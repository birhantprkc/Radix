//
//  IncrementalScanService.swift
//  Radix
//

import Foundation

/// Adds conservative FSEvents-based rescans around the ordinary scan engine.
/// Any uncertainty delegates to a full scan; partial subtree results are never
/// published before the complete batch splice succeeds.
nonisolated final class IncrementalScanService: ScanEventStreaming, @unchecked Sendable {
    private let engine: ScanEngine
    private let eventHistoryProvider: any FileSystemEventHistoryProviding
    private let planner: IncrementalRescanPlanner

    init(
        engine: ScanEngine = ScanEngine(),
        eventHistoryProvider: any FileSystemEventHistoryProviding = DarwinFileSystemEventHistoryProvider(),
        planner: IncrementalRescanPlanner = IncrementalRescanPlanner()
    ) {
        self.engine = engine
        self.eventHistoryProvider = eventHistoryProvider
        self.planner = planner
    }

    func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        let checkpoint = try? eventHistoryProvider.currentCheckpoint(for: target.url)
        return bridge(engine.scan(target: target, options: options)) { snapshot in
            self.snapshot(
                snapshot,
                checkpoint: self.eligibleCheckpoint(
                    checkpoint,
                    for: snapshot,
                    options: options
                )
            )
        }
    }

    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    guard self.canIncrementallyRescan(
                        baseline,
                        target: target,
                        options: options
                    ), let previousCheckpoint = baseline.incrementalCheckpoint else {
                        try await self.forwardFullScan(
                            target: target,
                            options: options,
                            continuation: continuation
                        )
                        return
                    }

                    let cutoff: ScanIncrementalCheckpoint
                    let history: FileSystemEventHistory
                    do {
                        cutoff = try self.eventHistoryProvider.currentCheckpoint(for: target.url)
                        history = try await self.eventHistoryProvider.history(
                            for: target.url,
                            since: previousCheckpoint,
                            through: cutoff
                        )
                    } catch {
                        try await self.forwardFullScan(
                            target: target,
                            options: options,
                            continuation: continuation
                        )
                        return
                    }

                    let matcher = ScanExclusionMatcher(
                        patterns: options.exclusionPatterns,
                        rootPath: options.exclusionRootPath ?? target.url.path,
                        includeCloudStorage: options.includeCloudStorage,
                        cloudStorageRootPath: options.cloudStorageRootPath,
                        iCloudDriveRootPath: options.iCloudDriveRootPath
                    )
                    switch self.planner.plan(
                        history: history,
                        target: target,
                        treeStore: baseline.treeStore,
                        exclusionMatcher: matcher
                    ) {
                    case .fullScan:
                        try await self.forwardFullScan(
                            target: target,
                            options: options,
                            continuation: continuation
                        )
                    case .noChanges:
                        let finished = self.refreshedSnapshot(
                            baseline,
                            checkpoint: cutoff,
                            startedAt: Date()
                        )
                        continuation.yield(.finished(finished))
                        continuation.finish()
                    case .rescanSubtrees(let nodeIDs):
                        try await self.performIncrementalScan(
                            target: target,
                            options: options,
                            baseline: baseline,
                            cutoff: cutoff,
                            nodeIDs: nodeIDs,
                            continuation: continuation
                        )
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func performIncrementalScan(
        target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot,
        cutoff: ScanIncrementalCheckpoint,
        nodeIDs: [String],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        let startedAt = Date()
        var replacements: [String: FileTreeStore] = [:]
        var replacementWarnings: [ScanWarning] = []
        var subtreeOptions = options
        if subtreeOptions.exclusionRootPath == nil {
            subtreeOptions.exclusionRootPath = target.url.path
        }

        for (index, nodeID) in nodeIDs.enumerated() {
            try Task.checkCancellation()
            guard let node = baseline.treeStore.node(id: nodeID) else {
                throw FileSystemEventHistoryError.targetUnavailable(nodeID)
            }
            var replacementSnapshot: ScanSnapshot?
            for try await event in engine.scan(
                target: ScanTarget(url: node.url),
                options: subtreeOptions
            ) {
                switch event {
                case .progress(var metrics):
                    let localFraction = min(max(metrics.progressFraction, 0), 1)
                    metrics.progressFraction = min(
                        (Double(index) + localFraction) / Double(max(nodeIDs.count, 1)) * 0.95,
                        0.95
                    )
                    continuation.yield(.progress(metrics))
                case .warning(let warning):
                    continuation.yield(.warning(warning))
                case .finished(let snapshot):
                    replacementSnapshot = snapshot
                }
            }
            let replacement = try replacementSnapshot.unwrap(
                or: FileSystemEventHistoryError.targetUnavailable(nodeID)
            )
            replacements[nodeID] = replacement.treeStore
            replacementWarnings.append(contentsOf: replacement.scanWarnings)
        }

        try Task.checkCancellation()
        guard let spliced = try baseline.replacingSubtrees(
            replacements,
            additionalWarnings: replacementWarnings,
            cancellationCheck: { try Task.checkCancellation() }
        ) else {
            try await forwardFullScan(
                target: target,
                options: options,
                continuation: continuation
            )
            return
        }
        let finished = ScanSnapshot(
            target: target,
            treeStore: spliced.treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            scanWarnings: spliced.scanWarnings,
            aggregateStats: spliced.treeStore.aggregateStats,
            isComplete: true,
            scanOptions: options,
            source: .live,
            incrementalCheckpoint: cutoff
        )
        continuation.yield(.finished(finished))
        continuation.finish()
    }

    private func forwardFullScan(
        target: ScanTarget,
        options: ScanOptions,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        for try await event in scan(target: target, options: options) {
            continuation.yield(event)
        }
        continuation.finish()
    }

    private func bridge(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        finishedTransform: @escaping @Sendable (ScanSnapshot) -> ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    for try await event in stream {
                        if case .finished(let snapshot) = event {
                            continuation.yield(.finished(finishedTransform(snapshot)))
                        } else {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func canIncrementallyRescan(
        _ baseline: ScanSnapshot,
        target: ScanTarget,
        options: ScanOptions
    ) -> Bool {
        guard baseline.isComplete,
              baseline.source.allowsFileMutation,
              baseline.target.kind == target.kind,
              baseline.target.url.standardizedFileURL.path == target.url.standardizedFileURL.path,
              baseline.scanOptions == options,
              baseline.incrementalCheckpoint != nil,
              !options.includeCloudStorage else {
            return false
        }
        let liveIdentity = try? ScanMetadataLoader().metadata(for: target.url).fileIdentity
        return baseline.root.fileIdentity == nil || liveIdentity == baseline.root.fileIdentity
    }

    private func eligibleCheckpoint(
        _ checkpoint: ScanIncrementalCheckpoint?,
        for snapshot: ScanSnapshot,
        options: ScanOptions
    ) -> ScanIncrementalCheckpoint? {
        _ = snapshot
        return options.includeCloudStorage ? nil : checkpoint
    }

    private func snapshot(
        _ snapshot: ScanSnapshot,
        checkpoint: ScanIncrementalCheckpoint?
    ) -> ScanSnapshot {
        ScanSnapshot(
            id: snapshot.id,
            target: snapshot.target,
            treeStore: snapshot.treeStore,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            scanWarnings: snapshot.scanWarnings,
            aggregateStats: snapshot.aggregateStats,
            isComplete: snapshot.isComplete,
            scanOptions: snapshot.scanOptions,
            source: snapshot.source,
            incrementalCheckpoint: checkpoint
        )
    }

    private func refreshedSnapshot(
        _ snapshot: ScanSnapshot,
        checkpoint: ScanIncrementalCheckpoint,
        startedAt: Date
    ) -> ScanSnapshot {
        ScanSnapshot(
            target: snapshot.target,
            treeStore: snapshot.treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            scanWarnings: snapshot.scanWarnings,
            aggregateStats: snapshot.aggregateStats,
            isComplete: true,
            scanOptions: snapshot.scanOptions,
            source: .live,
            incrementalCheckpoint: checkpoint
        )
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
