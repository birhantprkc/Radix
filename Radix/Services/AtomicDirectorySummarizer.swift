//
//  AtomicDirectorySummarizer.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated struct AtomicDirectorySummarizer: Sendable {
    typealias ProfileReporter = @Sendable (ScanAutoSummaryProfileEvent) -> Void

    let metadataLoader: ScanMetadataLoader
    let diagnostics: ScanDiagnosticsContext?
    let summaryPool: AtomicDirectorySummaryPool?
    let profileReporter: ProfileReporter?

    init(
        metadataLoader: ScanMetadataLoader,
        diagnostics: ScanDiagnosticsContext? = nil,
        summaryPool: AtomicDirectorySummaryPool? = nil,
        profileReporter: ProfileReporter? = nil
    ) {
        self.metadataLoader = metadataLoader
        self.diagnostics = diagnostics
        self.summaryPool = summaryPool
        self.profileReporter = profileReporter
    }

    /// Cheap, synchronous pre-check mirroring `summaryIfNeeded`'s gating: whether the
    /// directory is worth probing or summarizing at all. Runs no descendant I/O, so it
    /// is safe to call on the scan scheduling loop before dispatching the (potentially
    /// slow) `summaryIfNeeded` call off it.
    func isAtomicSummaryCandidate(
        url: URL,
        childEntries: [DirectoryEntry],
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        guard !childEntries.isEmpty else { return false }
        if childEntries.count >= minFileCount,
           try immediateChildrenSuggestAtomicDirectory(
               childEntries,
               maxAverageFileSize: maxAverageFileSize,
               cancellationCheck: cancellationCheck
           ) {
            return true
        }
        if Self.isKnownGeneratedDirectory(at: url) {
            return true
        }
        return shouldRunDescendantAtomicProbe(
            childEntries: childEntries,
            minFileCount: minFileCount,
            isNodeDependencyLayout: isNodeDependencyLayout
        )
    }

    /// Determines if a directory should be treated as atomic (summarized without expansion).
    /// Returns a summary if the directory has many small files (like node_modules, caches).
    /// Returns nil if the directory should be expanded normally.
    ///
    /// Sampling uses metadata decoded from `contentsOfDirectory`'s prefetched resource values,
    /// so no additional per-file resource lookups are needed.
    func summaryIfNeeded(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        workerLimit: Int,
        progressWeight: Double = 0,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        guard !childEntries.isEmpty else { return nil }

        let immediateCandidate: Bool
        if childEntries.count >= minFileCount {
            immediateCandidate = try immediateChildrenSuggestAtomicDirectory(
                childEntries,
                maxAverageFileSize: maxAverageFileSize,
                cancellationCheck: cancellationCheck
            )
        } else {
            immediateCandidate = false
        }

        let deepCandidate: Bool
        var probeResumeState: AtomicDirectoryProbeResumeState? = nil
        if immediateCandidate {
            deepCandidate = true
        } else if Self.isKnownGeneratedDirectory(at: url) {
            deepCandidate = true
        } else {
            guard shouldRunDescendantAtomicProbe(
                childEntries: childEntries,
                minFileCount: minFileCount,
                isNodeDependencyLayout: isNodeDependencyLayout
            ) else {
                return nil
            }
            let outcome = try descendantAtomicProbeProfile(
                at: url,
                rootEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                isNodeDependencyLayout: isNodeDependencyLayout,
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            deepCandidate = outcome.profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            )
            profileReporter?(.probeCompleted(
                visitedItemCount: outcome.visitedItemCount,
                wasAccepted: deepCandidate
            ))
            probeResumeState = deepCandidate ? outcome.resumeState : nil
        }

        guard deepCandidate else {
            return nil
        }

        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        let canReuseImmediateEntries = immediateCandidate && directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            let summary = try await summarizeReusingImmediateChildren(
                at: url,
                childEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: url.path,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            reportCreatedSummary(summary)
            return summary
        }

        guard let summary = try await summarize(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            progressWeight: progressWeight,
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            resumeState: probeResumeState
        ) else { return nil }
        reportCreatedSummary(summary)
        return summary
    }

    private func reportCreatedSummary(_ summary: AtomicDirectorySummary?) {
        guard let summary else { return }
        profileReporter?(.directorySummarized(
            descendantFileCount: summary.descendantFileCount
        ))
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    func summarize(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        progressWeight: Double = 0,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        resumeState: AtomicDirectoryProbeResumeState? = nil
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        if let summaryPool {
            #if DEBUG
            let summaryStart = diagnostics?.start()
            #endif
            let summary = try await summaryPool.summarize(
                AtomicSummaryPoolRequest(
                    url: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    progressWeight: progressWeight,
                    ownerNodeID: ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    metadataLoader: metadataLoader,
                    cancellationCheck: cancellationCheck,
                    metrics: metrics,
                    continuation: continuation,
                    resumeState: resumeState
                )
            )
            #if DEBUG
            diagnostics?.record(
                operation: "atomic.summary.pool",
                url: url,
                startedAt: summaryStart,
                itemCount: summary?.descendantFileCount
            )
            #endif
            return summary
        }
        if workerLimit > 1 {
            #if DEBUG
            let summaryStart = diagnostics?.start()
            #endif
            let summary: AtomicDirectorySummary?
            do {
                summary = try await Self.summarizeInParallel(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
                    ownerNodeID: ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    metadataLoader: metadataLoader,
                    cancellationCheck: cancellationCheck,
                    metrics: metrics,
                    continuation: continuation,
                    resumeState: resumeState
                )
            } catch is AtomicSummaryRootFallbackRequired {
                resumeState?.invalidateCursors()
                summary = try await Self.summarizeInParallel(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
                    ownerNodeID: ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    metadataLoader: metadataLoader,
                    cancellationCheck: cancellationCheck,
                    metrics: metrics,
                    continuation: continuation,
                    forcesFoundationTraversal: true
                )
            }
            #if DEBUG
            diagnostics?.record(
                operation: "atomic.summary.parallel",
                url: url,
                startedAt: summaryStart,
                itemCount: summary?.descendantFileCount,
                detail: "workers=\(workerLimit)"
            )
            #endif
            return summary
        }

        return try await summarizeSerial(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            ownerNodeID: ownerNodeID,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            resumeState: resumeState
        )
    }
}
