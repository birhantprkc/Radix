//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Darwin
import Dispatch
import Foundation

private nonisolated final class DirectoryNamespaceResolver: @unchecked Sendable {
    private struct Mapping {
        let presentedRootPath: String
        let resolvedRootPath: String
    }

    private let lock = NSLock()
    private var mappings: [Mapping] = []

    func preservingParentNamespace(_ contents: [URL], under parentURL: URL) -> [URL] {
        let parentPath = parentURL.path
        guard let enumeratedParentPath = contents.lazy
            .map({ $0.deletingLastPathComponent().path })
            .first(where: { $0 != parentPath }) else {
            return contents
        }

        if let resolvedParentPath = cachedResolvedPath(
            forPresentedPath: parentPath,
            matching: enumeratedParentPath
        ) {
            return replacingParentNamespace(
                in: contents,
                from: resolvedParentPath,
                to: parentURL
            )
        }

        guard let resolvedParentPath = resolvedFileSystemPath(parentURL),
              resolvedParentPath != parentPath,
              enumeratedParentPath == resolvedParentPath else {
            return contents
        }
        cacheMapping(
            presentedRootPath: parentPath,
            resolvedRootPath: resolvedParentPath
        )
        return replacingParentNamespace(
            in: contents,
            from: resolvedParentPath,
            to: parentURL
        )
    }

    private func cachedResolvedPath(
        forPresentedPath presentedPath: String,
        matching candidate: String
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        for mapping in mappings {
            guard let suffix = pathSuffix(presentedPath, under: mapping.presentedRootPath) else {
                continue
            }
            let resolvedPath = mapping.resolvedRootPath + suffix
            if candidate == resolvedPath {
                return resolvedPath
            }
        }
        return nil
    }

    private func cacheMapping(presentedRootPath: String, resolvedRootPath: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !mappings.contains(where: {
            $0.presentedRootPath == presentedRootPath && $0.resolvedRootPath == resolvedRootPath
        }) else {
            return
        }
        mappings.append(Mapping(
            presentedRootPath: presentedRootPath,
            resolvedRootPath: resolvedRootPath
        ))
    }

    private func pathSuffix(_ path: String, under rootPath: String) -> String? {
        if path == rootPath {
            return ""
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    private func replacingParentNamespace(
        in contents: [URL],
        from resolvedParentPath: String,
        to presentedParentURL: URL
    ) -> [URL] {
        contents.map { childURL in
            guard childURL.deletingLastPathComponent().path == resolvedParentPath else {
                return childURL
            }
            let parentPath = presentedParentURL.path
            let childPath = parentPath == "/"
                ? parentPath + childURL.lastPathComponent
                : parentPath + "/" + childURL.lastPathComponent
            return URL(
                filePath: childPath,
                directoryHint: childURL.hasDirectoryPath ? .isDirectory : .notDirectory
            )
        }
    }

    private func resolvedFileSystemPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolvedPath = realpath(path, nil) else { return nil }
            defer { free(resolvedPath) }
            return String(cString: resolvedPath)
        }
    }
}

