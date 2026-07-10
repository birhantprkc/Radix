//
//  AtomicDirectoryParallelSummary.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated private struct AtomicSummaryCancellation: Error {
    let underlyingError: Error
}

nonisolated struct AtomicSummaryRootFallbackRequired: Error {}

nonisolated private final class AtomicSummaryWarningCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var warnings: [ScanWarning] = []

    func record(for url: URL, error: Error) {
        lock.lock()
        warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
        lock.unlock()
    }

    func collectedWarnings() -> [ScanWarning] {
        lock.lock()
        defer { lock.unlock() }
        return warnings
    }
}

nonisolated private final class AtomicSummaryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pendingItems: [AtomicSummaryWorkItem]
    private var activeItemCount = 0
    private var failure: Error?

    init(items: [AtomicSummaryWorkItem]) {
        pendingItems = items
    }

    func take(cancellationCheck: CancellationCheck) throws -> AtomicSummaryWorkItem? {
        condition.lock()
        defer { condition.unlock() }

        while pendingItems.isEmpty, activeItemCount > 0, failure == nil {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            try cancellationCheck()
        }

        if let failure {
            throw failure
        }

        guard let item = pendingItems.popLast() else {
            return nil
        }

        activeItemCount += 1
        return item
    }

    func enqueue(_ item: AtomicSummaryWorkItem) {
        condition.lock()
        pendingItems.append(item)
        condition.signal()
        condition.unlock()
    }

    func finishCurrentItem() {
        condition.lock()
        activeItemCount -= 1
        if pendingItems.isEmpty && activeItemCount == 0 {
            condition.broadcast()
        } else {
            condition.signal()
        }
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if failure == nil {
            failure = error
        }
        pendingItems.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

nonisolated final class AtomicSummaryAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var allocatedSize: Int64 = 0
    private var logicalSize: Int64 = 0
    private var descendantFileCount = 0
    private var isAccessible = true
    private var warnings: [ScanWarning] = []
    private var hardLinkClaims: [HardLinkClaim] = []

    init(seed: AtomicDirectorySummaryPartial? = nil) {
        guard let seed else { return }
        allocatedSize = seed.allocatedSize
        logicalSize = seed.logicalSize
        descendantFileCount = seed.descendantFileCount
        isAccessible = seed.isAccessible
        warnings = seed.warnings
        hardLinkClaims = seed.hardLinkClaims
    }

    func updateAccessibility(_ readable: Bool) {
        lock.lock()
        isAccessible = isAccessible && readable
        lock.unlock()
    }

    func recordWarning(for url: URL, error: Error) {
        lock.lock()
        isAccessible = false
        warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
        lock.unlock()
    }

    func merge(_ partial: AtomicDirectorySummaryPartial) {
        lock.lock()
        allocatedSize += partial.allocatedSize
        logicalSize += partial.logicalSize
        descendantFileCount += partial.descendantFileCount
        isAccessible = isAccessible && partial.isAccessible
        warnings.append(contentsOf: partial.warnings)
        hardLinkClaims.append(contentsOf: partial.hardLinkClaims)
        lock.unlock()
    }

    func makeSummary() -> AtomicDirectorySummary {
        lock.lock()
        defer { lock.unlock() }
        return AtomicDirectorySummary(
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            isAccessible: isAccessible,
            warnings: warnings,
            hardLinkClaims: hardLinkClaims
        )
    }
}

