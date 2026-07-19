//
//  IncrementalRescanPlanner.swift
//  Radix
//

import Foundation

/// Converts advisory filesystem events into conservative directory relists and
/// subtree rescans that can be spliced into a prior `FileTreeStore`.
nonisolated struct IncrementalRescanPlanner: Sendable {
    private static let broadRelistDirectoryThreshold = 32

    private enum UpdateKind {
        case relistDirectory
        case rescanSubtree
    }

    func plan(
        history: FileSystemEventHistory,
        target: ScanTarget,
        treeStore: FileTreeStore,
        exclusionMatcher: ScanExclusionMatcher? = nil
    ) -> IncrementalRescanPlan {
        let targetPath = Self.normalizedDirectoryPath(target.url.path)
        var orderedCandidateNodeIDs: [String] = []
        var updateKindByNodeID: [String: UpdateKind] = [:]

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
            if matchedNode.isAutoSummarized {
                return .fullScan(reason: .autoSummarizedBoundary)
            }
            let updateKind = updateKind(
                for: event,
                matchedNode: matchedNode
            )
            if updateKindByNodeID[matchedNode.id] == nil {
                orderedCandidateNodeIDs.append(matchedNode.id)
            }
            if updateKind == .rescanSubtree
                || updateKindByNodeID[matchedNode.id] == nil {
                updateKindByNodeID[matchedNode.id] = updateKind
            }
        }

        let topLevelNodeIDs = treeStore.topLevelNodeIDs(from: orderedCandidateNodeIDs)
        guard !topLevelNodeIDs.isEmpty else { return .noChanges }

        var relistDirectoryIDs: [String] = []
        var rescanSubtreeIDs: [String] = []
        for nodeID in topLevelNodeIDs {
            let hasNestedUpdate = orderedCandidateNodeIDs.contains { candidateID in
                candidateID != nodeID && treeStore.isAncestor(nodeID, of: candidateID)
            }
            let updateKind = hasNestedUpdate ? .rescanSubtree : updateKindByNodeID[nodeID]
            switch updateKind {
            case .relistDirectory:
                relistDirectoryIDs.append(nodeID)
            case .rescanSubtree:
                if nodeID == treeStore.rootID || nodeID == targetPath {
                    return .fullScan(reason: .changedScanRoot)
                }
                rescanSubtreeIDs.append(nodeID)
            case nil:
                continue
            }
        }
        let updateRootCount = relistDirectoryIDs.count + rescanSubtreeIDs.count
        if updateRootCount >= Self.broadRelistDirectoryThreshold {
            let relistedItemCount = relistDirectoryIDs.reduce(0) { count, directoryID in
                count + treeStore.childIDs(of: directoryID).count + 1
            }
            let rescannedItemCount = rescanSubtreeIDs.reduce(0) { count, subtreeID in
                count + treeStore.subtreeNodeCount(rootedAt: subtreeID)
            }
            if relistedItemCount + rescannedItemCount >= max(treeStore.nodeCount / 2, 1) {
                return .fullScan(reason: .incrementalWorkTooBroad)
            }
        }
        return .update(
            relistDirectoryIDs: relistDirectoryIDs,
            rescanSubtreeIDs: rescanSubtreeIDs
        )
    }

    private func updateKind(
        for event: FileSystemEventRecord,
        matchedNode: FileNodeRecord
    ) -> UpdateKind {
        if event.flags.contains(.mustScanSubdirectories) || matchedNode.isPackage {
            return .rescanSubtree
        }
        let changesMembership = !event.flags.intersection([
            .itemCreated,
            .itemRemoved,
            .itemRenamed,
        ]).isEmpty
        if event.flags.contains(.itemIsDirectory), !changesMembership {
            return .rescanSubtree
        }
        if !changesMembership,
           event.flags.intersection([.itemIsFile, .itemIsSymbolicLink]).isEmpty,
           event.path == matchedNode.id {
            return .rescanSubtree
        }
        return .relistDirectory
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
