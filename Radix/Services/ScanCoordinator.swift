//
//  ScanCoordinator.swift
//  Radix
//

import Combine
import Foundation

enum AppModelPhase: Equatable, Sendable {
    case idle
    case scanning
    case displaying
    case failed
}

protocol ScanEventStreaming: Sendable {
    nonisolated func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error>
    nonisolated func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error>
}

enum ScanExpansionResult {
    case skipped
    case cancelled
    case expanded(replacementRootID: FileNodeRecord.ID)
    case failed(message: String)
}

nonisolated enum ScanCompletionNotice: Equatable, Sendable {
    case incrementalUpdated
    case noChanges
    case fullFallback(IncrementalRescanFallbackReason)
}

@MainActor
final class ScanProgressState: ObservableObject {
    @Published var metrics: ScanMetrics
    @Published var executionMode: ScanExecutionMode?

    init(
        metrics: ScanMetrics = ScanMetrics(),
        executionMode: ScanExecutionMode? = nil
    ) {
        self.metrics = metrics
        self.executionMode = executionMode
    }
}

@MainActor
final class ScanCoordinator: ObservableObject {
    @Published var phase: AppModelPhase = .idle
    @Published private(set) var snapshot: ScanSnapshot?
    @Published var selectedTarget: ScanTarget?
    @Published private(set) var completedScanSnapshot: ScanSnapshot?
    @Published private(set) var scanErrorMessage: String?
    @Published private(set) var expandingNodeID: FileNodeRecord.ID?
    @Published private(set) var trashSafetyPolicy: TrashSafetyPolicy
    @Published private(set) var scanCompletionNotice: ScanCompletionNotice?

    let progress: ScanProgressState

    private let scanService: any ScanEventStreaming
    private let snapshotTransformService: any ScanSnapshotTransforming
    private let progressThrottleDuration: Duration
    private let progressClock = ContinuousClock()

    private var scanTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var progressPublishTask: Task<Void, Never>?
    private var completionNoticeDismissTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var activeExpansionID: UUID?
    private var expansionCompletion: ((ScanExpansionResult) -> Void)?
    private var pendingProgressMetrics: ScanMetrics?
    private var lastProgressPublishTime: ContinuousClock.Instant?
    private var snapshotContextID = UUID()
    private var snapshotRevision: UInt64 = 0
    var onScanFinished: ((ScanSnapshot) -> Void)?

    init(
        scanService: any ScanEventStreaming = IncrementalScanService(),
        snapshotTransformService: any ScanSnapshotTransforming = ScanSnapshotTransformService(),
        progressThrottleDuration: Duration = .milliseconds(100),
        progress: ScanProgressState = ScanProgressState(),
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) {
        self.scanService = scanService
        self.snapshotTransformService = snapshotTransformService
        self.progressThrottleDuration = progressThrottleDuration
        self.progress = progress
        self.trashSafetyPolicy = trashSafetyPolicy
    }

    var scanMetrics: ScanMetrics {
        get { progress.metrics }
        set { progress.metrics = newValue }
    }

    var isScanning: Bool {
        phase == .scanning
    }

    var canRescan: Bool {
        selectedTarget != nil && !isScanning
    }

    var canStopScan: Bool {
        isScanning
    }

    var snapshotSource: ScanSnapshotSource {
        snapshot?.source ?? .live
    }

    var fileTreeStore: FileTreeStore? {
        snapshot?.treeStore
    }

    func replaceTrashSafetyPolicy(_ policy: TrashSafetyPolicy) {
        trashSafetyPolicy = policy
    }

    func startScan(
        _ target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot? = nil,
        isRescan: Bool = false,
        prepare: () -> Void = {}
    ) {
        stopScan(resetState: false)
        dismissScanCompletionNotice()
        prepare()

        selectedTarget = target
        phase = .scanning
        scanErrorMessage = nil
        scanMetrics = ScanMetrics()
        progress.executionMode = isRescan ? .preparingIncremental : nil
        publishSnapshot(nil, startsNewContext: true)
        completedScanSnapshot = nil
        resetProgressThrottling()

        let scanID = UUID()
        activeScanID = scanID
        let stream: AsyncThrowingStream<ScanProgressEvent, Error>
        if let baseline {
            stream = scanService.rescan(target: target, options: options, from: baseline)
        } else {
            stream = scanService.scan(target: target, options: options)
        }
        scanTask = Task { [weak self] in
            await self?.consumeScanStream(stream, scanID: scanID)
        }
    }

