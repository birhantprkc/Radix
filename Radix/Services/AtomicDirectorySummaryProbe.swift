//
//  AtomicDirectorySummaryProbe.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

extension AtomicDirectorySummarizer {
    private nonisolated static func directoryOnlyProbeLimit(minFileCount: Int) -> Int {
        min(max(64, minFileCount / 4), 512)
    }

    nonisolated static func isKnownGeneratedDirectory(at url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3 else { return false }

        return Array(components.suffix(3)) == ["Library", "Developer", "CoreSimulator"]
    }

    nonisolated static func isNodeDependencyLayoutDirectory(at url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "node_modules" || name == ".pnpm" {
            return true
        }

        guard name.hasPrefix("@") else { return false }
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return parentName == "node_modules" || parentName == ".pnpm"
    }

    nonisolated func shouldRunDescendantAtomicProbe(
        childEntries: [DirectoryEntry],
        minFileCount: Int,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        if isNodeDependencyLayout {
            return true
        }

        guard childEntries.contains(where: { childEntry in
            childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
        }) else {
            return false
        }

        // Sparse parents are cheaper to traverse normally; dense descendants can still summarize themselves.
        let minimumImmediateEntries = max(1, min(minFileCount, minFileCount / 10))
        return childEntries.count >= minimumImmediateEntries
    }

    nonisolated func immediateChildrenSuggestAtomicDirectory(
        _ childEntries: [DirectoryEntry],
        maxAverageFileSize: Int64,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        try cancellationCheck()
        let sampleSize = min(100, childEntries.count)
        let step = max(1, childEntries.count / sampleSize)
        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for index in stride(from: 0, to: childEntries.count, by: step).prefix(sampleSize) {
            try cancellationCheck()
            let childEntry = childEntries[index]
            guard let childMetadata = childEntry.metadata else {
                return false
            }

            if !childMetadata.isDirectory {
                sampleTotalSize += childMetadata.logicalSize
                sampleFileCount += 1
            }
        }

        guard sampleFileCount > 0 else { return false }
        return (sampleTotalSize / Int64(sampleFileCount)) <= maxAverageFileSize
    }

    nonisolated func descendantAtomicProbeProfile(
        at url: URL,
        rootEntries: [DirectoryEntry],
        includeHiddenFiles: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeProfile {
        try cancellationCheck()
        #if DEBUG
        let probeStart = diagnostics?.start()
        #endif
        var visitedItems = 0
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.probe",
                url: url,
                startedAt: probeStart,
                itemCount: visitedItems,
                detail: "files=\(profile.observedFileCount) dirs=\(profile.observedDirectoryCount) nodeDeps=\(profile.observedNodeDependencyLayout)"
            )
        }
        #endif
        let maxVisitedItems = isNodeDependencyLayout
            ? max(5_000, minFileCount * 8)
            : max(1_000, minFileCount)

