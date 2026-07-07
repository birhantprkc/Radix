//
//  AtomicDirectoryParallelSummary.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated private struct AtomicSummaryWorkItem: Sendable {
    let url: URL
    let treatPackagesAsDirectories: Bool
    let ownerNodeID: String
}

nonisolated private final class AtomicSummaryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pendingItems: [AtomicSummaryWorkItem]
    private var activeItemCount = 0
    private var failure: Error?

    init(rootItem: AtomicSummaryWorkItem) {
        pendingItems = [rootItem]
    }

    func take() throws -> AtomicSummaryWorkItem? {
        condition.lock()
        defer { condition.unlock() }

        while pendingItems.isEmpty, activeItemCount > 0, failure == nil {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            try Task.checkCancellation()
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

nonisolated private final class AtomicSummaryAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var allocatedSize: Int64 = 0
    private var logicalSize: Int64 = 0
    private var descendantFileCount = 0
    private var isAccessible = true
    private var warnings: [ScanWarning] = []
    private var hardLinkClaims: [HardLinkClaim] = []
    private var visitedItemCount = 0

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

    func merge(_ partial: AtomicSummaryPartial) {
        lock.lock()
        allocatedSize += partial.allocatedSize
        logicalSize += partial.logicalSize
        descendantFileCount += partial.descendantFileCount
        isAccessible = isAccessible && partial.isAccessible
        warnings.append(contentsOf: partial.warnings)
        hardLinkClaims.append(contentsOf: partial.hardLinkClaims)
        visitedItemCount += partial.visitedItemCount
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

nonisolated private struct AtomicSummaryPartial: Sendable {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var descendantFileCount = 0
    var isAccessible = true
    var warnings: [ScanWarning] = []
    var hardLinkClaims: [HardLinkClaim] = []
    var visitedItemCount = 0

    mutating func recordVisitedItem() {
        visitedItemCount += 1
    }

    mutating func updateAccessibility(_ readable: Bool) {
        isAccessible = isAccessible && readable
    }

    mutating func recordWarning(for url: URL, error: Error) {
        isAccessible = false
        warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
    }

    mutating func accumulateFile(_ metadata: NodeMetadata, url: URL, ownerNodeID: String) {
        allocatedSize += metadata.allocatedSize
        logicalSize += metadata.logicalSize
        if !metadata.isSymbolicLink {
            descendantFileCount += 1
        }
        if metadata.linkCount > 1,
           let claim = HardLinkDeduplicator.claim(for: metadata, ownerNodeID: ownerNodeID, path: url.path) {
            hardLinkClaims.append(claim)
        }
    }
}

nonisolated private final class AtomicSummaryProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: ScanMetrics
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private var lastEmission = Date.distantPast
    private var hasEmitted = false

    init(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) {
        self.metrics = metrics
        self.continuation = continuation
    }

    func emit(currentURL: URL) {
        lock.lock()
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
}

extension AtomicDirectorySummarizer {
    nonisolated static func summarizeInParallel(
        at url: URL,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> AtomicDirectorySummary? {
        try Task.checkCancellation()
        let progressReporter = AtomicSummaryProgressReporter(
            metrics: metrics,
            continuation: continuation
        )

        let accumulator = AtomicSummaryAccumulator()
        do {
            let rootValues = try url.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
            accumulator.updateAccessibility(rootValues.isReadable ?? false)
        } catch {
            accumulator.recordWarning(for: url, error: error)
        }

        let queue = AtomicSummaryWorkQueue(
            rootItem: AtomicSummaryWorkItem(
                url: url,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                ownerNodeID: ownerNodeID
            )
        )
        let workerCount = max(1, workerLimit)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var workerVisitedItemCount = 0
                    while true {
                        try Task.checkCancellation()
                        guard let item = try queue.take() else { return }

                        do {
                            try Self.processWorkItem(
                                item,
                                includeHiddenFiles: includeHiddenFiles,
                                exclusionMatcher: exclusionMatcher,
                                accumulator: accumulator,
                                queue: queue,
                                metadataLoader: metadataLoader,
                                progressReporter: progressReporter,
                                workerVisitedItemCount: &workerVisitedItemCount
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

        return accumulator.makeSummary()
    }

    private nonisolated static func processWorkItem(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        accumulator: AtomicSummaryAccumulator,
        queue: AtomicSummaryWorkQueue,
        metadataLoader: ScanMetadataLoader,
        progressReporter: AtomicSummaryProgressReporter,
        workerVisitedItemCount: inout Int
    ) throws {
        try Task.checkCancellation()

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

        var partial = AtomicSummaryPartial()
        while let nextObject = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let childURL = nextObject as? URL else { continue }
            partial.recordVisitedItem()
            workerVisitedItemCount += 1
            if workerVisitedItemCount == 1 || workerVisitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(currentURL: childURL)
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            guard !exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) else {
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

            guard !exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) else {
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