actor ScanEngine {
    protocol DirectoryObjectEnumerating: AnyObject {
        func nextObject() -> Any?
    }

    private enum ScanEngineError: LocalizedError {
        case missingRootNode

        var errorDescription: String? {
            switch self {
            case .missingRootNode:
                return String(localized: "The scan could not assemble a root node.", comment: "Error shown when a completed scan has no root node.")
            }
        }
    }

    struct ScanBehavior: Sendable {
        let excludesStartupVolumeInternals: Bool

        static let standard = ScanBehavior(excludesStartupVolumeInternals: false)
    }

    private struct AggregateStatsAccumulator {
        private(set) var fileCount = 0
        private(set) var directoryCount = 0
        private(set) var accessibleItemCount = 0
        private(set) var inaccessibleItemCount = 0

        mutating func include(_ node: FileNodeRecord, hasChildren: Bool) {
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && !hasChildren {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        func makeStats(root: FileNodeRecord) -> ScanAggregateStats {
            ScanAggregateStats(
                totalAllocatedSize: root.allocatedSize,
                totalLogicalSize: root.logicalSize,
                fileCount: fileCount,
                directoryCount: directoryCount,
                accessibleItemCount: accessibleItemCount,
                inaccessibleItemCount: inaccessibleItemCount
            )
        }
    }

    /// A work item for the iterative scanner.
    /// `parentKey` links this item back to its parent for bottom-up assembly.
    /// `depth` tracks how deep we are in the directory tree.
    /// `weight` is this subtree's share of the scan's total progress (the root is 1);
    /// a directory's weight is split among its children when it is enumerated.
    private struct ScanWorkItem: Sendable {
        let url: URL
        let metadata: NodeMetadata?
        let localizedEnumerationError: Error?
        let isDirectoryHint: Bool?
        let parentKey: Int
        let depth: Int
        let weight: Double
        let parentDirectoryLease: ScanDirectoryDescriptorPool.Lease?
        let nativeName: BulkDirectoryEnumerator.NativeName?

        init(
            url: URL,
            metadata: NodeMetadata?,
            localizedEnumerationError: Error?,
            isDirectoryHint: Bool?,
            parentKey: Int,
            depth: Int,
            weight: Double,
            parentDirectoryLease: ScanDirectoryDescriptorPool.Lease? = nil,
            nativeName: BulkDirectoryEnumerator.NativeName? = nil
        ) {
            self.url = url
            self.metadata = metadata
            self.localizedEnumerationError = localizedEnumerationError
            self.isDirectoryHint = isDirectoryHint
            self.parentKey = parentKey
            self.depth = depth
            self.weight = weight
            self.parentDirectoryLease = parentDirectoryLease
            self.nativeName = nativeName
        }
    }

    struct DirectoryEnumerationFailure: Sendable {
        let url: URL
        let error: Error
        let isDirectoryHint: Bool?

        init(url: URL, error: Error, isDirectoryHint: Bool? = nil) {
            self.url = url
            self.error = error
            self.isDirectoryHint = isDirectoryHint
        }
    }

    struct DirectoryEnumerationResult: Sendable {
        let urls: [URL]
        let localizedFailures: [DirectoryEnumerationFailure]

        init(urls: [URL], localizedFailures: [DirectoryEnumerationFailure] = []) {
            self.urls = urls
            self.localizedFailures = localizedFailures
        }
    }

    private struct DirectoryContentsScanResult: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
        let directoryLease: ScanDirectoryDescriptorPool.Lease?
        #if DEBUG
        let enumerationNanoseconds: UInt64
        let classificationNanoseconds: UInt64
        #endif
    }

    private struct ClassifiedDirectoryEntriesChunk: Sendable {
        let index: Int
        let entries: [DirectoryEntry]
    }

    private struct DirectoryTraversalSuccess: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: DirectoryContentsScanResult
    }

    private struct DirectoryTraversalFailure: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let warning: ScanWarning
        #if DEBUG
        let elapsedNanoseconds: UInt64
        let diagnosticDetail: String
        #endif

        #if DEBUG
        init(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            warning: ScanWarning,
            elapsedNanoseconds: UInt64,
            diagnosticDetail: String
        ) {
            self.item = item
            self.itemKey = itemKey
            self.metadata = metadata
            self.warning = warning
            self.elapsedNanoseconds = elapsedNanoseconds
            self.diagnosticDetail = diagnosticDetail
        }
        #else
        init(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            warning: ScanWarning
        ) {
            self.item = item
            self.itemKey = itemKey
            self.metadata = metadata
            self.warning = warning
        }
        #endif
    }

    private enum DirectoryTraversalResult: Sendable {
        case success(DirectoryTraversalSuccess)
        case failure(DirectoryTraversalFailure)
    }

    private struct LeafNodeResult: Sendable {
        let node: FileNodeRecord
        let warnings: [ScanWarning]
        let hardLinkAccumulator: HardLinkIdentityOwnerAccumulator
        let minimumAllocatedSize: Int64?
    }

    private struct PackageSummaryResult: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let leaf: LeafNodeResult
    }

    /// An enumerated directory that passed the cheap atomic-summary gates and is
    /// waiting for (or has finished) its pooled probe/summary off the scheduling loop.
    private struct AtomicDirectoryScanCandidate: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: DirectoryContentsScanResult
        let childDirectoryCount: Int
        let totalWeightUnits: Double
        let isNodeDependencyLayout: Bool
    }

    private struct AtomicDirectoryScanResult: Sendable {
        let candidate: AtomicDirectoryScanCandidate
        /// nil when the probe decided the directory should be expanded normally.
        let summary: AtomicDirectorySummary?
    }

    private enum ScanTaskResult: Sendable {
        case directory(DirectoryTraversalResult)
        case package(PackageSummaryResult)
        case atomicDirectory(AtomicDirectoryScanResult)
    }

    /// A completed directory scan awaiting parent assembly.
    private struct CompletedDirScan {
        let node: FileNodeRecord?     // Leaves carry a node; traversable dirs are resolved in phase 2.
        let metadata: NodeMetadata
        let url: URL
        let isTraversable: Bool     // True if this was a directory we intended to traverse.
    }

    typealias DirectoryContentsProvider = @Sendable (
        URL,
        [URLResourceKey]?,
        FileManager.DirectoryEnumerationOptions,
        @Sendable () throws -> Void
    ) throws -> DirectoryEnumerationResult

    typealias URLDirectoryContentsProvider = @Sendable (
        URL,
        [URLResourceKey]?,
        FileManager.DirectoryEnumerationOptions,
        @Sendable () throws -> Void
    ) throws -> [URL]

    typealias VolumeFileSystemTypeProvider = @Sendable (URL) -> String?
    typealias DirectoryDescriptorPoolFactory = @Sendable () -> ScanDirectoryDescriptorPool

    private let directoryContents: DirectoryContentsProvider
    private let usesBulkDirectoryEnumeration: Bool
    private let directoryNamespaceResolver: DirectoryNamespaceResolver
    private let linkCountCapabilityCache: LinkCountCapabilityCache
    private let atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver?
    private let atomicSummaryProgressEmissionInterval: TimeInterval
    private let volumeFileSystemTypeProvider: VolumeFileSystemTypeProvider
    private let directoryDescriptorPoolFactory: DirectoryDescriptorPoolFactory
    private let diagnostics: ScanDiagnosticsContext?

    init(
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver? = nil,
        atomicSummaryProgressEmissionInterval: TimeInterval = 0.15,
        directoryDescriptorPoolFactory: @escaping DirectoryDescriptorPoolFactory = {
            ScanDirectoryDescriptorPool()
        }
    ) {
        self.init(
            enumeratedDirectoryContents: ScanEngine.defaultDirectoryContents,
            volumeFileSystemTypeProvider: volumeFileSystemTypeProvider,
            usesBulkDirectoryEnumeration: true,
            atomicSummaryWorkerObserver: atomicSummaryWorkerObserver,
            atomicSummaryProgressEmissionInterval: atomicSummaryProgressEmissionInterval,
            directoryDescriptorPoolFactory: directoryDescriptorPoolFactory
        )
    }

    init(
        enumeratedDirectoryContents: @escaping DirectoryContentsProvider,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver? = nil,
        atomicSummaryProgressEmissionInterval: TimeInterval = 0.15
    ) {
        self.init(
            enumeratedDirectoryContents: enumeratedDirectoryContents,
            volumeFileSystemTypeProvider: volumeFileSystemTypeProvider,
            usesBulkDirectoryEnumeration: false,
            atomicSummaryWorkerObserver: atomicSummaryWorkerObserver,
            atomicSummaryProgressEmissionInterval: atomicSummaryProgressEmissionInterval,
            directoryDescriptorPoolFactory: { ScanDirectoryDescriptorPool() }
        )
    }

    private init(
        enumeratedDirectoryContents: @escaping DirectoryContentsProvider,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider,
        usesBulkDirectoryEnumeration: Bool,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver?,
        atomicSummaryProgressEmissionInterval: TimeInterval,
        directoryDescriptorPoolFactory: @escaping DirectoryDescriptorPoolFactory
    ) {
        #if DEBUG
        let diagnostics = ScanDiagnostics.makeIfEnabled()
        #else
        let diagnostics: ScanDiagnosticsContext? = nil
        #endif
        self.directoryContents = enumeratedDirectoryContents
        self.usesBulkDirectoryEnumeration = usesBulkDirectoryEnumeration
        self.directoryNamespaceResolver = DirectoryNamespaceResolver()
        self.linkCountCapabilityCache = LinkCountCapabilityCache()
        self.atomicSummaryWorkerObserver = atomicSummaryWorkerObserver
        self.atomicSummaryProgressEmissionInterval = max(atomicSummaryProgressEmissionInterval, 0)
        self.volumeFileSystemTypeProvider = volumeFileSystemTypeProvider
        self.directoryDescriptorPoolFactory = directoryDescriptorPoolFactory
        self.diagnostics = diagnostics
    }

    init(
        directoryContents: @escaping URLDirectoryContentsProvider,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver? = nil,
        atomicSummaryProgressEmissionInterval: TimeInterval = 0.15
    ) {
        self.init(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            let urls = try directoryContents(url, keys, options, cancellationCheck)
            return DirectoryEnumerationResult(urls: urls)
        }, volumeFileSystemTypeProvider: volumeFileSystemTypeProvider,
           atomicSummaryWorkerObserver: atomicSummaryWorkerObserver,
           atomicSummaryProgressEmissionInterval: atomicSummaryProgressEmissionInterval)
    }

    private nonisolated static func defaultDirectoryContents(
        url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> DirectoryEnumerationResult {
        var rootEnumerationError: Error?
        var localizedFailures: [DirectoryEnumerationFailure] = []
        let rootPath = url.standardizedFileURL.path
        return try enumeratedDirectoryContents(
            url: url,
            keys: keys,
            options: options,
            cancellationCheck: cancellationCheck,
            makeEnumerator: { url, keys, options in
                FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: options,
                    errorHandler: { failedURL, error in
                        if failedURL.standardizedFileURL.path == rootPath {
                            rootEnumerationError = error
                            return false
                        }
                        localizedFailures.append(
                            DirectoryEnumerationFailure(
                                url: failedURL,
                                error: error,
                                isDirectoryHint: true
                            )
                        )
                        return true
                    }
                )
            },
            enumerationError: { rootEnumerationError },
            localizedEnumerationFailures: { localizedFailures }
        )
    }

    private nonisolated static func defaultVolumeFileSystemType(for url: URL) -> String? {
        var fileSystemStats = statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &fileSystemStats)
        }
        guard result == 0 else { return nil }

        return withUnsafeBytes(of: fileSystemStats.f_fstypename) { rawBuffer -> String? in
            let buffer = rawBuffer.bindMemory(to: CChar.self)
            guard let baseAddress = buffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    nonisolated static func enumeratedDirectoryContents(
        url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        cancellationCheck: @Sendable () throws -> Void,
        makeEnumerator: (
            URL,
            [URLResourceKey]?,
            FileManager.DirectoryEnumerationOptions
        ) -> (any DirectoryObjectEnumerating)?,
        enumerationError: () -> Error? = { nil },
        localizedEnumerationFailures: () -> [DirectoryEnumerationFailure] = { [] }
    ) throws -> DirectoryEnumerationResult {
        try cancellationCheck()
        guard let enumerator = makeEnumerator(url, keys, options) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSURLErrorKey: url]
            )
        }

        var contents: [URL] = []
        while let nextObject = enumerator.nextObject() {
            try cancellationCheck()
            if let enumerationError = enumerationError() {
                throw enumerationError
            }
            guard let childURL = nextObject as? URL else { continue }
            contents.append(childURL)
        }

        if let enumerationError = enumerationError() {
            throw enumerationError
        }
        try cancellationCheck()
        return DirectoryEnumerationResult(
            urls: contents,
            localizedFailures: localizedEnumerationFailures()
        )
    }

    /// Thresholds for automatically summarizing directories with many small files.
    /// Directories exceeding BOTH thresholds are treated as atomic (not expanded).
    private enum AtomicDirectoryThresholds {
        /// Minimum file count to consider a directory for atomic treatment
        static let minFileCount = 5_000
        /// Maximum average file size (in bytes) to consider for atomic treatment
        /// Below this suggests files are tiny/cached/irrelevant (npm, caches, etc.)
        static let maxAverageFileSize: Int64 = 4_096  // 4 KB average
        /// Minimum depth at which atomic treatment applies
        /// (depth 0 = scan root, depth 1 = immediate children, etc.)
        static let minDepthForSummarization = 2
    }

    private enum ScanConcurrencyPolicy {
        static let directoryClassificationParallelThreshold = 128
        // Shared budget for concurrent child metadata reads across traversal and classification workers.
        static let directoryMetadataWorkerBudgetMaximum = 16

        static func atomicSummaryWorkerLimit(for options: ScanOptions) -> Int {
            if let optionLimit = options.atomicSummaryWorkerLimit {
                return max(1, optionLimit)
            }

            if let environmentLimit = ProcessInfo.processInfo.environment["RADIX_SCAN_ATOMIC_SUMMARY_WORKERS"]
                .flatMap(Int.init) {
                return max(1, environmentLimit)
            }

            return hardwareAwareWorkerLimit(minimum: 4, processorDivisor: 1, maximum: 8)
        }

        static func directoryTraversalWorkerLimit(for options: ScanOptions) -> Int {
            if let optionLimit = options.directoryTraversalWorkerLimit {
                return max(1, optionLimit)
            }

            if let environmentLimit = ProcessInfo.processInfo.environment["RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS"]
                .flatMap(Int.init) {
                return max(1, environmentLimit)
            }

            return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8)
        }

        static func directoryClassificationWorkerLimit(for options: ScanOptions) -> Int {
            if let optionLimit = options.directoryClassificationWorkerLimit {
                return max(1, optionLimit)
            }

            if let environmentLimit = ProcessInfo.processInfo.environment["RADIX_SCAN_DIRECTORY_CLASSIFICATION_WORKERS"]
                .flatMap(Int.init) {
                return max(1, environmentLimit)
            }

            return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8)
        }

        static func effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: Int,
            classificationWorkerLimit: Int
        ) -> Int {
            guard traversalWorkerLimit > 1 else {
                return classificationWorkerLimit
            }

            let sharedMetadataBudget = sharedMetadataWorkerBudget()
            let perDirectoryLimit = max(1, sharedMetadataBudget / max(1, traversalWorkerLimit))
            return min(classificationWorkerLimit, perDirectoryLimit)
        }

        private static func sharedMetadataWorkerBudget() -> Int {
            let processInfo = ProcessInfo.processInfo
            let activeProcessorCount = max(1, processInfo.activeProcessorCount)
            var limit = min(
                max(4, activeProcessorCount * 2),
                directoryMetadataWorkerBudgetMaximum
            )

            if processInfo.isLowPowerModeEnabled {
                limit = max(1, limit / 2)
            }

            switch processInfo.thermalState {
            case .serious, .critical:
                limit = max(1, limit / 2)
            case .fair:
                limit = max(1, limit - 2)
            case .nominal:
                break
            @unknown default:
                break
            }

            return limit
        }

        private static func hardwareAwareWorkerLimit(
            minimum: Int,
            processorDivisor: Int,
            maximum: Int
        ) -> Int {
            let processInfo = ProcessInfo.processInfo
            let activeProcessorCount = max(1, processInfo.activeProcessorCount)
            var limit = min(max(minimum, activeProcessorCount / max(1, processorDivisor)), maximum)

            if processInfo.isLowPowerModeEnabled {
                limit = max(1, limit / 2)
            }

            switch processInfo.thermalState {
            case .serious, .critical:
                limit = max(1, limit / 2)
            case .fair:
                limit = max(1, limit - 1)
            case .nominal:
                break
            @unknown default:
                break
            }

            return limit
        }
    }

    nonisolated func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    let snapshot = try await self.performScan(
                        target: target,
                        options: options,
                        continuation: continuation
                    )
                    continuation.yield(.finished(snapshot))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // The scan path (`performScan` and the helpers it calls) is `nonisolated` on
    // purpose. `ScanEngine`'s stored properties are all `let`, so the scan holds no
    // actor-mutable state and isolation bought us nothing but serialization on the
    // actor's executor — which let a previous, still-cancelling scan block a freshly
    // started one from running. Keeping these `nonisolated` is what allows overlapping
    // scans to make progress independently. Do not re-isolate without reintroducing
    // that bug (see testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling).
    private nonisolated func performScan(
        target: ScanTarget,
        options: ScanOptions,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> ScanSnapshot {
        let startedAt = Date()
        var metrics = ScanMetrics()
        var warnings: [ScanWarning] = []
        var emissionState = ScanEmissionState()
        let behavior = ScanBehavior(
            excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? target.url.path,
            includeCloudStorage: options.includeCloudStorage,
            cloudStorageRootPath: options.cloudStorageRootPath,
            iCloudDriveRootPath: options.iCloudDriveRootPath
        )

        let treeStore = try await scanDirectory(
            target: target,
            includeVolumeDetails: true,
            options: options,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            metrics: &metrics,
            warnings: &warnings,
            continuation: continuation,
            emissionState: &emissionState
        )
        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        continuation.yield(.progress(metrics))

        if let overlappingBytes = VolumeCapacityAccounting.overlappingAllocatedBytes(
            in: treeStore,
            capacity: metrics.volumeCapacity
        ) {
            let warning = ScanWarning(
                path: target.url.path,
                message: "File allocations overlap by \(overlappingBytes) bytes; APFS clones or files changed during the scan may share physical storage.",
                category: .fileSystem
            )
            warnings.append(warning)
            continuation.yield(.warning(warning))
        }

        let snapshot = makeSnapshot(
            target: target,
            treeStore: treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            warnings: warnings,
            isComplete: true,
            scanOptions: options,
            volumeCapacity: metrics.volumeCapacity,
            reconcilesVolumeCapacity: metrics.estimatedTotalBytes > 0,
            hasActiveExclusions: !exclusionMatcher.isEmpty
        )

        metrics.isFinalizing = false
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        #if DEBUG
        if let diagnostics {
            print(diagnostics.makeReport(targetPath: target.url.path, elapsedSeconds: Date().timeIntervalSince(startedAt)))
        }
        #endif
        return snapshot
    }

    // MARK: - Iterative Directory Scanning

    /// Scans a directory iteratively (no recursion) and returns a fully assembled flat tree.
    private nonisolated func scanDirectory(
        target: ScanTarget,
        includeVolumeDetails: Bool,
        options: ScanOptions,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> FileTreeStore {
        try Task.checkCancellation()
        let cancellationCheck: CancellationCheck = { try Task.checkCancellation() }
        let scanMetadataLoader = ScanMetadataLoader(
            diagnostics: diagnostics,
            linkCountCapabilityCache: linkCountCapabilityCache
        )
        let rootMetadata = try scanMetadataLoader.metadata(for: target.url, includeVolumeDetails: includeVolumeDetails)
        metrics.discoveredItems = 1
        metrics.volumeCapacity = target.kind == .volume ? rootMetadata.volumeCapacity : nil
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()
        var hardLinkAccumulator = HardLinkIdentityOwnerAccumulator()
        var minimumAllocatedSizeByNodeID: [String: Int64] = [:]
        let atomicSummaryWorkerLimit = ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options)
        let atomicSummaryPool = AtomicDirectorySummaryPool(
            workerLimit: atomicSummaryWorkerLimit,
            workerObserver: atomicSummaryWorkerObserver,
            progressEmissionInterval: atomicSummaryProgressEmissionInterval
        )
        atomicSummaryPool.start()
        let scanAtomicDirectorySummarizer = AtomicDirectorySummarizer(
            metadataLoader: scanMetadataLoader,
            diagnostics: diagnostics,
            summaryPool: atomicSummaryPool
        )
        let directoryTraversalWorkerLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(for: options)
        let directoryClassificationWorkerLimit = ScanConcurrencyPolicy.directoryClassificationWorkerLimit(for: options)
        let effectiveDirectoryClassificationWorkerLimit = ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: directoryTraversalWorkerLimit,
            classificationWorkerLimit: directoryClassificationWorkerLimit
        )
        let directoryContentsProvider = directoryContents
        let usesBulkDirectoryEnumeration = usesBulkDirectoryEnumeration
        let directoryNamespaceResolver = directoryNamespaceResolver
        let directoryDescriptorPool = usesBulkDirectoryEnumeration
            ? directoryDescriptorPoolFactory()
            : nil
        let directoryResourceKeys = ScanMetadataLoader.scanResourceKeys

        do {
        // If the root itself shouldn't be traversed, return a leaf node.
        guard shouldTraverseDirectory(metadata: rootMetadata, options: options) else {
            let leafResult = try await makeLeafNode(
                url: target.url,
                metadata: rootMetadata,
                options: options,
                exclusionMatcher: exclusionMatcher,
                atomicDirectorySummarizer: scanAtomicDirectorySummarizer,
                progressWeight: 1,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            hardLinkAccumulator.merge(leafResult.hardLinkAccumulator)
            if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
            }
            applyLeafMetrics(leafResult.node, weight: 1, metrics: &metrics)
            if !leafResult.warnings.isEmpty {
                warnings.append(contentsOf: leafResult.warnings)
                for warning in leafResult.warnings {
                    continuation.yield(.warning(warning))
                }
            }
            metrics.recalculateProgress()
            atomicSummaryPool.updateProgress(
                &metrics,
                continuation: continuation,
                force: true
            )
            let rawStore = FileTreeStore(root: leafResult.node)
            let store = HardLinkDeduplicator.deduplicatedStore(
                rootID: leafResult.node.id,
                nodesByID: [leafResult.node.id: leafResult.node],
                childIDsByID: [:],
                parentIDByID: [:],
                aggregateStats: rawStore.aggregateStats,
                hardLinkAccumulator: hardLinkAccumulator,
                minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
            )
            await atomicSummaryPool.finish()
            return store
        }

        // Phase 1: Walk the tree iteratively, collecting completed nodes by key.
        // We use a stack for DFS. Each item knows its parent key and depth for assembly.
        metrics.discoveredDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        var workStack: [ScanWorkItem] = [
            ScanWorkItem(
                url: target.url,
                metadata: rootMetadata,
                localizedEnumerationError: nil,
                isDirectoryHint: nil,
                parentKey: -1,
                depth: 0,
                weight: 1
            )
        ]
        // Maps a key to its completed result (leaf or assembled directory).
        var completedByKey: [CompletedDirScan?] = []
        // Maps parent key → child keys, built during phase 1.
        var childrenKeysByKey: [[Int]?] = []
        var seenScannedNodeIDs = Set<String>()
        var nextKey = 0

        try await withThrowingTaskGroup(of: ScanTaskResult.self) { group in
            var activeDirectoryTasks = 0
            var activePackageTasks = 0
            let packageSummaryRequestLimit = max(1, atomicSummaryWorkerLimit * 2)
            // Packages and atomic-summary candidates waiting for a summary-request slot.
            // They must not be summarized inline in the scheduling loop: awaiting a pool
            // job there stops the group from being drained, freezing progress bookkeeping
            // until the stack unwinds.
            var pendingPackageScans: [(item: ScanWorkItem, itemKey: Int, metadata: NodeMetadata)] = []
            var pendingAtomicScans: [AtomicDirectoryScanCandidate] = []
            let autoSummarizeMinFileCount = options.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
            let autoSummarizeMaxAverageFileSize = options.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize
            let autoSummarizeMinDepth = options.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization

            while true {
                while activeDirectoryTasks < directoryTraversalWorkerLimit,
                      let item = workStack.popLast() {
                    try Task.checkCancellation()

                    guard seenScannedNodeIDs.insert(item.url.path).inserted else {
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        recordDuplicateNode(
                            at: item.url,
                            weight: item.weight,
                            metrics: &metrics,
                            warnings: &warnings,
                            continuation: continuation,
                            emissionState: &emissionState,
                            summaryPool: atomicSummaryPool
                        )
                        continue
                    }

                    let itemKey = nextKey
                    nextKey += 1
                    completedByKey.append(nil)
                    childrenKeysByKey.append(nil)

                    // Register this child with its parent (skip root which has parentKey -1).
                    if item.parentKey >= 0 {
                        if childrenKeysByKey[item.parentKey] == nil {
                            childrenKeysByKey[item.parentKey] = []
                        }
                        childrenKeysByKey[item.parentKey]!.append(itemKey)
                    }

                    let meta: NodeMetadata
                    if let localizedEnumerationError = item.localizedEnumerationError {
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        recordUnavailableItem(
                            item,
                            itemKey: itemKey,
                            error: localizedEnumerationError,
                            metrics: &metrics,
                            warnings: &warnings,
                            continuation: continuation,
                            emissionState: &emissionState,
                            summaryPool: atomicSummaryPool,
                            completedByKey: &completedByKey
                        )
                        continue
                    } else if let itemMetadata = item.metadata {
                        meta = itemMetadata
                    } else {
                        do {
                            meta = try scanMetadataLoader.metadata(for: item.url)
                        } catch {
                            releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                            recordUnavailableItem(
                                item,
                                itemKey: itemKey,
                                error: error,
                                metrics: &metrics,
                                warnings: &warnings,
                                continuation: continuation,
                                emissionState: &emissionState,
                                summaryPool: atomicSummaryPool,
                                completedByKey: &completedByKey
                            )
                            continue
                        }
                    }
                    metrics.currentPath = item.url.path

                    if shouldTraverseDirectory(metadata: meta, options: options) {
                        metrics.directoriesVisited += 1
                        maybeEmitProgress(metrics: &metrics, continuation: continuation, emissionState: &emissionState, summaryPool: atomicSummaryPool)

                        let taskItem = item
                        let taskItemKey = itemKey
                        let taskMetadata = meta
                        activeDirectoryTasks += 1
                        group.addTask {
                            #if DEBUG
                            let traversalStart = DispatchTime.now().uptimeNanoseconds
                            #endif
                            do {
                                let contents = try await ScanEngine.directoryEntries(
                                    of: taskItem.url,
                                    includeHiddenFiles: options.includeHiddenFiles,
                                    behavior: behavior,
                                    exclusionMatcher: exclusionMatcher,
                                    resourceKeys: directoryResourceKeys,
                                    metadataLoader: scanMetadataLoader,
                                    directoryContents: directoryContentsProvider,
                                    usesBulkDirectoryEnumeration: usesBulkDirectoryEnumeration,
                                    directoryNamespaceResolver: directoryNamespaceResolver,
                                    directoryDescriptorPool: directoryDescriptorPool,
                                    parentDirectoryLease: taskItem.parentDirectoryLease,
                                    nativeName: taskItem.nativeName,
                                    expectedIdentity: Self.verifiesDirectoryIdentity(
                                        at: taskItem.url,
                                        behavior: behavior
                                    ) ? taskMetadata.fileIdentity : nil,
                                    classificationWorkerLimit: effectiveDirectoryClassificationWorkerLimit,
                                    cancellationCheck: cancellationCheck
                                )
                                return .directory(.success(DirectoryTraversalSuccess(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    contents: contents
                                )))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                #if DEBUG
                                return .directory(.failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error),
                                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - traversalStart,
                                    diagnosticDetail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
                                )))
                                #else
                                return .directory(.failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error)
                                )))
                                #endif
                            }
                        }
                    } else {
                        // Leaf node (file, symlink, or package-as-directory). Discovery may
                        // have classified it as a pending directory; release that claim.
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        if meta.isPackage,
                           meta.isDirectory,
                           !options.treatPackagesAsDirectories {
                            pendingPackageScans.append((item: item, itemKey: itemKey, metadata: meta))
                            continue
                        }
                        let leafResult = try await makeLeafNode(
                            url: item.url,
                            metadata: meta,
                            options: options,
                            exclusionMatcher: exclusionMatcher,
                            atomicDirectorySummarizer: scanAtomicDirectorySummarizer,
                            progressWeight: item.weight,
                            cancellationCheck: cancellationCheck,
                            metrics: &metrics,
                            continuation: continuation,
                            emissionState: &emissionState
                        )
                        hardLinkAccumulator.merge(leafResult.hardLinkAccumulator)
                        if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                            minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
                        }
                        applyLeafMetrics(leafResult.node, weight: item.weight, metrics: &metrics)
                        if !leafResult.warnings.isEmpty {
                            warnings.append(contentsOf: leafResult.warnings)
                            for warning in leafResult.warnings {
                                continuation.yield(.warning(warning))
                            }
                        }
                        maybeEmitProgress(metrics: &metrics, continuation: continuation, emissionState: &emissionState, summaryPool: atomicSummaryPool)

                        completedByKey[itemKey] = CompletedDirScan(
                            node: leafResult.node,
                            metadata: meta,
                            url: item.url,
                            isTraversable: false
                        )
                    }
                }

                while activePackageTasks < packageSummaryRequestLimit,
                      let pendingPackage = pendingPackageScans.popLast() {
                    let taskItem = pendingPackage.item
                    let taskItemKey = pendingPackage.itemKey
                    let taskMetadata = pendingPackage.metadata
                    let taskMetrics = metrics
                    let taskEmissionState = emissionState
                    activePackageTasks += 1
                    group.addTask {
                        var localMetrics = taskMetrics
                        var localEmissionState = taskEmissionState
                        let leaf = try await self.makeLeafNode(
                            url: taskItem.url,
                            metadata: taskMetadata,
                            options: options,
                            exclusionMatcher: exclusionMatcher,
                            atomicDirectorySummarizer: scanAtomicDirectorySummarizer,
                            progressWeight: taskItem.weight,
                            cancellationCheck: cancellationCheck,
                            metrics: &localMetrics,
                            continuation: continuation,
                            emissionState: &localEmissionState
                        )
                        return .package(PackageSummaryResult(
                            item: taskItem,
                            itemKey: taskItemKey,
                            metadata: taskMetadata,
                            leaf: leaf
                        ))
                    }
                }

                while activePackageTasks < packageSummaryRequestLimit,
                      let candidate = pendingAtomicScans.popLast() {
                    let taskMetrics = metrics
                    let taskEmissionState = emissionState
                    activePackageTasks += 1
                    group.addTask {
                        var localMetrics = taskMetrics
                        var localEmissionState = taskEmissionState
                        let summary = try await scanAtomicDirectorySummarizer.summaryIfNeeded(
                            url: candidate.item.url,
                            childEntries: candidate.contents.entries,
                            metadata: candidate.metadata,
                            includeHiddenFiles: options.includeHiddenFiles,
                            treatPackagesAsDirectories: options.treatPackagesAsDirectories,
                            isNodeDependencyLayout: candidate.isNodeDependencyLayout,
                            minFileCount: autoSummarizeMinFileCount,
                            maxAverageFileSize: autoSummarizeMaxAverageFileSize,
                            workerLimit: atomicSummaryWorkerLimit,
                            progressWeight: candidate.item.weight,
                            exclusionMatcher: exclusionMatcher,
                            cancellationCheck: cancellationCheck,
                            metrics: &localMetrics,
                            continuation: continuation,
                            emissionState: &localEmissionState
                        )
                        return .atomicDirectory(AtomicDirectoryScanResult(
                            candidate: candidate,
                            summary: summary
                        ))
                    }
                }

                guard activeDirectoryTasks + activePackageTasks > 0 else { break }
                guard let traversalResult = try await group.next() else { break }
                // Set when a drained result yields an enumerated directory whose children
                // should be expanded normally; handled once after the switch.
                var directoryToExpand: AtomicDirectoryScanCandidate?

                switch traversalResult {
                case .directory(.success(let success)):
                    activeDirectoryTasks -= 1
                    let item = success.item
                    let itemKey = success.itemKey
                    let meta = success.metadata
                    let contents = success.contents
                    let childEntries = contents.entries
                    #if DEBUG
                    diagnostics?.recordElapsed(
                        operation: "directory.enumerate",
                        url: item.url,
                        nanoseconds: contents.enumerationNanoseconds,
                        itemCount: contents.enumeratedItemCount
                    )
                    diagnostics?.recordElapsed(
                        operation: "directory.classify_children",
                        url: item.url,
                        nanoseconds: contents.classificationNanoseconds,
                        itemCount: contents.enumeratedItemCount,
                        detail: "kept=\(childEntries.count)"
                    )
                    #endif

                    metrics.currentPath = item.url.path
                    metrics.discoveredItems += childEntries.count
                    metrics.enumeratedDirectoryCount += 1
                    releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                    var childDirectoryCount = 0
                    var totalWeightUnits = 0.0
                    for childEntry in childEntries {
                        if Self.isLikelyTraversableDirectory(entry: childEntry) {
                            childDirectoryCount += 1
                            totalWeightUnits += Self.directoryChildWeightUnits
                        } else {
                            totalWeightUnits += 1
                        }
                    }
                    metrics.discoveredDirectoryCount += childDirectoryCount
                    metrics.pendingDirectoryCount += childDirectoryCount
                    // Refresh the summary pool's base metrics unconditionally: the pool
                    // emits progress on its own cadence and must not keep publishing the
                    // frontier state from before this enumeration. (`maybeEmitProgress`
                    // can skip the refresh entirely when its item-count gate misses.)
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(&metrics, continuation: continuation)

                    // Check if this directory should be summarized as atomic (many small files)
                    let isNodeDependencyLayout = AtomicDirectorySummarizer.isNodeDependencyLayoutDirectory(at: item.url)
                    let isKnownGeneratedDirectory = AtomicDirectorySummarizer.isKnownGeneratedDirectory(at: item.url)
                    let canProbeForAutoSummary =
                        item.depth >= autoSummarizeMinDepth ||
                        (item.depth >= 1 && isNodeDependencyLayout) ||
                        isKnownGeneratedDirectory
                    let candidate = AtomicDirectoryScanCandidate(
                        item: item,
                        itemKey: itemKey,
                        metadata: meta,
                        contents: contents,
                        childDirectoryCount: childDirectoryCount,
                        totalWeightUnits: totalWeightUnits,
                        isNodeDependencyLayout: isNodeDependencyLayout
                    )
                    if options.autoSummarizeDirectories,
                       canProbeForAutoSummary,
                       try scanAtomicDirectorySummarizer.isAtomicSummaryCandidate(
                           url: item.url,
                           childEntries: childEntries,
                           isNodeDependencyLayout: isNodeDependencyLayout,
                           minFileCount: autoSummarizeMinFileCount,
                           maxAverageFileSize: autoSummarizeMaxAverageFileSize,
                           cancellationCheck: cancellationCheck
                       ) {
                        // The probe/summary awaits a pooled job; run it as a group task
                        // so the scheduling loop keeps draining results while it works.
                        pendingAtomicScans.append(candidate)
                    } else {
                        directoryToExpand = candidate
                    }

                case .directory(.failure(let failure)):
                    activeDirectoryTasks -= 1
                    #if DEBUG
                    diagnostics?.recordElapsed(
                        operation: "directory.enumerate.error",
                        url: failure.item.url,
                        nanoseconds: failure.elapsedNanoseconds,
                        detail: failure.diagnosticDetail
                    )
                    #endif
                    let item = failure.item
                    let itemKey = failure.itemKey
                    let meta = failure.metadata
                    let warning = failure.warning
                    warnings.append(warning)
                    continuation.yield(.warning(warning))
                    metrics.completedItems += 1
                    metrics.completedTraversalWeight += item.weight
                    metrics.enumeratedDirectoryCount += 1
                    releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(&metrics, continuation: continuation)

                    let inaccessibleNode = FileNodeRecord(
                        id: item.url.path,
                        url: item.url,
                        name: ScanTarget.displayName(for: item.url),
                        isDirectory: true,
                        isSymbolicLink: meta.isSymbolicLink,
                        allocatedSize: 0,
                        logicalSize: 0,
                        descendantFileCount: 0,
                        lastModified: meta.lastModified,
                        fileIdentity: meta.fileIdentity,
                        linkCount: meta.linkCount,
                        isPackage: meta.isPackage,
                        isAccessible: false,
                        isSelfAccessible: false,
                        isSynthetic: false,
                        isAutoSummarized: false
                    )
                    completedByKey[itemKey] = CompletedDirScan(
                        node: inaccessibleNode,
                        metadata: meta,
                        url: item.url,
                        isTraversable: false
                    )
                case .package(let packageResult):
                    activePackageTasks -= 1
                    let item = packageResult.item
                    let leafResult = packageResult.leaf
                    hardLinkAccumulator.merge(leafResult.hardLinkAccumulator)
                    if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                        minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
                    }
                    applyLeafMetrics(leafResult.node, weight: item.weight, metrics: &metrics)
                    if !leafResult.warnings.isEmpty {
                        warnings.append(contentsOf: leafResult.warnings)
                        for warning in leafResult.warnings {
                            continuation.yield(.warning(warning))
                        }
                    }
                    // Committed summary weight must reach the pool's base metrics even
                    // when `maybeEmitProgress`'s item-count gate would skip the update.
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(&metrics, continuation: continuation)
                    completedByKey[packageResult.itemKey] = CompletedDirScan(
                        node: leafResult.node,
                        metadata: packageResult.metadata,
                        url: item.url,
                        isTraversable: false
                    )

                case .atomicDirectory(let atomicResult):
                    activePackageTasks -= 1
                    let candidate = atomicResult.candidate
                    guard let summary = atomicResult.summary else {
                        // Probe declined: expand the directory normally.
                        directoryToExpand = candidate
                        break
                    }
                    let item = candidate.item
                    let meta = candidate.metadata
                    // Treat as atomic: create a leaf node with summary stats.
                    let atomicNode = FileNodeRecord(
                        id: item.url.path,
                        url: item.url,
                        name: ScanTarget.displayName(for: item.url),
                        isDirectory: true,
                        isSymbolicLink: false,
                        allocatedSize: max(meta.allocatedSize, summary.allocatedSize),
                        logicalSize: max(meta.logicalSize, summary.logicalSize),
                        descendantFileCount: summary.descendantFileCount,
                        lastModified: meta.lastModified,
                        fileIdentity: meta.fileIdentity,
                        linkCount: meta.linkCount,
                        isPackage: false,
                        isAccessible: summary.isAccessible,
                        isSelfAccessible: meta.isReadable,
                        isSynthetic: false,
                        isAutoSummarized: true
                    )
                    hardLinkAccumulator.merge(summary.hardLinkAccumulator)
                    minimumAllocatedSizeByNodeID[atomicNode.id] = meta.allocatedSize
                    // The summarized children will never be enqueued: count them as
                    // completed and release their frontier claims.
                    metrics.completedItems += candidate.contents.entries.count
                    metrics.discoveredDirectoryCount = max(
                        metrics.discoveredDirectoryCount - candidate.childDirectoryCount,
                        0
                    )
                    metrics.pendingDirectoryCount = max(
                        metrics.pendingDirectoryCount - candidate.childDirectoryCount,
                        0
                    )
                    applyLeafMetrics(atomicNode, weight: item.weight, metrics: &metrics)
                    if !summary.warnings.isEmpty {
                        warnings.append(contentsOf: summary.warnings)
                        for warning in summary.warnings {
                            continuation.yield(.warning(warning))
                        }
                    }
                    // Committed summary weight must reach the pool's base metrics even
                    // when `maybeEmitProgress`'s item-count gate would skip the update.
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(&metrics, continuation: continuation)

                    completedByKey[candidate.itemKey] = CompletedDirScan(
                        node: atomicNode,
                        metadata: meta,
                        url: item.url,
                        isTraversable: false
                    )
                }

                guard let expansion = directoryToExpand else { continue }
                let item = expansion.item
                let itemKey = expansion.itemKey
                let contents = expansion.contents
                let childEntries = contents.entries
                let totalWeightUnits = expansion.totalWeightUnits

                if childEntries.isEmpty {
                    // Nothing below this directory: its whole weight is done.
                    metrics.completedTraversalWeight += item.weight
                }

                // Enqueue children onto the stack. Each child records its parent key.
                for (offset, childEntry) in childEntries.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    let childWeight = item.weight * Self.traversalWeightUnits(for: childEntry) / totalWeightUnits

                    // Bulk discovery has already fully classified ordinary files
                    // and symlinks. Complete them here instead of allocating a work
                    // item only to pop, reclassify, and pass it through an async leaf
                    // function on the next loop iteration. Packages remain queued
                    // because they may require recursive summary work.
                    if let childMetadata = childEntry.metadata,
                       !childMetadata.isDirectory || childMetadata.isSymbolicLink {
                        let childPath = childEntry.url.path
                        guard seenScannedNodeIDs.insert(childPath).inserted else {
                            recordDuplicateNode(
                                at: childEntry.url,
                                weight: childWeight,
                                metrics: &metrics,
                                warnings: &warnings,
                                continuation: continuation,
                                emissionState: &emissionState,
                                summaryPool: atomicSummaryPool
                            )
                            continue
                        }

                        let childKey = nextKey
                        nextKey += 1
                        completedByKey.append(nil)
                        childrenKeysByKey.append(nil)
                        if childrenKeysByKey[itemKey] == nil {
                            childrenKeysByKey[itemKey] = []
                        }
                        childrenKeysByKey[itemKey]!.append(childKey)

                        let childNode = makeFileNode(
                            url: childEntry.url,
                            metadata: childMetadata
                        )
                        if childMetadata.linkCount > 1,
                           let hardLinkClaim = HardLinkDeduplicator.claim(
                               for: childMetadata,
                               ownerNodeID: childNode.id,
                               path: childPath
                           ) {
                            hardLinkAccumulator.record(hardLinkClaim)
                        }
                        metrics.currentPath = childPath
                        applyLeafMetrics(childNode, weight: childWeight, metrics: &metrics)
                        maybeEmitProgress(
                            metrics: &metrics,
                            continuation: continuation,
                            emissionState: &emissionState,
                            summaryPool: atomicSummaryPool
                        )
                        completedByKey[childKey] = CompletedDirScan(
                            node: childNode,
                            metadata: childMetadata,
                            url: childEntry.url,
                            isTraversable: false
                        )
                        continue
                    }

                    workStack.append(
                        ScanWorkItem(
                            url: childEntry.url,
                            metadata: childEntry.metadata,
                            localizedEnumerationError: childEntry.localizedEnumerationError,
                            isDirectoryHint: childEntry.isDirectoryHint,
                            parentKey: itemKey,
                            depth: item.depth + 1,
                            weight: childWeight,
                            parentDirectoryLease: contents.directoryLease,
                            nativeName: childEntry.nativeName
                        )
                    )
                }
                // Register this directory so phase 2 can assemble it.
                completedByKey[itemKey] = CompletedDirScan(
                    node: nil,
                    metadata: expansion.metadata,
                    url: item.url,
                    isTraversable: true
                )
            }
        }

        // Phase 2: Assemble the tree bottom-up from completed results.
        // Process keys in reverse order (children always have higher keys than parents).
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        metrics.finalizationFraction = 0
        metrics.recalculateProgress()
        atomicSummaryPool.updateProgress(
            &metrics,
            continuation: continuation,
            force: true
        )

        let finalizationTotal = max(completedByKey.count, 1)
        // Cap stream traffic to roughly 200 assembly updates on very large scans.
        let finalizationProgressInterval = max(512, finalizationTotal / 200)
        var finalizedItems = 0
        var resolvedNodeByKey = Array<FileNodeRecord?>(repeating: nil, count: nextKey)
        var childIndicesByIndex = Array<[FileTreeNodeIndex]>(repeating: [], count: nextKey)
        var parentIndices = Array<FileTreeNodeIndex?>(repeating: nil, count: nextKey)
        var aggregateStats = AggregateStatsAccumulator()
        #if DEBUG
        let finalizationStart = diagnostics?.start()
        #endif
        for key in (0..<nextKey).reversed() {
            if finalizedItems.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let completed = completedByKey[key] else { continue }
            completedByKey[key] = nil
            finalizedItems += 1

            if completed.isTraversable {
                // Traversable directories must still be materialized when empty.
                let childKeys = childrenKeysByKey[key] ?? []
                childrenKeysByKey[key] = nil
                var sortedChildKeys: [Int] = []
                sortedChildKeys.reserveCapacity(childKeys.count)
                for (offset, childKey) in childKeys.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    if resolvedNodeByKey[childKey] != nil {
                        sortedChildKeys.append(childKey)
                    }
                }
                // Duplicate paths are rejected before keys are assigned in phase 1,
                // so children are already unique here.
                sortedChildKeys.sort { lhsKey, rhsKey in
                    guard let lhs = resolvedNodeByKey[lhsKey],
                          let rhs = resolvedNodeByKey[rhsKey] else {
                        return lhsKey < rhsKey
                    }
                    if lhs.allocatedSize == rhs.allocatedSize {
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.allocatedSize > rhs.allocatedSize
                }
                try Task.checkCancellation()
                let directoryID = completed.url.path
                var allocatedSize: Int64 = 0
                var logicalSize: Int64 = 0
                var descendantFileCount = 0
                var childrenAreAccessible = true
                var sortedChildIndices: [FileTreeNodeIndex] = []
                sortedChildIndices.reserveCapacity(sortedChildKeys.count)
                for (offset, childKey) in sortedChildKeys.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    guard let child = resolvedNodeByKey[childKey] else { continue }
                    allocatedSize = ScanIntegerMath.addingClamped(allocatedSize, child.allocatedSize)
                    logicalSize = ScanIntegerMath.addingClamped(logicalSize, child.logicalSize)
                    childrenAreAccessible = childrenAreAccessible && child.isAccessible
                    if child.isDirectory {
                        descendantFileCount = ScanIntegerMath.addingClamped(
                            descendantFileCount,
                            child.descendantFileCount
                        )
                    } else if !child.isSymbolicLink && !child.isSynthetic {
                        descendantFileCount = ScanIntegerMath.addingClamped(descendantFileCount, 1)
                    }
                    let childIndex = FileTreeNodeIndex(rawValue: UInt32(childKey))
                    sortedChildIndices.append(childIndex)
                    parentIndices[childKey] = FileTreeNodeIndex(rawValue: UInt32(key))
                }

                let assembled = FileNodeRecord(
                    id: directoryID,
                    url: completed.url,
                    name: ScanTarget.displayName(for: completed.url),
                    isDirectory: true,
                    isSymbolicLink: false,
                    allocatedSize: allocatedSize,
                    logicalSize: logicalSize,
                    descendantFileCount: descendantFileCount,
                    lastModified: completed.metadata.lastModified,
                    fileIdentity: completed.metadata.fileIdentity,
                    linkCount: completed.metadata.linkCount,
                    isPackage: completed.metadata.isPackage,
                    isAccessible: completed.metadata.isReadable && childrenAreAccessible,
                    isSelfAccessible: completed.metadata.isReadable,
                    isSynthetic: false,
                    isAutoSummarized: false
                )
                resolvedNodeByKey[key] = assembled
                aggregateStats.include(assembled, hasChildren: !sortedChildIndices.isEmpty)

                childIndicesByIndex[key] = sortedChildIndices

                metrics.completedItems = min(metrics.discoveredItems, metrics.completedItems + 1)
            } else if let onlyChild = completed.node {
                // Leaf node or inaccessible directory: use the child directly.
                resolvedNodeByKey[key] = onlyChild
                aggregateStats.include(onlyChild, hasChildren: false)
            }

            if finalizedItems.isMultiple(of: finalizationProgressInterval) || finalizedItems == finalizationTotal {
                try Task.checkCancellation()
                metrics.finalizationFraction = Double(finalizedItems) / Double(finalizationTotal)
                metrics.recalculateProgress()
                atomicSummaryPool.updateProgress(
                    &metrics,
                    continuation: continuation,
                    force: true
                )
            }
        }
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize",
            url: target.url,
            startedAt: finalizationStart,
            itemCount: finalizedItems
        )
        #endif

        guard let rootNode = resolvedNodeByKey[0] else {
            throw ScanEngineError.missingRootNode
        }

        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(resolvedNodeByKey.count)
        for key in resolvedNodeByKey.indices {
            guard let node = resolvedNodeByKey[key] else {
                assertionFailure("Missing finalized node for scan key \(key).")
                throw ScanEngineError.missingRootNode
            }
            resolvedNodeByKey[key] = nil
            nodes.append(node)
        }

        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        var orderedNodeIndices: [FileTreeNodeIndex] = []
        orderedNodeIndices.reserveCapacity(nodes.count)
        var orderedTraversalStack = [rootIndex]
        while let nodeIndex = orderedTraversalStack.popLast() {
            if orderedNodeIndices.count.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            orderedNodeIndices.append(nodeIndex)
            let children = childIndicesByIndex[Int(nodeIndex.rawValue)]
            orderedTraversalStack.append(contentsOf: children.reversed())
        }
        assert(orderedNodeIndices.count == nodes.count)

        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: &metrics, continuation: continuation, emissionState: &emissionState, summaryPool: atomicSummaryPool)

        let store = HardLinkDeduplicator.deduplicatedStore(
            rootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: aggregateStats.makeStats(root: rootNode),
            hardLinkAccumulator: hardLinkAccumulator,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
        await atomicSummaryPool.finish()
        directoryDescriptorPool?.invalidate()
        return store
        } catch {
            directoryDescriptorPool?.cancel()
            await atomicSummaryPool.cancelAndFinish(with: error)
            throw error
        }
    }

    // MARK: - Helpers

    private nonisolated func applyLeafMetrics(_ node: FileNodeRecord, weight: Double, metrics: inout ScanMetrics) {
        if node.isDirectory {
            if !node.isAutoSummarized {
                metrics.directoriesVisited += 1
            }
            metrics.filesVisited += node.descendantFileCount
        } else if !node.isSymbolicLink {
            metrics.filesVisited += 1
        }
        metrics.bytesDiscovered += node.allocatedSize
        metrics.completedItems += 1
        metrics.completedTraversalWeight += weight
        if node.isDirectory, node.isAutoSummarized || node.isPackage {
            metrics.completedSummaryTraversalWeight += weight
        }
    }

    /// Relative progress weight of a traversable directory child versus a single file.
    /// A subdirectory hides an unscanned subtree of unknown size, so it gets a larger
    /// share of its parent's weight than a file does.
    private static let directoryChildWeightUnits = 8.0

    /// Classifies an item the same way at discovery time and at pop time so the
    /// frontier accounting in `ScanMetrics` stays balanced.
    private nonisolated static func isLikelyTraversableDirectory(
        metadata: NodeMetadata?,
        url: URL,
        isDirectoryHint: Bool? = nil
    ) -> Bool {
        guard let metadata else {
            return isDirectoryHint ?? url.hasDirectoryPath
        }
        return metadata.isDirectory && !metadata.isSymbolicLink
    }

    private nonisolated static func traversalWeightUnits(for entry: DirectoryEntry) -> Double {
        isLikelyTraversableDirectory(entry: entry) ? directoryChildWeightUnits : 1
    }

    private nonisolated static func isLikelyTraversableDirectory(entry: DirectoryEntry) -> Bool {
        isLikelyTraversableDirectory(
            metadata: entry.metadata,
            url: entry.url,
            isDirectoryHint: entry.isDirectoryHint
        )
    }

    /// Removes an item's frontier claim once its fate is known (enumerated, leaf,
    /// duplicate, or unavailable). Uses the same classifier as discovery so the
    /// pending count stays balanced.
    private nonisolated func releasePendingDirectoryIfNeeded(for item: ScanWorkItem, metrics: inout ScanMetrics) {
        guard Self.isLikelyTraversableDirectory(
            metadata: item.metadata,
            url: item.url,
            isDirectoryHint: item.isDirectoryHint
        ) else { return }
        metrics.pendingDirectoryCount = max(metrics.pendingDirectoryCount - 1, 0)
    }

    nonisolated static func uniqueNodesForAssembly(_ nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        guard nodes.count > 1 else { return nodes }

        var seenIDs = Set<String>()
        seenIDs.reserveCapacity(nodes.count)
        for node in nodes {
            guard seenIDs.insert(node.id).inserted else {
                return uniqueNodesAfterDuplicateFound(nodes)
            }
        }

        return nodes
    }

    private nonisolated static func uniqueNodesAfterDuplicateFound(_ nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        var seenIDs = Set<String>()
        var uniqueNodes: [FileNodeRecord] = []
        uniqueNodes.reserveCapacity(nodes.count)

        for node in nodes where seenIDs.insert(node.id).inserted {
            uniqueNodes.append(node)
        }

        return uniqueNodes
    }

    private nonisolated func recordDuplicateNode(
        at url: URL,
        weight: Double,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        summaryPool: AtomicDirectorySummaryPool? = nil
    ) {
        let warning = ScanWarningFactory.makeDuplicateNodeWarning(for: url)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += weight
        maybeEmitProgress(
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            summaryPool: summaryPool
        )
    }

    private nonisolated func recordUnavailableItem(
        _ item: ScanWorkItem,
        itemKey: Int,
        error: Error,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        summaryPool: AtomicDirectorySummaryPool? = nil,
        completedByKey: inout [CompletedDirScan?]
    ) {
        let isDirectory = Self.isLikelyTraversableDirectory(
            metadata: item.metadata,
            url: item.url,
            isDirectoryHint: item.isDirectoryHint
        )
        let warning = ScanWarningFactory.makeWarning(for: item.url, error: error)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += item.weight
        maybeEmitProgress(
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            summaryPool: summaryPool
        )

        completedByKey[itemKey] = CompletedDirScan(
            node: makeUnavailableNode(for: item.url, isDirectory: isDirectory),
            metadata: NodeMetadata(
                isDirectory: isDirectory,
                isPackage: false,
                isSymbolicLink: false,
                logicalSize: 0,
                allocatedSize: 0,
                lastModified: nil,
                isReadable: false,
                volumeCapacity: nil,
                fileIdentity: nil,
                linkCount: 0
            ),
            url: item.url,
            isTraversable: false
        )
    }

    private nonisolated func makeUnavailableNode(for url: URL, isDirectory: Bool) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: false,
            isSelfAccessible: false,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private nonisolated static func directoryEntries(
        of url: URL,
        includeHiddenFiles: Bool,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        directoryContents: DirectoryContentsProvider,
        usesBulkDirectoryEnumeration: Bool,
        directoryNamespaceResolver: DirectoryNamespaceResolver,
        directoryDescriptorPool: ScanDirectoryDescriptorPool?,
        parentDirectoryLease: ScanDirectoryDescriptorPool.Lease?,
        nativeName: BulkDirectoryEnumerator.NativeName?,
        expectedIdentity: FileIdentity?,
        classificationWorkerLimit: Int,
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> DirectoryContentsScanResult {
        try cancellationCheck()

        if usesBulkDirectoryEnumeration {
            #if DEBUG
            var enumerationNanoseconds: UInt64 = 0
            var classificationNanoseconds: UInt64 = 0
            #endif
            let directoryLease: ScanDirectoryDescriptorPool.Lease?
            if let directoryDescriptorPool,
               let parentDirectoryLease,
               let nativeName {
                switch try directoryDescriptorPool.openChild(
                    named: nativeName,
                    at: url,
                    relativeTo: parentDirectoryLease,
                    expectedIdentity: expectedIdentity,
                    cancellationCheck: cancellationCheck
                ) {
                case .lease(let lease):
                    directoryLease = lease
                case .fallback:
                    directoryLease = nil
                }
            } else if let directoryDescriptorPool {
                switch try directoryDescriptorPool.openRoot(
                    at: url,
                    expectedIdentity: expectedIdentity,
                    cancellationCheck: cancellationCheck
                ) {
                case .lease(let lease): directoryLease = lease
                case .fallback: directoryLease = nil
                }
            } else {
                directoryLease = nil
            }
            let cursor: BulkDirectoryEnumerator.Cursor
            if let directoryLease {
                cursor = try BulkDirectoryEnumerator.makeCursor(
                    at: url,
                    borrowing: directoryLease,
                    includeHiddenFiles: includeHiddenFiles,
                    metadataLoader: metadataLoader,
                    cancellationCheck: cancellationCheck
                )
            } else {
                cursor = try BulkDirectoryEnumerator.makeCursor(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    metadataLoader: metadataLoader,
                    cancellationCheck: cancellationCheck
                )
            }
            var entries: [DirectoryEntry] = []
            var enumeratedItemCount = 0
            do {
                while true {
                    #if DEBUG
                    let batchStart = DispatchTime.now().uptimeNanoseconds
                    #endif
                    guard let batch = try cursor.nextBatch(cancellationCheck: cancellationCheck) else {
                        #if DEBUG
                        enumerationNanoseconds += DispatchTime.now().uptimeNanoseconds - batchStart
                        #endif
                        break
                    }
                    #if DEBUG
                    enumerationNanoseconds += DispatchTime.now().uptimeNanoseconds - batchStart
                    let classificationStart = DispatchTime.now().uptimeNanoseconds
                    #endif
                    let filteredEntries = try ScanDirectoryEntryFilter.filteredEntries(
                        batch.entries,
                        under: url,
                        behavior: behavior,
                        exclusionMatcher: exclusionMatcher,
                        cancellationCheck: cancellationCheck
                    )
                    entries.append(contentsOf: filteredEntries)
                    enumeratedItemCount += batch.enumeratedItemCount
                    #if DEBUG
                    classificationNanoseconds += DispatchTime.now().uptimeNanoseconds - classificationStart
                    #endif
                }
                #if DEBUG
                return DirectoryContentsScanResult(
                    entries: entries,
                    enumeratedItemCount: enumeratedItemCount,
                    directoryLease: directoryLease,
                    enumerationNanoseconds: enumerationNanoseconds,
                    classificationNanoseconds: classificationNanoseconds
                )
                #else
                return DirectoryContentsScanResult(
                    entries: entries,
                    enumeratedItemCount: enumeratedItemCount,
                    directoryLease: directoryLease
                )
                #endif
            } catch BulkDirectoryEnumerator.StreamError.unavailable {
                directoryLease?.close()
                // Discard the uncommitted native batches and use the Foundation path.
            } catch {
                directoryLease?.close()
                throw error
            }
        }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let prefetchKeys = shouldFilterStartupVolumeInternals(under: url, behavior: behavior)
            ? nil
            : Array(resourceKeys)
        #if DEBUG
        let enumerationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let enumerationResult = try directoryContents(url, prefetchKeys, options, cancellationCheck)
        #if DEBUG
        let enumerationNanoseconds = DispatchTime.now().uptimeNanoseconds - enumerationStart
        #endif
        try cancellationCheck()

        #if DEBUG
        let classificationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let namespacePreservedURLs = directoryNamespaceResolver.preservingParentNamespace(
            enumerationResult.urls,
            under: url
        )
        let namespacePreservedFailures = enumerationResult.localizedFailures.map { failure in
            let preservedURL = directoryNamespaceResolver.preservingParentNamespace(
                [failure.url],
                under: url
            ).first ?? failure.url
            return DirectoryEnumerationFailure(
                url: preservedURL,
                error: failure.error,
                isDirectoryHint: failure.isDirectoryHint
            )
        }
        var entries = try await Self.classifiedDirectoryEntries(
            namespacePreservedURLs,
            under: url,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            resourceKeys: resourceKeys,
            metadataLoader: metadataLoader,
            workerLimit: classificationWorkerLimit,
            cancellationCheck: cancellationCheck
        )
        entries.append(contentsOf:
            ScanDirectoryEntryFilter.entriesForLocalizedFailures(
                namespacePreservedFailures,
                under: url,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher
            )
        )
        #if DEBUG
        let classificationNanoseconds = DispatchTime.now().uptimeNanoseconds - classificationStart
        #endif

        try cancellationCheck()
        #if DEBUG
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumerationResult.urls.count + enumerationResult.localizedFailures.count,
            directoryLease: nil,
            enumerationNanoseconds: enumerationNanoseconds,
            classificationNanoseconds: classificationNanoseconds
        )
        #else
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumerationResult.urls.count + enumerationResult.localizedFailures.count,
            directoryLease: nil
        )
        #endif
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        workerLimit: Int,
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> [DirectoryEntry] {
        guard workerLimit > 1,
              contents.count >= ScanConcurrencyPolicy.directoryClassificationParallelThreshold else {
            return try classifiedDirectoryEntries(
                contents,
                range: contents.indices,
                under: parentURL,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher,
                resourceKeys: resourceKeys,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck
            )
        }

        let workerCount = min(max(1, workerLimit), contents.count)
        let chunkSize = max(
            ScanConcurrencyPolicy.directoryClassificationParallelThreshold,
            (contents.count + workerCount - 1) / workerCount
        )
        let chunkCount = (contents.count + chunkSize - 1) / chunkSize
        var chunks = Array<[DirectoryEntry]?>(repeating: nil, count: chunkCount)

        try await withThrowingTaskGroup(of: ClassifiedDirectoryEntriesChunk.self) { group in
            var chunkIndex = 0
            var chunkStart = 0
            while chunkStart < contents.count {
                let chunkEnd = min(chunkStart + chunkSize, contents.count)
                let range = chunkStart..<chunkEnd
                let index = chunkIndex
                group.addTask {
                    let entries = try classifiedDirectoryEntries(
                        contents,
                        range: range,
                        under: parentURL,
                        behavior: behavior,
                        exclusionMatcher: exclusionMatcher,
                        resourceKeys: resourceKeys,
                        metadataLoader: metadataLoader,
                        cancellationCheck: cancellationCheck
                    )
                    return ClassifiedDirectoryEntriesChunk(index: index, entries: entries)
                }
                chunkIndex += 1
                chunkStart = chunkEnd
            }

            for try await chunk in group {
                chunks[chunk.index] = chunk.entries
            }
        }

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(contents.count)
        for chunk in chunks {
            guard let chunk else { continue }
            entries.append(contentsOf: chunk)
        }
        return entries
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        range: Range<Int>,
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck
    ) throws -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(range.count)

        for index in range {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            let childURL = contents[index]
            guard ScanDirectoryEntryFilter.includes(
                childURL,
                under: parentURL,
                behavior: behavior
            ) else {
                continue
            }

            let childMetadata = try? metadataLoader.metadata(
                for: childURL,
                prefetchedResourceValues: childURL.resourceValues(forKeys: resourceKeys)
            )
            guard !exclusionMatcher.excludes(
                childURL,
                isDirectory: childMetadata?.isDirectory ?? childURL.hasDirectoryPath
            ) else {
                continue
            }

            entries.append(DirectoryEntry(url: childURL, metadata: childMetadata))
        }

        try cancellationCheck()
        return entries
    }

    private nonisolated static func shouldFilterStartupVolumeInternals(under parentURL: URL, behavior: ScanBehavior) -> Bool {
        behavior.excludesStartupVolumeInternals && (parentURL.path == "/" || parentURL.path == "/System")
    }

    nonisolated static func includedChildURL(_ childURL: URL, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        ScanDirectoryEntryFilter.includes(childURL, under: parentURL, behavior: behavior)
    }

    /// Startup-volume firmlinks deliberately resolve from the sealed System
    /// volume into the Data volume. Their enumerated and opened identities are
    /// therefore expected to differ; all other directory opens retain strict
    /// replacement detection.
    nonisolated static func verifiesDirectoryIdentity(
        at url: URL,
        behavior: ScanBehavior
    ) -> Bool {
        !behavior.excludesStartupVolumeInternals
            || !TrashSafetyPolicy.isStartupVolumeFirmlinkRoot(url)
    }

    private nonisolated func makeFileNode(
        url: URL,
        metadata: NodeMetadata
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: metadata.isDirectory,
            isSymbolicLink: metadata.isSymbolicLink,
            allocatedSize: metadata.allocatedSize,
            logicalSize: metadata.logicalSize,
            descendantFileCount: metadata.isDirectory || metadata.isSymbolicLink ? 0 : 1,
            lastModified: metadata.lastModified,
            fileIdentity: metadata.fileIdentity,
            linkCount: metadata.linkCount,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable,
            isSelfAccessible: metadata.isReadable,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private nonisolated func makeLeafNode(
        url: URL,
        metadata: NodeMetadata,
        options: ScanOptions,
        exclusionMatcher: ScanExclusionMatcher,
        atomicDirectorySummarizer: AtomicDirectorySummarizer,
        progressWeight: Double,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> LeafNodeResult {
        try cancellationCheck()
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            let hardLinkClaim = metadata.linkCount > 1
                ? HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path)
                : nil
            var hardLinkAccumulator = HardLinkIdentityOwnerAccumulator()
            if let hardLinkClaim {
                hardLinkAccumulator.record(hardLinkClaim)
            }
            return LeafNodeResult(
                node: node,
                warnings: [],
                hardLinkAccumulator: hardLinkAccumulator,
                minimumAllocatedSize: nil
            )
        }

        guard let summary = try await atomicDirectorySummarizer.summarize(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true,
            workerLimit: ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options),
            progressWeight: progressWeight,
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            let hardLinkClaim = metadata.linkCount > 1
                ? HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path)
                : nil
            var hardLinkAccumulator = HardLinkIdentityOwnerAccumulator()
            if let hardLinkClaim {
                hardLinkAccumulator.record(hardLinkClaim)
            }
            return LeafNodeResult(
                node: node,
                warnings: [],
                hardLinkAccumulator: hardLinkAccumulator,
                minimumAllocatedSize: nil
            )
        }

        return LeafNodeResult(
            node: FileNodeRecord(
                id: url.path,
                url: url,
                name: ScanTarget.displayName(for: url),
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: max(metadata.allocatedSize, summary.allocatedSize),
                logicalSize: max(metadata.logicalSize, summary.logicalSize),
                descendantFileCount: summary.descendantFileCount,
                lastModified: metadata.lastModified,
                fileIdentity: metadata.fileIdentity,
                linkCount: metadata.linkCount,
                isPackage: true,
                isAccessible: metadata.isReadable && summary.isAccessible,
                isSelfAccessible: metadata.isReadable,
                isSynthetic: false,
                isAutoSummarized: false
            ),
            warnings: summary.warnings,
            hardLinkAccumulator: summary.hardLinkAccumulator,
            minimumAllocatedSize: metadata.allocatedSize
        )
    }

    private nonisolated func makeSnapshot(
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool,
        scanOptions: ScanOptions?,
        volumeCapacity: VolumeCapacitySnapshot? = nil,
        reconcilesVolumeCapacity: Bool = false,
        hasActiveExclusions: Bool = false
    ) -> ScanSnapshot {
        let reconciledStore = VolumeCapacityAccounting.reconciledStore(
            treeStore,
            target: target,
            capacity: reconcilesVolumeCapacity ? volumeCapacity : nil,
            hasActiveExclusions: hasActiveExclusions
        )

        return ScanSnapshot(
            target: target,
            treeStore: reconciledStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            aggregateStats: reconciledStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            volumeCapacity: volumeCapacity
        )
    }

    private nonisolated func maybeEmitProgress(
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        summaryPool: AtomicDirectorySummaryPool? = nil
    ) {
        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        let isFixedEmissionPoint = visitedItems <= 2 || visitedItems.isMultiple(of: 1_000)
        guard isFixedEmissionPoint || visitedItems.isMultiple(of: 64) else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(emissionState.lastProgressEmission)
        let shouldEmit = isFixedEmissionPoint || elapsed >= 0.15
        guard shouldEmit else { return }

        emissionState.lastProgressEmission = now
        metrics.recalculateProgress()
        if let summaryPool {
            summaryPool.updateProgress(&metrics, continuation: continuation)
        } else {
            continuation.yield(.progress(metrics))
        }
    }

    private nonisolated func shouldTraverseDirectory(metadata: NodeMetadata, options: ScanOptions) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        return !metadata.isPackage || options.treatPackagesAsDirectories
    }

    /// APFS capacity is container-wide and includes storage that cannot be attributed
    /// safely to any one mounted volume (including the startup volume). Reconciling it
    /// against per-file allocations creates a misleading synthetic remainder, so keep
    /// capacity accounting separate from the scanned tree on every APFS volume.
    private nonisolated func estimatedTotalBytes(for target: ScanTarget, metadata: NodeMetadata) -> Int64 {
        guard target.kind == .volume,
              let volumeCapacity = metadata.volumeCapacity,
              shouldReconcileVolumeCapacity(for: target.url) else {
            return 0
        }
        return max(volumeCapacity.usedCapacity, metadata.allocatedSize)
    }

    private nonisolated func shouldReconcileVolumeCapacity(for url: URL) -> Bool {
        guard let fileSystemType = volumeFileSystemTypeProvider(url) else {
            return false
        }
        return Self.shouldReconcileVolumeCapacity(fileSystemType: fileSystemType)
    }

    nonisolated static func shouldReconcileVolumeCapacity(fileSystemType: String) -> Bool {
        let normalizedType = fileSystemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedType.isEmpty else { return false }
        return normalizedType != "apfs"
    }

}

extension FileManager.DirectoryEnumerator: nonisolated ScanEngine.DirectoryObjectEnumerating {}

nonisolated struct ScanEmissionState: Sendable {
    var lastProgressEmission: Date

    nonisolated init(
        lastProgressEmission: Date = .distantPast
    ) {
        self.lastProgressEmission = lastProgressEmission
    }
}