nonisolated final class AtomicSummaryProgressReporter: @unchecked Sendable {
    typealias VisitHandler = @Sendable (_ delta: Int, _ currentURL: URL) -> Void

    private let lock = NSLock()
    private var metrics: ScanMetrics
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private let visitHandler: VisitHandler?
    private var lastEmission = Date.distantPast
    private var hasEmitted = false
    private var lastReportedVisitedItemCount = 0

    init(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        visitHandler: VisitHandler? = nil
    ) {
        self.metrics = metrics
        self.continuation = continuation
        self.visitHandler = visitHandler
    }

    func emit(currentURL: URL, visitedItemCount: Int? = nil) {
        lock.lock()
        if let visitedItemCount, let visitHandler {
            let delta = visitedItemCount >= lastReportedVisitedItemCount
                ? visitedItemCount - lastReportedVisitedItemCount
                : visitedItemCount
            lastReportedVisitedItemCount = visitedItemCount
            if delta > 0 {
                visitHandler(delta, currentURL)
            }
        }
        guard visitHandler == nil else {
            lock.unlock()
            return
        }
        let now = Date()
        guard !hasEmitted || now.timeIntervalSince(lastEmission) >= 0.15 else {
            lock.unlock()
            return
        }

        metrics.currentPath = currentURL.path
        lastEmission = now
        hasEmitted = true
        continuation.yield(.progress(metrics))
        lock.unlock()
    }

    func finish(currentURL: URL, visitedItemCount: Int) {
        emit(currentURL: currentURL, visitedItemCount: visitedItemCount)
    }

    func beginPhase() {
        lock.lock()
        lastReportedVisitedItemCount = 0
        lock.unlock()
    }
}

extension AtomicDirectorySummarizer {
    nonisolated static func processPooledWorkItem(
        _ initialItem: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter,
        forcesFoundationTraversal: Bool
    ) throws -> AtomicSummaryWorkResult {
        try cancellationCheck()
        var item = initialItem

        if forcesFoundationTraversal {
            return try processPooledWorkItemUsingFoundation(
                item,
                includeHiddenFiles: includeHiddenFiles,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter
            )
        }

        var partial = AtomicDirectorySummaryPartial()
        var pendingItems: [AtomicSummaryWorkItem] = []
        var visitedItemCount = 0
        if item.nextEntryIndex < item.bufferedEntries.count {
            try stageEntries(
                item.bufferedEntries[item.nextEntryIndex...],
                from: item,
                exclusionMatcher: exclusionMatcher,
                partial: &partial,
                pendingItems: &pendingItems,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter,
                workerVisitedItemCount: &visitedItemCount
            )
            item.nextEntryIndex = item.bufferedEntries.count
        }

        var cursor = item.cursor
        if cursor == nil, item.needsCursor {
            do {
                cursor = try BulkDirectoryEnumerator.makeCursor(
                    at: item.url,
                    includeHiddenFiles: includeHiddenFiles,
                    loadsPackageMetadata: !item.treatPackagesAsDirectories,
                    metadataLoader: metadataLoader,
                    cancellationCheck: cancellationCheck
                )
            } catch {
                try cancellationCheck()
                partial.recordWarning(for: item.url, error: error)
                progressReporter.finish(
                    currentURL: item.url,
                    visitedItemCount: visitedItemCount
                )
                return AtomicSummaryWorkResult(partial: partial, pendingItems: pendingItems)
            }
        }

        do {
            while let batch = try cursor?.nextBatch(cancellationCheck: cancellationCheck) {
                try stageEntries(
                    batch.entries[...],
                    from: item,
                    exclusionMatcher: exclusionMatcher,
                    partial: &partial,
                    pendingItems: &pendingItems,
                    cancellationCheck: cancellationCheck,
                    progressReporter: progressReporter,
                    workerVisitedItemCount: &visitedItemCount
                )
            }
        } catch BulkDirectoryEnumerator.StreamError.unavailable {
            progressReporter.finish(
                currentURL: item.url,
                visitedItemCount: visitedItemCount
            )
            if item.requiresRootRestartOnFallback {
                throw AtomicSummaryRootFallbackRequired()
            }
            progressReporter.beginPhase()
            return try processPooledWorkItemUsingFoundation(
                item,
                includeHiddenFiles: includeHiddenFiles,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter
            )
        } catch {
            try cancellationCheck()
            progressReporter.finish(
                currentURL: item.url,
                visitedItemCount: visitedItemCount
            )
            var warningOnly = AtomicDirectorySummaryPartial()
            warningOnly.recordWarning(for: item.url, error: error)
            return AtomicSummaryWorkResult(partial: warningOnly, pendingItems: [])
        }

        progressReporter.finish(currentURL: item.url, visitedItemCount: visitedItemCount)
        return AtomicSummaryWorkResult(partial: partial, pendingItems: pendingItems)
    }

