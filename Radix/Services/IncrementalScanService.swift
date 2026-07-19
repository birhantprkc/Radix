//
//  IncrementalScanService.swift
//  Radix
//

import Foundation

/// Adds conservative FSEvents-based rescans around the ordinary scan engine.
/// Any uncertainty delegates to a full scan; partial subtree results are never
/// published before the complete batch splice succeeds.
nonisolated final class IncrementalScanService: ScanEventStreaming, @unchecked Sendable {
    private enum ShallowRelistError: Error {
        case invalidDirectory
        case incompleteMetadata
        case duplicateEntry
        case identityChanged
        case replacementCollision
    }

    private struct ShallowReplacement: Sendable {
        let directoryID: String
        let treeStore: FileTreeStore
        let warnings: [ScanWarning]
    }

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

    nonisolated func scan(
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

    nonisolated func rescan(
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
                    case .update(let relistDirectoryIDs, let rescanSubtreeIDs):
                        try await self.performIncrementalScan(
                            target: target,
                            options: options,
                            baseline: baseline,
                            cutoff: cutoff,
                            relistDirectoryIDs: relistDirectoryIDs,
                            rescanSubtreeIDs: rescanSubtreeIDs,
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

    private nonisolated func performIncrementalScan(
        target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot,
        cutoff: ScanIncrementalCheckpoint,
        relistDirectoryIDs: [String],
        rescanSubtreeIDs: [String],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        let startedAt = Date()
        var replacements: [String: FileTreeStore] = [:]
        var replacementWarnings: [ScanWarning] = []
        var subtreeOptions = options
        if subtreeOptions.exclusionRootPath == nil {
            subtreeOptions.exclusionRootPath = target.url.path
        }
        let relistOptions = subtreeOptions

        do {
            try await withThrowingTaskGroup(of: ShallowReplacement.self) { group in
                let workerLimit = min(
                    ScanEngine.shallowRelistWorkerLimit(for: relistOptions),
                    relistDirectoryIDs.count
                )
                var nextIndex = 0
                func addNextRelist() {
                    guard nextIndex < relistDirectoryIDs.count else { return }
                    let nodeID = relistDirectoryIDs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await self.shallowReplacement(
                            directoryID: nodeID,
                            target: target,
                            options: relistOptions,
                            baseline: baseline
                        )
                    }
                }
                for _ in 0..<workerLimit {
                    addNextRelist()
                }
                while let replacement = try await group.next() {
                    replacements[replacement.directoryID] = replacement.treeStore
                    replacementWarnings.append(contentsOf: replacement.warnings)
                    addNextRelist()
                }
            }
            for warning in replacementWarnings {
                continuation.yield(.warning(warning))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await forwardFullScan(
                target: target,
                options: options,
                continuation: continuation
            )
            return
        }

        let updateCount = relistDirectoryIDs.count + rescanSubtreeIDs.count
        for (subtreeIndex, nodeID) in rescanSubtreeIDs.enumerated() {
            try Task.checkCancellation()
            guard let node = baseline.treeStore.node(id: nodeID) else {
                try await forwardFullScan(
                    target: target,
                    options: options,
                    continuation: continuation
                )
                return
            }
            var replacementSnapshot: ScanSnapshot?
            do {
                for try await event in engine.scan(
                    target: ScanTarget(url: node.url),
                    options: subtreeOptions
                ) {
                    switch event {
                    case .progress(var metrics):
                        let localFraction = min(max(metrics.progressFraction, 0), 1)
                        metrics.progressFraction = min(
                            (
                                Double(relistDirectoryIDs.count + subtreeIndex)
                                    + localFraction
                            ) / Double(max(updateCount, 1)) * 0.95,
                            0.95
                        )
                        continuation.yield(.progress(metrics))
                    case .warning(let warning):
                        continuation.yield(.warning(warning))
                    case .finished(let snapshot):
                        replacementSnapshot = snapshot
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await forwardFullScan(
                    target: target,
                    options: options,
                    continuation: continuation
                )
                return
            }
            guard let replacement = replacementSnapshot else {
                try await forwardFullScan(
                    target: target,
                    options: options,
                    continuation: continuation
                )
                return
            }
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
            volumeCapacity: baseline.volumeCapacity,
            source: .live,
            incrementalCheckpoint: cutoff
        )
        continuation.yield(.finished(finished))
        continuation.finish()
    }

    private nonisolated func shallowReplacement(
        directoryID: String,
        target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot
    ) async throws -> ShallowReplacement {
        guard let originalSubtree = baseline.treeStore.subtree(rootedAt: directoryID),
              originalSubtree.root.isDirectory,
              !originalSubtree.root.isSymbolicLink else {
            throw ShallowRelistError.invalidDirectory
        }
        let listing = try await engine.shallowDirectoryListing(
            at: originalSubtree.root.url,
            scanTarget: target,
            options: options
        )
        guard listing.directoryMetadata.fileIdentity != nil,
              listing.directoryMetadata.fileIdentity == originalSubtree.root.fileIdentity else {
            throw ShallowRelistError.identityChanged
        }

        var nodesByID = originalSubtree.nodesByID
        var childIDsByID = originalSubtree.childIDsByID
        let originalChildIDs = originalSubtree.childIDs(of: directoryID)
        var currentChildIDs = Set<String>()
        currentChildIDs.reserveCapacity(listing.entries.count)
        var preservedSubtreeIDs = Set<String>()
        var replacementWarnings: [ScanWarning] = []

        for entry in listing.entries {
            try Task.checkCancellation()
            guard entry.localizedEnumerationError == nil,
                  let metadata = entry.metadata else {
                throw ShallowRelistError.incompleteMetadata
            }
            let childID = entry.url.path
            guard currentChildIDs.insert(childID).inserted else {
                throw ShallowRelistError.duplicateEntry
            }

            if canPreserveDirectory(
                baselineNode: originalSubtree.node(id: childID),
                metadata: metadata
            ) {
                preservedSubtreeIDs.insert(childID)
                continue
            }

            removeSubtree(
                rootedAt: childID,
                from: originalSubtree,
                nodesByID: &nodesByID,
                childIDsByID: &childIDsByID
            )
            if metadata.isDirectory, !metadata.isSymbolicLink {
                let childSnapshot = try await scannedReplacement(
                    at: entry.url,
                    options: options
                )
                for (replacementID, node) in childSnapshot.treeStore.nodesByID {
                    guard nodesByID[replacementID] == nil else {
                        throw ShallowRelistError.replacementCollision
                    }
                    nodesByID[replacementID] = node
                }
                for (replacementID, childIDs) in childSnapshot.treeStore.childIDsByID {
                    childIDsByID[replacementID] = childIDs
                }
                replacementWarnings.append(contentsOf: childSnapshot.scanWarnings)
            } else {
                nodesByID[childID] = engine.makeFileNode(
                    url: entry.url,
                    metadata: metadata
                )
            }
        }

        for removedChildID in originalChildIDs where !currentChildIDs.contains(removedChildID) {
            removeSubtree(
                rootedAt: removedChildID,
                from: originalSubtree,
                nodesByID: &nodesByID,
                childIDsByID: &childIDsByID
            )
        }

        let children = FileTreeStore.sortedChildren(
            currentChildIDs.compactMap { nodesByID[$0] }
        )
        guard children.count == currentChildIDs.count else {
            throw ShallowRelistError.incompleteMetadata
        }
        nodesByID[directoryID] = FileNodeRecord.directory(
            id: directoryID,
            url: originalSubtree.root.url,
            name: originalSubtree.root.name,
            children: children,
            lastModified: listing.directoryMetadata.lastModified,
            fileIdentity: listing.directoryMetadata.fileIdentity,
            linkCount: listing.directoryMetadata.linkCount,
            isPackage: listing.directoryMetadata.isPackage,
            isAccessible: listing.directoryMetadata.isReadable,
            childrenAreSorted: true
        )
        if children.isEmpty {
            childIDsByID.removeValue(forKey: directoryID)
        } else {
            childIDsByID[directoryID] = children.map(\.id)
        }
        replacementWarnings.append(contentsOf: baseline.scanWarnings.filter { warning in
            preservedSubtreeIDs.contains { subtreeID in
                Self.path(warning.path, isContainedIn: subtreeID)
            }
        })
        return ShallowReplacement(
            directoryID: directoryID,
            treeStore: FileTreeStore(
                rootID: directoryID,
                nodesByID: nodesByID,
                childIDsByID: childIDsByID
            ),
            warnings: replacementWarnings
        )
    }

    private nonisolated func scannedReplacement(
        at url: URL,
        options: ScanOptions
    ) async throws -> ScanSnapshot {
        var snapshot: ScanSnapshot?
        for try await event in engine.scan(
            target: ScanTarget(url: url),
            options: options
        ) {
            switch event {
            case .finished(let finished):
                snapshot = finished
            case .progress, .warning:
                break
            }
        }
        guard let snapshot else { throw ShallowRelistError.invalidDirectory }
        return snapshot
    }

    private nonisolated func canPreserveDirectory(
        baselineNode: FileNodeRecord?,
        metadata: NodeMetadata
    ) -> Bool {
        guard let baselineNode,
              baselineNode.isDirectory,
              !baselineNode.isSymbolicLink,
              metadata.isDirectory,
              !metadata.isSymbolicLink,
              baselineNode.isPackage == metadata.isPackage,
              baselineNode.isSelfAccessible == metadata.isReadable,
              let fileIdentity = metadata.fileIdentity,
              baselineNode.fileIdentity == fileIdentity else {
            return false
        }
        return true
    }

    private nonisolated func removeSubtree(
        rootedAt nodeID: String,
        from originalSubtree: FileTreeStore,
        nodesByID: inout [String: FileNodeRecord],
        childIDsByID: inout [String: [String]]
    ) {
        for removedID in originalSubtree.subtreeNodeIDs(rootedAt: nodeID) {
            nodesByID.removeValue(forKey: removedID)
            childIDsByID.removeValue(forKey: removedID)
        }
    }

    private nonisolated static func path(_ path: String, isContainedIn rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private nonisolated func forwardFullScan(
        target: ScanTarget,
        options: ScanOptions,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        for try await event in scan(target: target, options: options) {
            continuation.yield(event)
        }
        continuation.finish()
    }

    private nonisolated func bridge(
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

    private nonisolated func canIncrementallyRescan(
        _ baseline: ScanSnapshot,
        target: ScanTarget,
        options: ScanOptions
    ) -> Bool {
        // Whole-volume accounting must capture capacity and rebuild its synthetic
        // unattributed remainder as one consistent scan-time snapshot.
        guard baseline.isComplete,
              baseline.source.allowsFileMutation,
              target.kind != .volume,
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

    private nonisolated func eligibleCheckpoint(
        _ checkpoint: ScanIncrementalCheckpoint?,
        for snapshot: ScanSnapshot,
        options: ScanOptions
    ) -> ScanIncrementalCheckpoint? {
        _ = snapshot
        return options.includeCloudStorage ? nil : checkpoint
    }

    private nonisolated func snapshot(
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
            volumeCapacity: snapshot.volumeCapacity,
            source: snapshot.source,
            incrementalCheckpoint: checkpoint
        )
    }

    private nonisolated func refreshedSnapshot(
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
            volumeCapacity: snapshot.volumeCapacity,
            source: .live,
            incrementalCheckpoint: checkpoint
        )
    }
}
