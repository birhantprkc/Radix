//
//  IncrementalRescanPlanner.swift
//  Radix
//

import Foundation

/// Converts advisory filesystem events into conservative, existing subtree
/// roots that can be scanned and spliced into a prior `FileTreeStore`.
nonisolated struct IncrementalRescanPlanner: Sendable {
    func plan(
        history: FileSystemEventHistory,
        target: ScanTarget,
        treeStore: FileTreeStore,
        exclusionMatcher: ScanExclusionMatcher? = nil
    ) -> IncrementalRescanPlan {
        let targetPath = Self.normalizedDirectoryPath(target.url.path)
        var candidateNodeIDs: [String] = []

        for event in history.events {
            if let fallback = fallbackReason(for: event.flags) {
                return .fullScan(reason: fallback)
            }

            let eventPath = URL(filePath: event.path).standardizedFileURL.path
            guard Self.path(eventPath, isEqualToOrDescendantOf: targetPath) else {
                return .fullScan(reason: .eventOutsideTarget)
            }
            if eventPath == targetPath {
                return .fullScan(reason: .changedScanRoot)
            }

            let knownIsDirectory: Bool?
            if event.flags.contains(.itemIsDirectory) {
                knownIsDirectory = true
            } else if !event.flags.intersection([.itemIsFile, .itemIsSymbolicLink]).isEmpty {
                knownIsDirectory = false
            } else {
                knownIsDirectory = nil
            }
            if let knownIsDirectory,
               exclusionMatcher?.excludesKnownNormalizedPath(
                   eventPath,
                   isDirectory: knownIsDirectory
               ) == true {
                continue
            }

            var candidatePath = initialCandidatePath(
                for: event,
                eventPath: eventPath,
                treeStore: treeStore
            )
            var matchedNode: FileNodeRecord?
            while Self.path(candidatePath, isEqualToOrDescendantOf: targetPath) {
                if let node = treeStore.node(id: candidatePath), node.isDirectory {
                    matchedNode = node
                    break
                }
                guard candidatePath != targetPath else { break }
                candidatePath = Self.parentPath(of: candidatePath)
            }

            guard let matchedNode else {
                return .fullScan(reason: .noMaterializedAncestor)
            }
            if matchedNode.id == treeStore.rootID || matchedNode.id == targetPath {
                return .fullScan(reason: .changedScanRoot)
            }
            if matchedNode.isAutoSummarized {
                return .fullScan(reason: .autoSummarizedBoundary)
            }
            candidateNodeIDs.append(matchedNode.id)
        }

        let topLevelNodeIDs = treeStore.topLevelNodeIDs(from: candidateNodeIDs)
        return topLevelNodeIDs.isEmpty
            ? .noChanges
            : .rescanSubtrees(nodeIDs: topLevelNodeIDs)
    }

    private func fallbackReason(
        for flags: FileSystemEventFlags
    ) -> IncrementalRescanFallbackReason? {
        if flags.contains(.userDropped) { return .userDroppedEvents }
        if flags.contains(.kernelDropped) { return .kernelDroppedEvents }
        if flags.contains(.eventIDsWrapped) { return .eventIDsWrapped }
        if flags.contains(.rootChanged) { return .watchedRootChanged }
        if !flags.intersection([.volumeMounted, .volumeUnmounted]).isEmpty {
            return .nestedVolumeChanged
        }
        return nil
    }

    private func initialCandidatePath(
        for event: FileSystemEventRecord,
        eventPath: String,
        treeStore: FileTreeStore
    ) -> String {
        if event.flags.contains(.mustScanSubdirectories) {
            return eventPath
        }

        let isDirectory = event.flags.contains(.itemIsDirectory)
        let changesMembership = !event.flags.intersection([
            .itemCreated,
            .itemRemoved,
            .itemRenamed,
        ]).isEmpty
        if isDirectory && !changesMembership {
            return eventPath
        }
        if event.flags.intersection([.itemIsFile, .itemIsSymbolicLink]).isEmpty,
           treeStore.node(id: eventPath)?.isDirectory == true,
           !changesMembership {
            return eventPath
        }
        return Self.parentPath(of: eventPath)
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.path
    }

    private static func parentPath(of path: String) -> String {
        URL(filePath: path).deletingLastPathComponent().standardizedFileURL.path
    }

    private static func path(_ path: String, isEqualToOrDescendantOf rootPath: String) -> Bool {
        rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