    private nonisolated static func processPooledWorkItemUsingFoundation(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter
    ) throws -> AtomicSummaryWorkResult {
        try cancellationCheck()

        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let warningCollector = AtomicSummaryWarningCollector()
        guard let enumerator = FileManager.default.enumerator(
            at: item.url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicSummaryResourceKeys,
            options: options,
            errorHandler: { childURL, error in
                warningCollector.record(for: childURL, error: error)
                return true
            }
        ) else {
            var partial = AtomicDirectorySummaryPartial()
            partial.recordWarning(
                for: item.url,
                error: NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadUnknownError,
                    userInfo: [NSURLErrorKey: item.url]
                )
            )
            progressReporter.finish(currentURL: item.url, visitedItemCount: 0)
            return AtomicSummaryWorkResult(partial: partial, pendingItems: [])
        }

        var partial = AtomicDirectorySummaryPartial()
        var pendingItems: [AtomicSummaryWorkItem] = []
        var visitedItemCount = 0
        while let nextObject = enumerator.nextObject() {
            try cancellationCheck()
            guard let childURL = nextObject as? URL else { continue }
            visitedItemCount += 1
            if visitedItemCount == 1 || visitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(
                    currentURL: childURL,
                    visitedItemCount: visitedItemCount
                )
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            let childPath = childURL.path
            guard !exclusionMatcher.excludesKnownNormalizedPath(
                childPath,
                isDirectory: hintedIsDirectory
            ) else {
                continue
            }

            let childMetadata: NodeMetadata
            do {
                let values = try childURL.resourceValues(
                    forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet
                )
                childMetadata = metadataLoader.atomicSummaryMetadata(
                    for: childURL,
                    prefetchedResourceValues: values
                )
            } catch {
                partial.recordWarning(for: childURL, error: error)
                continue
            }

            guard childMetadata.isDirectory == hintedIsDirectory ||
                    !exclusionMatcher.excludesKnownNormalizedPath(
                        childPath,
                        isDirectory: childMetadata.isDirectory
                    ) else {
                continue
            }

            partial.updateAccessibility(childMetadata.isReadable)
            guard childMetadata.isDirectory else {
                partial.accumulateFile(
                    childMetadata,
                    url: childURL,
                    ownerNodeID: item.ownerNodeID
                )
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            pendingItems.append(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage
                        ? true
                        : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }

        let localizedWarnings = warningCollector.collectedWarnings()
        if !localizedWarnings.isEmpty {
            partial.isAccessible = false
            partial.warnings.append(contentsOf: localizedWarnings)
        }
        progressReporter.finish(currentURL: item.url, visitedItemCount: visitedItemCount)
        return AtomicSummaryWorkResult(partial: partial, pendingItems: pendingItems)
    }

    nonisolated static func summarizeInParallel(
        at url: URL,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: @escaping CancellationCheck,
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        resumeState: AtomicDirectoryProbeResumeState? = nil,
        forcesFoundationTraversal: Bool = false
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        #if DEBUG
        let resumedSummaryStart = resumeState == nil ? nil : metadataLoader.diagnostics?.start()
        #endif
        let progressReporter = AtomicSummaryProgressReporter(
            metrics: metrics,
            continuation: continuation
        )

        let accumulator = AtomicSummaryAccumulator(seed: resumeState?.partial)
        if resumeState == nil {
            do {
                let rootValues = try url.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
                accumulator.updateAccessibility(rootValues.isReadable ?? false)
            } catch {
                accumulator.recordWarning(for: url, error: error)
            }
        }

        let initialItems = resumeState?.workItems ?? [
            AtomicSummaryWorkItem(
                url: url,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                ownerNodeID: ownerNodeID
            )
        ]
        let queue = AtomicSummaryWorkQueue(items: initialItems)
        let workerCount = max(1, workerLimit)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var workerVisitedItemCount = 0
                    while true {
                        try cancellationCheck()
                        guard let item = try queue.take(cancellationCheck: cancellationCheck) else { return }

                        do {
                            try Self.processWorkItem(
                                item,
                                includeHiddenFiles: includeHiddenFiles,
                                exclusionMatcher: exclusionMatcher,
                                accumulator: accumulator,
                                queue: queue,
                                metadataLoader: metadataLoader,
                                cancellationCheck: cancellationCheck,
                                progressReporter: progressReporter,
                                workerVisitedItemCount: &workerVisitedItemCount,
                                forcesFoundationTraversal: forcesFoundationTraversal
                            )
                            queue.finishCurrentItem()
                        } catch {
                            queue.fail(error)
                            queue.finishCurrentItem()
                            throw error
                        }
                    }
                }
            }

