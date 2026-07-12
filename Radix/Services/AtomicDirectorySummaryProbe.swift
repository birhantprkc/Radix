//
//  AtomicDirectorySummaryProbe.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated private struct AtomicProbeCancellation: Error {
    let underlyingError: Error
}

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
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeOutcome {
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
            at: url,
            rootEntries: rootEntries,
            rootMetadata: rootMetadata,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
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
            return bulkResult.outcome
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
            return AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil)
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
            guard visitedItems <= maxVisitedItems else {
                return AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil)
            }

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
                        return AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil)
                    }
                    continue
                }
                guard !isSymbolicLink else { continue }

                profile.totalSampledLogicalSize = ScanIntegerMath.addingClamped(
                    profile.totalSampledLogicalSize,
                    Int64(values.totalFileSize ?? values.fileSize ?? 0)
                )
                profile.observedFileCount += 1

                if profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: maxAverageFileSize
                ) {
                    return AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil)
                }
                // Once minimum sample is large-file-biased, skip summary and keep full detail.
                if profile.observedFileCount >= minFileCount {
                    return AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil)
                }
            } catch {
                return AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil)
            }
        }

        return AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil)
    }

    /// Mirrors `FileManager.DirectoryEnumerator`'s depth-first probe using
    /// immediate-child bulk metadata batches. Returning `nil` selects the
    /// Foundation compatibility path above on unsupported filesystems.
    private nonisolated func bulkDescendantAtomicProbeProfile(
        at url: URL,
        rootEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        maxVisitedItems: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> (outcome: AtomicDirectoryProbeOutcome, visitedItems: Int)? {
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        var visitedItems = 0
        var partial = AtomicDirectorySummaryPartial()
        partial.updateAccessibility(rootMetadata.isReadable)
        // The caller already enumerated and classified the root directory.
        // A successful probe hands these frames directly to the summary queue.
        var frames = [AtomicSummaryWorkItem(
            url: url,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            ownerNodeID: url.path,
            bufferedEntries: rootEntries,
            needsCursor: false
        )]

        while !frames.isEmpty {
            try cancellationCheck()
            let frameIndex = frames.index(before: frames.endIndex)
            if frames[frameIndex].nextEntryIndex >= frames[frameIndex].bufferedEntries.count {
                if frames[frameIndex].cursor == nil, frames[frameIndex].needsCursor {
                    do {
                        if frames.lazy.filter({ $0.cursor != nil }).count >= 64 {
                            guard let childResult = try BulkDirectoryEnumerator.directoryEntries(
                                at: frames[frameIndex].url,
                                includeHiddenFiles: includeHiddenFiles,
                                loadsPackageMetadata: !frames[frameIndex].treatPackagesAsDirectories,
                                metadataLoader: metadataLoader,
                                cancellationCheck: {
                                    do {
                                        try cancellationCheck()
                                    } catch {
                                        throw AtomicProbeCancellation(underlyingError: error)
                                    }
                                }
                            ) else {
                                return nil
                            }
                            frames[frameIndex].bufferedEntries = childResult.entries
                            frames[frameIndex].nextEntryIndex = 0
                            frames[frameIndex].needsCursor = false
                            continue
                        }
                        frames[frameIndex].cursor = try BulkDirectoryEnumerator.makeCursor(
                            at: frames[frameIndex].url,
                            includeHiddenFiles: includeHiddenFiles,
                            loadsPackageMetadata: !frames[frameIndex].treatPackagesAsDirectories,
                            metadataLoader: metadataLoader,
                            cancellationCheck: {
                                do {
                                    try cancellationCheck()
                                } catch {
                                    throw AtomicProbeCancellation(underlyingError: error)
                                }
                            }
                        )
                        frames[frameIndex].needsCursor = false
                    } catch let cancellation as AtomicProbeCancellation {
                        throw cancellation.underlyingError
                    } catch {
                        partial.recordWarning(for: frames[frameIndex].url, error: error)
                        frames.removeLast()
                        continue
                    }
                }

                if let cursor = frames[frameIndex].cursor {
                    do {
                        if let batch = try cursor.nextBatch(cancellationCheck: {
                            do {
                                try cancellationCheck()
                            } catch {
                                throw AtomicProbeCancellation(underlyingError: error)
                            }
                        }) {
                            frames[frameIndex].bufferedEntries = batch.entries
                            frames[frameIndex].nextEntryIndex = 0
                            continue
                        }
                    } catch let cancellation as AtomicProbeCancellation {
                        throw cancellation.underlyingError
                    } catch BulkDirectoryEnumerator.StreamError.unavailable {
                        return nil
                    } catch {
                        return nil
                    }
                }
                frames.removeLast()
                continue
            }

            let entry = frames[frameIndex].bufferedEntries[frames[frameIndex].nextEntryIndex]
            frames[frameIndex].nextEntryIndex += 1
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
                return (
                    AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil),
                    visitedItems
                )
            }

            guard let metadata = entry.metadata else {
                return (
                    AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil),
                    visitedItems
                )
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
            partial.updateAccessibility(metadata.isReadable)

            if metadata.isDirectory {
                profile.observedDirectoryCount += 1
                if !isNodeDependencyLayout,
                   profile.observedFileCount == 0,
                   profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount) {
                    return (
                        AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil),
                        visitedItems
                    )
                }

                let isTraversablePackageSymlink = metadata.isSymbolicLink
                    && metadata.isPackage
                    && !frames[frameIndex].treatPackagesAsDirectories
                if !metadata.isSymbolicLink || isTraversablePackageSymlink {
                    frames.append(
                        AtomicSummaryWorkItem(
                            url: entry.url,
                            treatPackagesAsDirectories: metadata.isPackage
                                ? true
                                : frames[frameIndex].treatPackagesAsDirectories,
                            ownerNodeID: frames[frameIndex].ownerNodeID
                        )
                    )
                }
                continue
            }
            partial.accumulateFile(metadata, url: entry.url, ownerNodeID: frames[frameIndex].ownerNodeID)
            guard !metadata.isSymbolicLink else { continue }

            profile.totalSampledLogicalSize = ScanIntegerMath.addingClamped(
                profile.totalSampledLogicalSize,
                metadata.logicalSize
            )
            profile.observedFileCount += 1
            if profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            ) {
                for index in frames.indices {
                    frames[index].requiresRootRestartOnFallback = true
                }
                return (
                    AtomicDirectoryProbeOutcome(
                        profile: profile,
                        resumeState: AtomicDirectoryProbeResumeState(
                            partial: partial,
                            workItems: frames,
                            visitedItemCount: visitedItems
                        )
                    ),
                    visitedItems
                )
            }
            if profile.observedFileCount >= minFileCount {
                return (
                    AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil),
                    visitedItems
                )
            }
        }

        return (
            AtomicDirectoryProbeOutcome(profile: profile, resumeState: nil),
            visitedItems
        )
    }
}