    func stopScan(resetState: Bool = true) {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        resetProgressThrottling()
        cancelExpansion(completeWith: .cancelled)

        var metrics = scanMetrics
        metrics.isFinalizing = false
        scanMetrics = metrics

        if resetState {
            phase = snapshot == nil ? .idle : .displaying
        }
    }

    func clearScan() {
        stopScan(resetState: false)
        dismissScanCompletionNotice()
        selectedTarget = nil
        publishSnapshot(nil, startsNewContext: true)
        completedScanSnapshot = nil
        scanMetrics = ScanMetrics()
        progress.executionMode = nil
        phase = .idle
    }

    func replaceCurrentSnapshot(_ snapshot: ScanSnapshot?) {
        cancelExpansion(completeWith: .cancelled)
        dismissScanCompletionNotice()
        publishSnapshot(snapshot, startsNewContext: true)
        if snapshot == nil {
            phase = .idle
        } else if !isScanning {
            phase = .displaying
        }
    }

    func restoreCompletedSnapshot(
        _ snapshot: ScanSnapshot,
        prepare: () -> Void = {}
    ) {
        guard snapshot.isComplete else { return }

        stopScan(resetState: false)
        dismissScanCompletionNotice()
        prepare()

        selectedTarget = snapshot.target
        scanErrorMessage = nil
        progress.executionMode = nil
        resetProgressThrottling()
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot.source.allowsFileMutation ? snapshot : nil

        var metrics = ScanMetrics()
        metrics.recalculateProgress(isComplete: true)
        scanMetrics = metrics
        phase = .displaying
    }

    @discardableResult
    func removeNodeFromCurrentSnapshot(id nodeID: FileNodeRecord.ID) async -> Bool {
        await removeNodesFromCurrentSnapshot(ids: [nodeID])
    }

    @discardableResult
    func removeNodesFromCurrentSnapshot(ids nodeIDs: [FileNodeRecord.ID]) async -> Bool {
        guard let initialSnapshot = snapshot else { return false }
        let removalNodeIDs = initialSnapshot.treeStore.topLevelNodeIDs(from: nodeIDs)
        guard !removalNodeIDs.isEmpty else { return false }
        let removalContextID = snapshotContextID

        do {
            while snapshotContextID == removalContextID {
                try Task.checkCancellation()
                guard let currentSnapshot = snapshot else { return false }
                let currentRemovalNodeIDs = currentSnapshot.treeStore.topLevelNodeIDs(
                    from: removalNodeIDs
                )
                if currentRemovalNodeIDs.isEmpty {
                    return true
                }

                if let expandingNodeID,
                   currentRemovalNodeIDs.contains(where: {
                       currentSnapshot.treeStore.isAncestor($0, of: expandingNodeID)
                   }) {
                    cancelExpansion(completeWith: .cancelled)
                }

                let transformRevision = snapshotRevision
                guard let updatedSnapshot = try await snapshotTransformService.removingNodes(
                    in: currentSnapshot,
                    ids: currentRemovalNodeIDs
                ) else { return false }
                try Task.checkCancellation()
                guard snapshotContextID == removalContextID else { return false }
                guard snapshotRevision == transformRevision else { continue }

                publishSnapshot(updatedSnapshot, startsNewContext: false)
                completedScanSnapshot = nil
                if !isScanning {
                    phase = .displaying
                }
                return true
            }
            return false
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    func expandSummarizedNode(
        _ node: FileNodeRecord,
        options: ScanOptions,
        completion: @escaping (ScanExpansionResult) -> Void
    ) {
        guard node.isAutoSummarized else {
            completion(.skipped)
            return
        }

        cancelExpansion(completeWith: .cancelled)

        let expansionID = UUID()
        let expansionContextID = snapshotContextID
        activeExpansionID = expansionID
        expandingNodeID = node.id
        expansionCompletion = completion

        let target = ScanTarget(url: node.url)
        let stream = scanService.scan(target: target, options: options)
        expandTask = Task { [weak self] in
            await self?.consumeExpansionStream(
                stream,
                node: node,
                expansionID: expansionID,
                snapshotContextID: expansionContextID
            )
        }
    }

    private func consumeScanStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        scanID: UUID
    ) async {
        do {
            for try await event in stream {
                guard activeScanID == scanID else { break }
                handle(event, scanID: scanID)
            }
        } catch is CancellationError {
            completeCancelledScan(scanID: scanID)
            return
        } catch {
            failScan(error, scanID: scanID)
            return
        }

        completeScanIfActive(scanID: scanID)
    }

    private func consumeExpansionStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        node: FileNodeRecord,
        expansionID: UUID,
        snapshotContextID expansionContextID: UUID
    ) async {
        do {
            var expandedSnapshot: ScanSnapshot?
            for try await event in stream {
                guard activeExpansionID == expansionID else { return }
                if case .finished(let snapshot) = event {
                    expandedSnapshot = snapshot
                }
            }

            try Task.checkCancellation()
            guard activeExpansionID == expansionID else { return }
            guard let expandedSnapshot else {
                completeExpansion(id: expansionID, result: .cancelled)
                return
            }

            let replacementRootID = try await replaceNodeInTree(
                node,
                with: expandedSnapshot,
                expansionID: expansionID,
                snapshotContextID: expansionContextID
            )
            guard activeExpansionID == expansionID else { return }
            if let replacementRootID {
                completeExpansion(id: expansionID, result: .expanded(replacementRootID: replacementRootID))
            } else {
                completeExpansion(id: expansionID, result: .skipped)
            }
        } catch is CancellationError {
            completeExpansion(id: expansionID, result: .cancelled)
        } catch {
            completeExpansion(
                id: expansionID,
                result: .failed(message: String(localized: "Failed to expand '\(node.name)': \(error.localizedDescription)", comment: "Error shown when expanding a summarized folder fails."))
            )
        }
    }