            do {
                try await group.waitForAll()
            } catch {
                queue.fail(error)
                group.cancelAll()
                throw error
            }
        }

        let summary = accumulator.makeSummary()
        #if DEBUG
        if let resumeState {
            metadataLoader.diagnostics?.record(
                operation: "atomic.summary.resumed_probe",
                url: url,
                startedAt: resumedSummaryStart,
                itemCount: resumeState.visitedItemCount,
                detail: "sources=\(resumeState.workItems.count)"
            )
        }
        #endif
        return summary
    }

    private nonisolated static func processWorkItem(
        _ initialItem: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        accumulator: AtomicSummaryAccumulator,
        queue: AtomicSummaryWorkQueue,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter,
        workerVisitedItemCount: inout Int,
        forcesFoundationTraversal: Bool
    ) throws {
        try cancellationCheck()
        var item = initialItem

        if forcesFoundationTraversal {
            try processWorkItemUsingFoundation(
                item,
                includeHiddenFiles: includeHiddenFiles,
                exclusionMatcher: exclusionMatcher,
                accumulator: accumulator,
                queue: queue,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter,
                workerVisitedItemCount: &workerVisitedItemCount
            )
            return
        }

        var partial = AtomicDirectorySummaryPartial()
        var pendingItems: [AtomicSummaryWorkItem] = []
        if item.nextEntryIndex < item.bufferedEntries.count {
            try stageEntries(
                item.bufferedEntries[item.nextEntryIndex...],
                from: item,
                exclusionMatcher: exclusionMatcher,
                partial: &partial,
                pendingItems: &pendingItems,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter,
                workerVisitedItemCount: &workerVisitedItemCount
            )
            item.nextEntryIndex = item.bufferedEntries.count
        }

        var cursor = item.cursor
        if cursor == nil, item.needsCursor {
            do {
                cursor = try BulkDirectoryEnumerator.makeCursor(
                    at: item.url,
                    includeHiddenFiles: includeHiddenFiles,
                    loadsPackageMetadata: !item.treatPackagesAsDirectories,
                    metadataLoader: metadataLoader,
                    cancellationCheck: {
                        do {
                            try cancellationCheck()
                        } catch {
                            throw AtomicSummaryCancellation(underlyingError: error)
                        }
                    }
                )
            } catch let cancellation as AtomicSummaryCancellation {
                throw cancellation.underlyingError
            } catch {
                accumulator.merge(partial)
                for pendingItem in pendingItems {
                    queue.enqueue(pendingItem)
                }
                accumulator.recordWarning(for: item.url, error: error)
                return
            }
        }

        do {
            while let batch = try cursor?.nextBatch(cancellationCheck: {
                do {
                    try cancellationCheck()
                } catch {
                    throw AtomicSummaryCancellation(underlyingError: error)
                }
            }) {
                try stageEntries(
                    batch.entries[...],
                    from: item,
                    exclusionMatcher: exclusionMatcher,
                    partial: &partial,
                    pendingItems: &pendingItems,
                    cancellationCheck: {
                        do {
                            try cancellationCheck()
                        } catch {
                            throw AtomicSummaryCancellation(underlyingError: error)
                        }
                    },
                    progressReporter: progressReporter,
                    workerVisitedItemCount: &workerVisitedItemCount
                )
            }
        } catch let cancellation as AtomicSummaryCancellation {
            throw cancellation.underlyingError
        } catch BulkDirectoryEnumerator.StreamError.unavailable {
            if item.requiresRootRestartOnFallback {
                throw AtomicSummaryRootFallbackRequired()
            }
            try processWorkItemUsingFoundation(
                item,
                includeHiddenFiles: includeHiddenFiles,
                exclusionMatcher: exclusionMatcher,
                accumulator: accumulator,
                queue: queue,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter,
                workerVisitedItemCount: &workerVisitedItemCount
            )
            return
        } catch {
            accumulator.recordWarning(for: item.url, error: error)
            return
        }

        accumulator.merge(partial)
        for pendingItem in pendingItems {
            queue.enqueue(pendingItem)
        }
    }

    private nonisolated static func stageEntries(
        _ entries: ArraySlice<DirectoryEntry>,
        from item: AtomicSummaryWorkItem,
        exclusionMatcher: ScanExclusionMatcher,
        partial: inout AtomicDirectorySummaryPartial,
        pendingItems: inout [AtomicSummaryWorkItem],
        cancellationCheck: CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter,
        workerVisitedItemCount: inout Int
    ) throws {
        for childEntry in entries {
            try cancellationCheck()
            let childURL = childEntry.url
            workerVisitedItemCount += 1
            if workerVisitedItemCount == 1 || workerVisitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(
                    currentURL: childURL,
                    visitedItemCount: workerVisitedItemCount
                )
            }

            let hintedIsDirectory = childEntry.isDirectoryHint ?? childURL.hasDirectoryPath
            let childPath = childURL.path
            guard !exclusionMatcher.excludesKnownNormalizedPath(
                childPath,
                isDirectory: hintedIsDirectory
            ) else {
                continue
            }

            guard let childMetadata = childEntry.metadata else {
                partial.recordWarning(
                    for: childURL,
                    error: childEntry.localizedEnumerationError ?? NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileReadUnknownError,
                        userInfo: [NSURLErrorKey: childURL]
                    )
                )
                continue
            }

            guard childMetadata.isDirectory == hintedIsDirectory ||
                    !exclusionMatcher.excludesKnownNormalizedPath(
                        childPath,
                        isDirectory: childMetadata.isDirectory
                    ) else {
                continue
            }

            partial.updateAccessibility(childMetadata.isReadable)
            guard childMetadata.isDirectory else {
                partial.accumulateFile(childMetadata, url: childURL, ownerNodeID: item.ownerNodeID)
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            pendingItems.append(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
    }

    /// Compatibility path for filesystems that do not support the requested
    /// `getattrlistbulk` attributes. Supported Darwin filesystems stay on the
    /// native batched path above and never load per-child resource values.
    private nonisolated static func processWorkItemUsingFoundation(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        accumulator: AtomicSummaryAccumulator,
        queue: AtomicSummaryWorkQueue,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter,
        workerVisitedItemCount: inout Int
    ) throws {
        try cancellationCheck()

        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: item.url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicSummaryResourceKeys,
            options: options,
            errorHandler: { childURL, error in
                accumulator.recordWarning(for: childURL, error: error)
                return true
            }
        ) else {
            accumulator.recordWarning(
                for: item.url,
                error: NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadUnknownError,
                    userInfo: [NSURLErrorKey: item.url]
                )
            )
            return
        }

        var partial = AtomicDirectorySummaryPartial()
        while let nextObject = enumerator.nextObject() {
            try cancellationCheck()
            guard let childURL = nextObject as? URL else { continue }
            workerVisitedItemCount += 1
            if workerVisitedItemCount == 1 || workerVisitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(
                    currentURL: childURL,
                    visitedItemCount: workerVisitedItemCount
                )
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            let childPath = childURL.path
            guard !exclusionMatcher.excludesKnownNormalizedPath(
                childPath,
                isDirectory: hintedIsDirectory
            ) else {
                continue
            }

            let childMetadata: NodeMetadata
            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
                childMetadata = metadataLoader.atomicSummaryMetadata(for: childURL, prefetchedResourceValues: values)
            } catch {
                partial.recordWarning(for: childURL, error: error)
                continue
            }

            guard childMetadata.isDirectory == hintedIsDirectory ||
                    !exclusionMatcher.excludesKnownNormalizedPath(
                        childPath,
                        isDirectory: childMetadata.isDirectory
                    ) else {
                continue
            }

            partial.updateAccessibility(childMetadata.isReadable)

            guard childMetadata.isDirectory else {
                partial.accumulateFile(childMetadata, url: childURL, ownerNodeID: item.ownerNodeID)
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            queue.enqueue(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
        accumulator.merge(partial)
    }
}