        if let bulkResult = try bulkDescendantAtomicProbeProfile(
            rootEntries: rootEntries,
            includeHiddenFiles: includeHiddenFiles,
            isNodeDependencyLayout: isNodeDependencyLayout,
            minFileCount: minFileCount,
            maxAverageFileSize: maxAverageFileSize,
            maxVisitedItems: maxVisitedItems,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) {
            visitedItems = bulkResult.visitedItems
            return bulkResult.profile
        }

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicProbeResourceKeys,
            options: enumeratorOptions,
            errorHandler: { _, _ in true }
        ) else {
            return profile
        }

        while let nextObject = enumerator.nextObject() {
            guard let childURL = nextObject as? URL else { continue }
            try cancellationCheck()
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childURL,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            guard visitedItems <= maxVisitedItems else { return profile }

            let hintedIsDirectory = childURL.hasDirectoryPath
            let childPath = childURL.path
            if exclusionMatcher.excludesKnownNormalizedPath(
                childPath,
                isDirectory: hintedIsDirectory
            ) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicProbeResourceKeySet)
                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                if isDirectory != hintedIsDirectory,
                   exclusionMatcher.excludesKnownNormalizedPath(childPath, isDirectory: isDirectory) {
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if Self.isNodeDependencyLayoutDirectory(at: childURL) {
                    profile.observedNodeDependencyLayout = true
                }

                guard !isDirectory else {
                    profile.observedDirectoryCount += 1
                    // Dense file caches reveal files quickly; directory-only trees should traverse normally.
                    if !isNodeDependencyLayout,
                       profile.observedFileCount == 0,
                       profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount) {
                        return profile
                    }
                    continue
                }
                guard !isSymbolicLink else { continue }

                profile.totalSampledLogicalSize += Int64(values.fileSize ?? 0)
                profile.observedFileCount += 1

                if profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: maxAverageFileSize
                ) {
                    return profile
                }
                // Once minimum sample is large-file-biased, skip summary and keep full detail.
                if profile.observedFileCount >= minFileCount {
                    return profile
                }
            } catch {
                return profile
            }
        }

        return profile
    }

    /// Mirrors `FileManager.DirectoryEnumerator`'s depth-first probe using
    /// immediate-child bulk metadata batches. Returning `nil` selects the
    /// Foundation compatibility path above on unsupported filesystems.
    private nonisolated func bulkDescendantAtomicProbeProfile(
        rootEntries: [DirectoryEntry],
        includeHiddenFiles: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        maxVisitedItems: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> (profile: AtomicDirectoryProbeProfile, visitedItems: Int)? {
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        var visitedItems = 0
        // The caller already enumerated and classified the root directory.
        // Reusing that array avoids a second full materialization before the
        // bounded descendant probe has examined even one item.
        var frames = [BulkProbeFrame(entries: rootEntries)]

        while !frames.isEmpty {
            try cancellationCheck()
            let frameIndex = frames.index(before: frames.endIndex)
            guard frames[frameIndex].nextIndex < frames[frameIndex].entries.count else {
                frames.removeLast()
                continue
            }

            let entry = frames[frameIndex].entries[frames[frameIndex].nextIndex]
            frames[frameIndex].nextIndex += 1
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: entry.url,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            guard visitedItems <= maxVisitedItems else {
                return (profile, visitedItems)
            }

            guard let metadata = entry.metadata else {
                return (profile, visitedItems)
            }
            let entryPath = entry.url.path
            guard !exclusionMatcher.excludesKnownNormalizedPath(
                entryPath,
                isDirectory: metadata.isDirectory
            ) else {
                continue
            }

            if Self.isNodeDependencyLayoutDirectory(at: entry.url) {
                profile.observedNodeDependencyLayout = true
            }

            if metadata.isDirectory {
                profile.observedDirectoryCount += 1
                if !isNodeDependencyLayout,
                   profile.observedFileCount == 0,
                   profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount) {
                    return (profile, visitedItems)
                }

                do {
                    guard let childResult = try BulkDirectoryEnumerator.directoryEntries(
                        at: entry.url,
                        includeHiddenFiles: includeHiddenFiles,
                        loadsPackageMetadata: false,
                        metadataLoader: metadataLoader,
                        cancellationCheck: cancellationCheck
                    ) else {
                        return nil
                    }
                    frames.append(BulkProbeFrame(entries: childResult.entries))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Foundation's error handler skips unreadable descendants and
                    // continues probing readable siblings.
                }
                continue
            }
            guard !metadata.isSymbolicLink else { continue }

            profile.totalSampledLogicalSize += metadata.logicalSize
            profile.observedFileCount += 1
            if profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            ) || profile.observedFileCount >= minFileCount {
                return (profile, visitedItems)
            }
        }

        return (profile, visitedItems)
    }
}

nonisolated private struct BulkProbeFrame {
    let entries: [DirectoryEntry]
    var nextIndex = 0
}