    private func handle(_ event: ScanProgressEvent, scanID: UUID) {
        guard activeScanID == scanID else { return }

        switch event {
        case .executionMode(let mode):
            handleExecutionMode(mode)
        case .progress(let metrics):
            handleProgress(metrics, scanID: scanID)
        case .warning:
            break
        case .finished(let snapshot):
            finishScan(with: snapshot, scanID: scanID)
        }
    }

    private func handleExecutionMode(_ mode: ScanExecutionMode) {
        if case .fullFallback = mode,
           progress.executionMode == .incremental || progress.executionMode == .incrementalNoChanges {
            resetProgressThrottling()
            scanMetrics = ScanMetrics()
        }
        progress.executionMode = mode
    }

    private func handleProgress(_ metrics: ScanMetrics, scanID: UUID) {
        guard activeScanID == scanID else { return }

        if shouldPublishProgressImmediately {
            publishProgress(metrics)
            return
        }

        pendingProgressMetrics = metrics
        schedulePendingProgressPublish(scanID: scanID)
    }

    private var shouldPublishProgressImmediately: Bool {
        guard progressThrottleDuration > .zero else { return true }
        guard let lastProgressPublishTime else { return true }

        return lastProgressPublishTime.duration(to: progressClock.now) >= progressThrottleDuration
    }

    private func schedulePendingProgressPublish(scanID: UUID) {
        guard progressPublishTask == nil else { return }

        let delay: Duration
        if let lastProgressPublishTime {
            let elapsed = lastProgressPublishTime.duration(to: progressClock.now)
            delay = elapsed >= progressThrottleDuration ? .zero : progressThrottleDuration - elapsed
        } else {
            delay = .zero
        }

        progressPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            self?.publishPendingProgress(scanID: scanID)
        }
    }

    private func publishPendingProgress(scanID: UUID) {
        guard activeScanID == scanID else { return }
        progressPublishTask = nil
        guard let pendingProgressMetrics else { return }
        publishProgress(pendingProgressMetrics)
    }

    private func publishProgress(_ metrics: ScanMetrics) {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = progressClock.now
        scanMetrics = metrics
    }

    private func finishScan(with snapshot: ScanSnapshot, scanID: UUID) {
        guard activeScanID == scanID else { return }

        flushPendingProgress(scanID: scanID)
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot

        var completedMetrics = scanMetrics
        completedMetrics.recalculateProgress(isComplete: true)
        publishProgress(completedMetrics)

        activeScanID = nil
        scanTask = nil
        phase = .displaying
        publishCompletionNotice(for: progress.executionMode)
        onScanFinished?(snapshot)
    }

    func dismissScanCompletionNotice() {
        completionNoticeDismissTask?.cancel()
        completionNoticeDismissTask = nil
        scanCompletionNotice = nil
    }

    private func publishCompletionNotice(for mode: ScanExecutionMode?) {
        let notice: ScanCompletionNotice?
        let automaticallyDismisses: Bool
        switch mode {
        case .incremental:
            notice = .incrementalUpdated
            automaticallyDismisses = true
        case .incrementalNoChanges:
            notice = .noChanges
            automaticallyDismisses = true
        case .fullFallback(let reason):
            notice = .fullFallback(reason)
            automaticallyDismisses = false
        case .full, .preparingIncremental, .none:
            notice = nil
            automaticallyDismisses = false
        }

        completionNoticeDismissTask?.cancel()
        completionNoticeDismissTask = nil
        scanCompletionNotice = notice
        guard automaticallyDismisses, notice != nil else { return }

        completionNoticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            self?.scanCompletionNotice = nil
            self?.completionNoticeDismissTask = nil
        }
    }

    private func apply(snapshot: ScanSnapshot) {
        publishSnapshot(snapshot, startsNewContext: true)
    }

    private func publishSnapshot(
        _ snapshot: ScanSnapshot?,
        startsNewContext: Bool
    ) {
        if startsNewContext {
            snapshotContextID = UUID()
        }
        snapshotRevision &+= 1
        self.snapshot = snapshot
    }

    private func completeCancelledScan(scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        if snapshot == nil {
            phase = .idle
        }
        activeScanID = nil
        scanTask = nil
    }

    private func failScan(_ error: Error, scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        phase = .failed
        scanErrorMessage = error.localizedDescription
        activeScanID = nil
        scanTask = nil
    }

    private func completeScanIfActive(scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        phase = snapshot == nil ? .idle : .displaying
        activeScanID = nil
        scanTask = nil
    }

    private func flushPendingProgress(scanID: UUID) {
        guard activeScanID == scanID else { return }
        progressPublishTask?.cancel()
        progressPublishTask = nil

        if let pendingProgressMetrics {
            publishProgress(pendingProgressMetrics)
        }
    }

    private func resetProgressThrottling() {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = nil
    }

    private func cancelExpansion(completeWith result: ScanExpansionResult?) {
        activeExpansionID = nil
        expandingNodeID = nil
        expandTask?.cancel()
        expandTask = nil

        guard let result, let completion = expansionCompletion else {
            expansionCompletion = nil
            return
        }

        expansionCompletion = nil
        completion(result)
    }

    private func completeExpansion(id: UUID, result: ScanExpansionResult) {
        guard activeExpansionID == id else { return }

        activeExpansionID = nil
        expandingNodeID = nil
        expandTask = nil
        guard let completion = expansionCompletion else { return }
        expansionCompletion = nil
        completion(result)
    }

    @discardableResult
    private func replaceNodeInTree(
        _ oldNode: FileNodeRecord,
        with expandedSnapshot: ScanSnapshot,
        expansionID: UUID,
        snapshotContextID expansionContextID: UUID
    ) async throws -> FileNodeRecord.ID? {
        while activeExpansionID == expansionID,
              snapshotContextID == expansionContextID {
            try Task.checkCancellation()
            guard let currentSnapshot = snapshot,
                  let currentNode = currentSnapshot.treeStore.node(id: oldNode.id),
                  currentNode.isAutoSummarized,
                  currentNode.fileIdentity == oldNode.fileIdentity else {
                return nil
            }

            let transformRevision = snapshotRevision
            guard let updatedSnapshot = try await snapshotTransformService.replacingNode(
                in: currentSnapshot,
                id: oldNode.id,
                with: expandedSnapshot.treeStore,
                additionalWarnings: expandedSnapshot.scanWarnings
            ) else { return nil }
            try Task.checkCancellation()
            guard activeExpansionID == expansionID,
                  snapshotContextID == expansionContextID else {
                return nil
            }
            guard snapshotRevision == transformRevision else { continue }

            publishSnapshot(updatedSnapshot, startsNewContext: false)
            return expandedSnapshot.root.id
        }
        return nil
    }
}
