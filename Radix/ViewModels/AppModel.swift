//
//  AppModel.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Combine
import Foundation

enum ArchiveOperationKind: String, Equatable, Sendable {
    case export
    case importPreview
    case `import`
    case compare
}

struct ArchiveOperationState: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ArchiveOperationKind
    let title: String
    var message: String
    var progressFraction: Double?

    var isDeterminate: Bool {
        progressFraction != nil
    }
}

struct ExportConfirmationState: Identifiable, Equatable, Sendable {
    let id: UUID
    let archiveURL: URL
}

nonisolated enum ScanComparisonCandidateSource: Equatable, Sendable {
    case archive(URL)
    case currentSnapshot(UUID)
    case retainedSnapshot(ScanSnapshot)

    static func == (
        lhs: ScanComparisonCandidateSource,
        rhs: ScanComparisonCandidateSource
    ) -> Bool {
        switch (lhs, rhs) {
        case (.archive(let lhsURL), .archive(let rhsURL)):
            return lhsURL == rhsURL
        case (.currentSnapshot(let lhsID), .currentSnapshot(let rhsID)):
            return lhsID == rhsID
        case (.retainedSnapshot(let lhsSnapshot), .retainedSnapshot(let rhsSnapshot)):
            return lhsSnapshot.id == rhsSnapshot.id
        default:
            return false
        }
    }
}

nonisolated enum ScanComparisonSlot: String, CaseIterable, Identifiable, Sendable {
    case before
    case after

    var id: String { rawValue }

    var title: String {
        switch self {
        case .before:
            return "Earlier Scan"
        case .after:
            return "Later Scan"
        }
    }
}

nonisolated struct ScanComparisonCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: ScanComparisonCandidateSource
    let displayName: String
    let path: String
    let targetKind: ScanTargetKind
    let scanDate: Date
    let totalAllocatedSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let warningCount: Int
    let scanOptions: ScanOptions?

    init(preview: ScanArchivePreview) {
        self.id = UUID()
        self.source = .archive(preview.archiveURL)
        self.displayName = preview.target.displayName
        self.path = preview.target.path
        self.targetKind = preview.target.kind
        self.scanDate = preview.finishedAt ?? preview.startedAt
        self.totalAllocatedSize = preview.totalAllocatedSize
        self.fileCount = preview.fileCount
        self.directoryCount = preview.directoryCount
        self.warningCount = preview.warningCount
        self.scanOptions = preview.scanOptions
    }

    init(snapshot: ScanSnapshot) {
        self.id = snapshot.id
        self.source = .currentSnapshot(snapshot.id)
        self.displayName = snapshot.target.displayName
        self.path = snapshot.target.url.path
        self.targetKind = snapshot.target.kind
        self.scanDate = snapshot.finishedAt ?? snapshot.startedAt
        self.totalAllocatedSize = snapshot.aggregateStats.totalAllocatedSize
        self.fileCount = snapshot.aggregateStats.fileCount
        self.directoryCount = snapshot.aggregateStats.directoryCount
        self.warningCount = snapshot.scanWarnings.count
        self.scanOptions = snapshot.scanOptions
    }

    init(retainedSnapshot snapshot: ScanSnapshot) {
        self.id = snapshot.id
        self.source = .retainedSnapshot(snapshot)
        self.displayName = snapshot.target.displayName
        self.path = snapshot.target.url.path
        self.targetKind = snapshot.target.kind
        self.scanDate = snapshot.finishedAt ?? snapshot.startedAt
        self.totalAllocatedSize = snapshot.aggregateStats.totalAllocatedSize
        self.fileCount = snapshot.aggregateStats.fileCount
        self.directoryCount = snapshot.aggregateStats.directoryCount
        self.warningCount = snapshot.scanWarnings.count
        self.scanOptions = snapshot.scanOptions
    }

    var isCurrentScan: Bool {
        if case .currentSnapshot = source {
            return true
        }
        return false
    }
}

nonisolated struct ScanComparisonSetup: Identifiable, Equatable, Sendable {
    let id: UUID
    var before: ScanComparisonCandidate?
    var after: ScanComparisonCandidate?
    var loadingSlot: ScanComparisonSlot?
    var errorMessage: String?

    init(
        before: ScanComparisonCandidate? = nil,
        after: ScanComparisonCandidate? = nil,
        loadingSlot: ScanComparisonSlot? = nil,
        errorMessage: String? = nil
    ) {
        self.id = UUID()
        self.before = before
        self.after = after
        self.loadingSlot = loadingSlot
        self.errorMessage = errorMessage
    }

    var canCompare: Bool {
        guard loadingSlot == nil,
              let before,
              let after else {
            return false
        }
        return before.source != after.source && validationMessage == nil
    }

    var validationMessage: String? {
        guard let before,
              let after else {
            return nil
        }
        if before.source == after.source {
            return "Choose two different scans."
        }
        guard before.targetKind == after.targetKind,
              Self.normalizedRootPath(before.path) == Self.normalizedRootPath(after.path) else {
            return "Choose scans of the same location."
        }
        if before.scanDate > after.scanDate {
            return "The earlier scan must precede the later scan."
        }
        if let beforeOptions = before.scanOptions,
           let afterOptions = after.scanOptions,
           beforeOptions != afterOptions {
            return "Choose scans made with the same scan settings."
        }
        if (before.scanOptions == nil) != (after.scanOptions == nil) {
            return "One scan is missing its settings, so these scans cannot be compared safely."
        }
        return nil
    }

    var resolvedCandidates: (before: ScanComparisonCandidate, after: ScanComparisonCandidate)? {
        guard let before,
              let after else {
            return nil
        }
        return (before, after)
    }

    var currentSnapshotID: UUID? {
        if case .currentSnapshot(let id)? = before?.source {
            return id
        }
        if case .currentSnapshot(let id)? = after?.source {
            return id
        }
        return nil
    }

    func candidate(for slot: ScanComparisonSlot) -> ScanComparisonCandidate? {
        switch slot {
        case .before:
            return before
        case .after:
            return after
        }
    }

    func canAssignCurrentScan(to slot: ScanComparisonSlot) -> Bool {
        let otherCandidate = switch slot {
        case .before:
            after
        case .after:
            before
        }
        return otherCandidate?.isCurrentScan != true
    }

    mutating func setCandidate(_ candidate: ScanComparisonCandidate?, for slot: ScanComparisonSlot) {
        switch slot {
        case .before:
            before = candidate
        case .after:
            after = candidate
        }
    }

    mutating func swap() {
        Swift.swap(&before, &after)
    }

    private static func normalizedRootPath(_ path: String) -> String {
        URL(filePath: path, directoryHint: .isDirectory)
            .standardizedFileURL
            .path
    }
}

struct DiscardPileState: Equatable, Sendable {
    let nodeIDs: [FileNodeRecord.ID]
    let snapshotID: UUID?

    init(
        nodeIDs: [FileNodeRecord.ID] = [],
        snapshotID: UUID? = nil
    ) {
        self.nodeIDs = nodeIDs
        self.snapshotID = nodeIDs.isEmpty ? nil : snapshotID
    }

    var isEmpty: Bool {
        nodeIDs.isEmpty
    }
}

struct DiscardPileSummary: Equatable, Sendable {
    let itemCount: Int
    let totalAllocatedSize: Int64

    var isEmpty: Bool {
        itemCount == 0
    }
}

@MainActor
final class AppModel: ObservableObject {
    private struct PostTrashRemovalRequest: Sendable {
        let nodeID: FileNodeRecord.ID
        let fallbackFocusID: FileNodeRecord.ID?
    }

    private struct OptimisticTrashVisibilityState: Equatable, Sendable {
        let nodeIDs: Set<FileNodeRecord.ID>
        let snapshotID: UUID?

        init(
            nodeIDs: Set<FileNodeRecord.ID> = [],
            snapshotID: UUID? = nil
        ) {
            self.nodeIDs = nodeIDs
            self.snapshotID = nodeIDs.isEmpty ? nil : snapshotID
        }
    }

    struct PendingTrashSelection {
        let nodes: [FileNodeRecord]
        let allowsHiddenNodes: Bool

        init(
            nodes: [FileNodeRecord],
            allowsHiddenNodes: Bool = false
        ) {
            self.nodes = nodes
            self.allowsHiddenNodes = allowsHiddenNodes
        }
    }

    private enum NavigationAction: Sendable {
        case select(FileNodeRecord.ID?)
        case selectMultiple(Set<FileNodeRecord.ID>, primary: FileNodeRecord.ID?)
        case focus(FileNodeRecord.ID?)
        case selectAndFocus(FileNodeRecord.ID)
        case reveal(FileNodeRecord.ID)
        case navigateBack
        case navigateForward
        case navigateToParent
        case resetFocusToRoot
        case clearSelection
    }

    private enum FileActionError: LocalizedError {
        case noSelection
        case unavailable(path: String)
        case changedSinceScan(path: String)
        case missingScannedIdentity(path: String)
        case currentIdentityUnavailable(path: String, reason: String)
        case unsupported
        case directoryRequired
        case packageContentsHidden(settingEnabled: Bool)
        case folderRequiredForDrop
        case fullDiskAccessSettingsUnavailable
        case readOnlySnapshot
        case currentComparisonSnapshotUnavailable

        var alertTitle: String? {
            switch self {
            case .packageContentsHidden:
                return "Package Contents Hidden"
            default:
                return nil
            }
        }

        var errorDescription: String? {
            switch self {
            case .noSelection:
                return "Select an item first."
            case .unavailable(let path):
                return "The item at \(path) is no longer available."
            case .changedSinceScan(let path):
                return "The item at \(path) changed since this scan. Rescan before moving it to Trash."
            case .missingScannedIdentity(let path):
                return "Radix could not verify the scanned identity for \(path). Rescan before moving it to Trash."
            case .currentIdentityUnavailable(let path, let reason):
                return "Radix could not verify the current identity for \(path): \(reason)"
            case .unsupported:
                return "This item does not support that action."
            case .directoryRequired:
                return "Choose a folder with contents to zoom in."
            case .packageContentsHidden(let settingEnabled):
                if settingEnabled {
                    return "Radix scanned this package before package contents were expanded. Rescan this location to zoom into it."
                }
                return "Radix scanned this package as a single item. To zoom into it, turn on “Treat app bundles and packages as folders” in Settings, then rescan this location."
            case .folderRequiredForDrop:
                return "Drop a folder or mounted volume to start a scan."
            case .fullDiskAccessSettingsUnavailable:
                return "Radix could not open Full Disk Access settings."
            case .readOnlySnapshot:
                return "Imported snapshots are read-only."
            case .currentComparisonSnapshotUnavailable:
                return "Current scan changed. Start the comparison again."
            }
        }
    }

    @Published var showHiddenFiles = true
    @Published var treatPackagesAsDirectories = false
    @Published var maxRenderedDepth = 6
    @Published var autoSummarizeDirectories = true
    @Published var showFreeSpaceInSunburst = false
    @Published var scanCloudStorageFolders = false
    @Published var useScanExclusions = false
    @Published var exclusionPatterns = AppScanPreferences.defaults.exclusionPatterns
    @Published private(set) var availableTargets: [ScanTarget] = [] {
        didSet {
            refreshSidebarTargetSections()
        }
    }
    @Published var recentTargets: [ScanTarget] = [] {
        didSet {
            refreshSidebarTargetSections()
        }
    }
    @Published var showsOnboarding: Bool
    @Published private(set) var fullDiskAccessStatus: FullDiskAccessStatus
    @Published private(set) var isExportPanelPresented = false
    @Published var lastErrorMessage: String? {
        didSet {
            if lastErrorMessage == nil {
                lastActionErrorTitle = nil
            }
        }
    }
    @Published private(set) var archiveOperation: ArchiveOperationState?
    @Published private(set) var exportConfirmation: ExportConfirmationState?
    @Published private(set) var scanComparison: ScanComparison?
    @Published var pendingComparisonSetup: ScanComparisonSetup?
    @Published var pendingImportPreview: ScanArchivePreview?
    @Published var pendingTrashNode: FileNodeRecord?
    @Published var pendingTrashSelection: PendingTrashSelection?
    @Published private(set) var discardPile = DiscardPileState()
    @Published private(set) var usageStats = AppUsageStats.empty
    @Published private var optimisticTrashVisibility = OptimisticTrashVisibilityState()

    private let dependencies: AppDependencies
    private let scanCoordinator: ScanCoordinator
    private let sidebarModel: SidebarModel
    private let quickLookController: AppQuickLookController
    private let navigationModel = WorkspaceNavigationModel()
    private var lastActionErrorTitle: String?
    private let sidebarScanCacheController: SidebarScanCacheController
    private var lastPersistedScanPreferences: AppScanPreferences?

    private static let viewUpdateDeferralDelay: Duration = .milliseconds(1)
    private static let scanPreferencePersistenceDebounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(50)
    private var cancellables = Set<AnyCancellable>()
    private var deferredScanStartTask: Task<Void, Never>?
    private var deferredScanStartID: UUID?
    private var deferredSidebarSelectionTask: Task<Void, Never>?
    private var deferredSidebarSelectionID: UUID?
    private var deferredNavigationActionTask: Task<Void, Never>?
    private var deferredNavigationActionID: UUID?
    private var deferredDiscardPileAddTask: Task<Void, Never>?
    private var deferredDiscardPileAddID: UUID?
    private var deferredNavigationContextTask: Task<Void, Never>?
    private var deferredNavigationContextID: UUID?
    private var deferredNavigationContextSnapshotID: UUID?
    private var postTrashRemovalTask: Task<Void, Never>?
    private var exportPanelTask: Task<Void, Never>?
    private var comparisonPanelTask: Task<Void, Never>?
    private var snapshotArchiveTask: Task<Void, Never>?
    private var snapshotArchiveProgressTask: Task<Void, Never>?
    private var exportConfirmationDismissTask: Task<Void, Never>?
    /// The completed live scan immediately preceding the active scan. Keeping this in memory
    /// makes a rescan comparison available without silently writing another full archive.
    private var previousScanComparisonBaseline: ScanSnapshot?
    private var pendingScanComparisonBaseline: ScanSnapshot?
    private var postTrashRemovalRequests: [PostTrashRemovalRequest] = []
    private var fullDiskAccessRefreshTask: Task<Void, Never>?
    private var targetCapacityDescriptionsRefreshTask: Task<Void, Never>?

    init(
        dependencies: AppDependencies = .live,
        completedScanCacheMinimumRetainedSnapshotCount: Int = 2,
        completedScanCacheMaxTotalNodeCount: Int = 250_000
    ) {
        self.dependencies = dependencies
        self.scanCoordinator = ScanCoordinator(scanService: dependencies.scanService)
        self.sidebarModel = SidebarModel(
            recentTargetStore: dependencies.recentTargets,
            preferredSmartTargetIDs: dependencies.systemActions.preferredSmartTargetIDs
        )
        self.quickLookController = AppQuickLookController(systemActions: dependencies.systemActions)
        self.sidebarScanCacheController = SidebarScanCacheController(
            minimumRetainedSnapshotCount: completedScanCacheMinimumRetainedSnapshotCount,
            maxTotalNodeCount: completedScanCacheMaxTotalNodeCount
        )

        let preferences = dependencies.preferences.loadPreferences()
        showHiddenFiles = preferences.scan.showHiddenFiles
        treatPackagesAsDirectories = preferences.scan.treatPackagesAsDirectories
        maxRenderedDepth = preferences.scan.maxRenderedDepth
        autoSummarizeDirectories = preferences.scan.autoSummarizeDirectories
        showFreeSpaceInSunburst = preferences.scan.showFreeSpaceInSunburst
        scanCloudStorageFolders = preferences.scan.scanCloudStorageFolders
        useScanExclusions = preferences.scan.useScanExclusions
        exclusionPatterns = preferences.scan.exclusionPatterns
        lastPersistedScanPreferences = preferences.scan
        showsOnboarding = !preferences.didCompleteOnboarding
        usageStats = dependencies.usageStats.loadUsageStats()
        fullDiskAccessStatus = dependencies.systemActions.usesAsyncFullDiskAccessStatus
            ? .unknown
            : dependencies.systemActions.currentFullDiskAccessStatus()
        recentTargets = dependencies.recentTargets.loadAvailableTargets()

        refreshAvailableTargets()
        refreshSidebarTargetSections()
        if dependencies.systemActions.usesAsyncFullDiskAccessStatus {
            refreshFullDiskAccessStatus()
        }
        quickLookController.delegate = self
        observeNavigationModel()
        observeScanCoordinator()
        observeMountedVolumes()
        observePreferences()
        quickLookController.installKeyMonitor()
    }

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }

    func cleanup() {
        flushPendingScanPreferences()
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        sidebarScanCacheController.resetTransientState()
        fullDiskAccessRefreshTask?.cancel()
        fullDiskAccessRefreshTask = nil
        targetCapacityDescriptionsRefreshTask?.cancel()
        targetCapacityDescriptionsRefreshTask = nil
        exportPanelTask?.cancel()
        exportPanelTask = nil
        comparisonPanelTask?.cancel()
        comparisonPanelTask = nil
        isExportPanelPresented = false
        cancelArchiveOperation()
        dismissExportConfirmation()
        pendingComparisonSetup = nil
        pendingImportPreview = nil
        quickLookController.setWorkspaceWindowNumber(nil)
        scanCoordinator.stopScan()
        quickLookController.removeKeyMonitor()
    }

    func suspendMainWindowActivity() {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        sidebarScanCacheController.clearActiveScanTracking()
        if scanCoordinator.canStopScan {
            scanCoordinator.stopScan()
        } else {
            scanCoordinator.stopScan(resetState: false)
        }
        quickLookController.closePreview()
    }

    func suspendBackgroundActivity() {
        quickLookController.closePreview()
    }

    var scanState: ScanCoordinator {
        scanCoordinator
    }

    var navigation: WorkspaceNavigationModel {
        navigationModel
    }

    var sidebar: SidebarModel {
        sidebarModel
    }

    var discardPileNodes: [FileNodeRecord] {
        resolvedDiscardPileNodes()
    }

    var discardPileSummary: DiscardPileSummary {
        let nodes = resolvedDiscardPileNodes()
        return DiscardPileSummary(
            itemCount: nodes.count,
            totalAllocatedSize: nodes.reduce(into: Int64(0)) { total, node in
                total += node.allocatedSize
            }
        )
    }

    var discardPileHiddenNodeIDs: Set<FileNodeRecord.ID> {
        hiddenNodeIDs(for: scanCoordinator.snapshot?.id)
    }

    var startupDiskTarget: ScanTarget? {
        availableTargets.first(where: { $0.kind == .volume && $0.url.path == "/" })
    }

    var smartTargets: [ScanTarget] {
        sidebarModel.smartTargets
    }

    var recentScanTargets: [ScanTarget] {
        sidebarModel.recentScanTargets
    }

    var targetCapacityDescriptions: [String: String] {
        sidebarModel.targetCapacityDescriptions
    }

    private func refreshSidebarTargetSections() {
        sidebarModel.refreshTargetSections(
            availableTargets: availableTargets,
            recentTargets: recentTargets
        )
    }

    var errorAlertTitle: String {
        if scanCoordinator.phase == .failed {
            return "Scan Failed"
        }
        return lastActionErrorTitle ?? "Action Failed"
    }

    var canRescanFromErrorAlert: Bool {
        scanCoordinator.phase == .failed && scanCoordinator.canRescan
    }

    var isArchiveOperationInProgress: Bool {
        archiveOperation != nil
    }

    func dismissOnboarding() {
        showsOnboarding = false
        dependencies.preferences.markOnboardingComplete()
    }

    func presentOnboarding() {
        showsOnboarding = true
    }

    func refreshFullDiskAccessStatus() {
        fullDiskAccessRefreshTask?.cancel()

        guard dependencies.systemActions.usesAsyncFullDiskAccessStatus else {
            fullDiskAccessStatus = dependencies.systemActions.currentFullDiskAccessStatus()
            fullDiskAccessRefreshTask = nil
            return
        }

        fullDiskAccessRefreshTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.dependencies.systemActions.loadCurrentFullDiskAccessStatus()
            guard !Task.isCancelled else { return }
            self.fullDiskAccessStatus = status
            self.fullDiskAccessRefreshTask = nil
        }
    }

    func restoreDefaultPreferences() {
        showHiddenFiles = AppScanPreferences.defaults.showHiddenFiles
        treatPackagesAsDirectories = AppScanPreferences.defaults.treatPackagesAsDirectories
        maxRenderedDepth = AppScanPreferences.defaults.maxRenderedDepth
        autoSummarizeDirectories = AppScanPreferences.defaults.autoSummarizeDirectories
        showFreeSpaceInSunburst = AppScanPreferences.defaults.showFreeSpaceInSunburst
        scanCloudStorageFolders = AppScanPreferences.defaults.scanCloudStorageFolders
        useScanExclusions = AppScanPreferences.defaults.useScanExclusions
        exclusionPatterns = AppScanPreferences.defaults.exclusionPatterns
    }

    func clearRecentTargets() {
        recentTargets.removeAll()
        dependencies.recentTargets.clear()
    }

    func clearUsageStats() {
        usageStats = .empty
        dependencies.usageStats.clearUsageStats()
    }

    func recordSunburstSegmentClick() {
        updateUsageStats { stats in
            stats.recordSunburstSegmentClick()
        }
    }

    func removeRecentTarget(_ target: ScanTarget) {
        recentTargets = dependencies.recentTargets.remove(target, currentTargets: recentTargets)
        sidebarModel.clearActiveTargetIfNeededAfterRemovingRecentTarget(target)
    }

    /// Expands an auto-summarized directory by scanning it fully and replacing the node in the tree.
    func expandSummarizedNode(_ node: FileNodeRecord, completion: @escaping () -> Void) {
        let target = ScanTarget(url: node.url)
        let options = scanOptions(
            for: target,
            autoSummarizeDirectories: false,
            preferredExclusionRootPath: currentScanExclusionRootPath
        )

        scanCoordinator.expandSummarizedNode(node, options: options) { [weak self] result in
            guard let self else {
                completion()
                return
            }

            switch result {
            case .skipped, .cancelled:
                break
            case .expanded(let replacementRootID):
                navigationModel.select(nodeID: replacementRootID)
            case .failed(let message):
                presentErrorMessage(message)
            }

            completion()
        }
    }

    func presentOpenPanelAndScan() {
        guard !scanCoordinator.isScanning else { return }
        if let target = dependencies.systemActions.presentOpenPanel() {
            startScan(target)
        }
    }

    var canExportCurrentScan: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            !scanCoordinator.isScanning &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress
    }

    private var canPresentScanSnapshotPanel: Bool {
        !scanCoordinator.isScanning &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress &&
            pendingComparisonSetup == nil &&
            pendingImportPreview == nil
    }

    var canImportScanSnapshot: Bool {
        canPresentScanSnapshotPanel
    }

    var canCompareScanSnapshots: Bool {
        canPresentScanSnapshotPanel
    }

    var canUseWorkspaceCommands: Bool {
        scanComparison == nil
    }

    var canCompareCurrentScanWithSnapshot: Bool {
        canCompareScanSnapshots &&
            scanCoordinator.snapshot?.isComplete == true &&
            scanCoordinator.snapshotSource.allowsFileMutation
    }

    var canCompareCurrentScanWithPreviousScan: Bool {
        guard canCompareScanSnapshots,
              let currentSnapshot = scanCoordinator.snapshot,
              let previousSnapshot = previousScanComparisonBaseline,
              currentSnapshot.isComplete,
              currentSnapshot.source.allowsFileMutation else {
            return false
        }

        return Self.canUseAsComparisonBaseline(previousSnapshot, for: currentSnapshot)
    }

    var canUseCurrentScanInComparisonSetup: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            scanCoordinator.snapshotSource.allowsFileMutation
    }

    private var canConfirmImportPreview: Bool {
        !scanCoordinator.isScanning &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress
    }

    func exportCurrentScan() {
        guard canExportCurrentScan,
              let snapshot = scanCoordinator.snapshot else {
            return
        }

        let defaultFileName = defaultExportFileName(for: snapshot)
        let snapshotID = snapshot.id

        exportPanelTask?.cancel()
        isExportPanelPresented = true
        exportPanelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isExportPanelPresented = false
                self.exportPanelTask = nil
            }

            guard let destinationURL = await self.dependencies.systemActions.presentExportScanPanel(defaultFileName),
                  !Task.isCancelled,
                  self.scanCoordinator.snapshot?.id == snapshotID,
                  self.canExportCurrentScanIgnoringPresentedPanel else {
                return
            }

            self.startArchiveExport(snapshot: snapshot, destinationURL: destinationURL)
        }
    }

    private var canExportCurrentScanIgnoringPresentedPanel: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            !scanCoordinator.isScanning &&
            !isArchiveOperationInProgress
    }

    private func startArchiveExport(snapshot: ScanSnapshot, destinationURL: URL) {
        cancelArchiveOperation()
        let progressReporter = ScanArchiveProgressReporter()
        let operationID = beginArchiveOperation(
            kind: .export,
            title: "Exporting Snapshot",
            message: "Preparing archive",
            progressReporter: progressReporter
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                progressReporter.finish()
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let exportOptions = ScanArchiveExportOptions(
                    appVersion: Self.currentAppVersion(),
                    progressReporter: progressReporter
                )
                let exportTask = Task.detached(priority: .utility) {
                    try await archiveService.export(
                        snapshot: snapshot,
                        to: destinationURL,
                        options: exportOptions
                    )
                }
                let result = try await Self.value(cancelling: exportTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                self.lastErrorMessage = nil
                self.presentExportConfirmation(for: result.archiveURL)
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error, title: "Export Failed")
            }
        }
    }

    func revealExportedSnapshotInFinder() {
        guard let exportConfirmation else { return }
        dependencies.systemActions.reveal(exportConfirmation.archiveURL)
        dismissExportConfirmation()
    }

    func dismissExportConfirmation() {
        exportConfirmationDismissTask?.cancel()
        exportConfirmationDismissTask = nil
        exportConfirmation = nil
    }

    private func presentExportConfirmation(for archiveURL: URL) {
        dismissExportConfirmation()
        let confirmation = ExportConfirmationState(id: UUID(), archiveURL: archiveURL)
        exportConfirmation = confirmation
        exportConfirmationDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard self?.exportConfirmation?.id == confirmation.id else { return }
            self?.exportConfirmation = nil
            self?.exportConfirmationDismissTask = nil
        }
    }

    func importScanSnapshot() {
        guard canImportScanSnapshot else { return }
        guard let sourceURL = dependencies.systemActions.presentImportScanPanel() else {
            return
        }

        importScanSnapshot(from: sourceURL)
    }

    func importScanSnapshot(from sourceURL: URL) {
        guard canImportScanSnapshot else {
            presentErrorMessage(importUnavailableMessage)
            return
        }

        previewImportScanSnapshot(from: sourceURL)
    }

    private var importUnavailableMessage: String {
        if scanCoordinator.isScanning {
            return "Stop the current scan before importing a snapshot."
        }
        if isExportPanelPresented {
            return "Finish choosing an export location before importing a snapshot."
        }
        if isArchiveOperationInProgress {
            return "Cancel the current archive operation before importing a snapshot."
        }
        if pendingComparisonSetup != nil {
            return "Finish or cancel the current comparison setup before importing a snapshot."
        }
        if pendingImportPreview != nil {
            return "Finish or cancel the current import preview before importing another snapshot."
        }
        return "Radix cannot import a snapshot right now."
    }

    private var comparisonUnavailableMessage: String {
        if scanCoordinator.isScanning {
            return "Stop the current scan before comparing snapshots."
        }
        if isExportPanelPresented {
            return "Finish choosing an export location before comparing snapshots."
        }
        if isArchiveOperationInProgress {
            return "Cancel the current archive operation before comparing snapshots."
        }
        if pendingComparisonSetup != nil {
            return "Finish or cancel the current comparison setup before comparing snapshots."
        }
        if pendingImportPreview != nil {
            return "Finish or cancel the current import preview before comparing snapshots."
        }
        return "Radix cannot compare snapshots right now."
    }

    func compareScanSnapshots() {
        guard canCompareScanSnapshots else {
            presentErrorMessage(comparisonUnavailableMessage)
            return
        }
        beginComparisonSetup()
    }

    func compareScanSnapshots(from sourceURLs: [URL]) {
        guard canCompareScanSnapshots else {
            presentErrorMessage(comparisonUnavailableMessage)
            return
        }
        guard sourceURLs.count == 2 else {
            presentErrorMessage("Choose exactly two Radix scan snapshots to compare.")
            return
        }

        previewArchiveSnapshotComparison(sourceURLs: sourceURLs)
    }

    func compareCurrentScanWithSnapshot() {
        guard canCompareCurrentScanWithSnapshot,
              let currentSnapshot = scanCoordinator.snapshot else {
            presentErrorMessage(currentScanComparisonUnavailableMessage)
            return
        }
        beginComparisonSetup(after: ScanComparisonCandidate(snapshot: currentSnapshot))
    }

    func compareCurrentScanWithPreviousScan() {
        guard canCompareCurrentScanWithPreviousScan,
              let beforeSnapshot = previousScanComparisonBaseline,
              let afterSnapshot = scanCoordinator.snapshot else {
            presentErrorMessage("Rescan this location with the same scan options before comparing it with the previous scan.")
            return
        }

        beginComparisonSetup(
            before: ScanComparisonCandidate(retainedSnapshot: beforeSnapshot),
            after: ScanComparisonCandidate(snapshot: afterSnapshot)
        )
    }

    func compareCurrentScan(with sourceURL: URL) {
        guard canCompareCurrentScanWithSnapshot,
              let currentSnapshot = scanCoordinator.snapshot else {
            presentErrorMessage(currentScanComparisonUnavailableMessage)
            return
        }
        beginComparisonSetup(after: ScanComparisonCandidate(snapshot: currentSnapshot))
        previewComparisonSnapshot(from: sourceURL, for: .before)
    }

    private var currentScanComparisonUnavailableMessage: String {
        if !canCompareScanSnapshots {
            return comparisonUnavailableMessage
        }
        return "Complete a live scan before comparing it with a snapshot."
    }

    func closeScanComparison() {
        scanComparison = nil
    }

    func canRevealComparisonRowInFinder(_ row: ScanComparisonRow) -> Bool {
        guard let node = currentScanNode(for: row.beforeNode, afterNode: row.afterNode) else {
            return false
        }
        return dependencies.systemActions.fileExists(node.url)
    }

    func revealComparisonRowInFinder(_ row: ScanComparisonRow) {
        guard let node = currentScanNode(for: row.beforeNode, afterNode: row.afterNode) else {
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
            return
        }
        guard dependencies.systemActions.fileExists(node.url) else {
            presentError(FileActionError.unavailable(path: node.url.path))
            return
        }
        dependencies.systemActions.reveal(node.url)
    }

    func copyComparisonRowPath(_ row: ScanComparisonRow) {
        guard let url = row.fileURL else {
            presentError(FileActionError.unsupported)
            return
        }
        do {
            try dependencies.systemActions.copyPath(url)
        } catch {
            presentError(error)
        }
    }

    func canShowComparisonRowInBrowser(_ row: ScanComparisonRow) -> Bool {
        canShowComparisonNodeInBrowser(beforeNode: row.beforeNode, afterNode: row.afterNode)
    }

    func showComparisonRowInBrowser(_ row: ScanComparisonRow) {
        showComparisonNodeInBrowser(beforeNode: row.beforeNode, afterNode: row.afterNode)
    }

    func canRevealComparisonChangeNodeInFinder(_ node: ScanComparisonChangeTreeNode) -> Bool {
        guard let currentNode = currentScanNode(for: node.beforeNode, afterNode: node.afterNode) else {
            return false
        }
        return dependencies.systemActions.fileExists(currentNode.url)
    }

    func revealComparisonChangeNodeInFinder(_ node: ScanComparisonChangeTreeNode) {
        guard let currentNode = currentScanNode(for: node.beforeNode, afterNode: node.afterNode) else {
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
            return
        }
        guard dependencies.systemActions.fileExists(currentNode.url) else {
            presentError(FileActionError.unavailable(path: currentNode.url.path))
            return
        }
        dependencies.systemActions.reveal(currentNode.url)
    }

    func copyComparisonChangeNodePath(_ node: ScanComparisonChangeTreeNode) {
        guard let url = node.fileURL else {
            presentError(FileActionError.unsupported)
            return
        }
        do {
            try dependencies.systemActions.copyPath(url)
        } catch {
            presentError(error)
        }
    }

    func canShowComparisonChangeNodeInBrowser(_ node: ScanComparisonChangeTreeNode) -> Bool {
        canShowComparisonNodeInBrowser(beforeNode: node.beforeNode, afterNode: node.afterNode)
    }

    func showComparisonChangeNodeInBrowser(_ node: ScanComparisonChangeTreeNode) {
        showComparisonNodeInBrowser(beforeNode: node.beforeNode, afterNode: node.afterNode)
    }

    func canRevealComparisonLocationInFinder(_ location: ScanComparisonLocationChange) -> Bool {
        guard let node = currentScanNode(for: location.beforeNode, afterNode: location.afterNode) else {
            return false
        }
        return dependencies.systemActions.fileExists(node.url)
    }

    func revealComparisonLocationInFinder(_ location: ScanComparisonLocationChange) {
        guard let node = currentScanNode(for: location.beforeNode, afterNode: location.afterNode) else {
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
            return
        }
        guard dependencies.systemActions.fileExists(node.url) else {
            presentError(FileActionError.unavailable(path: node.url.path))
            return
        }
        dependencies.systemActions.reveal(node.url)
    }

    func canShowComparisonLocationInBrowser(_ location: ScanComparisonLocationChange) -> Bool {
        canShowComparisonNodeInBrowser(beforeNode: location.beforeNode, afterNode: location.afterNode)
    }

    func showComparisonLocationInBrowser(_ location: ScanComparisonLocationChange) {
        showComparisonNodeInBrowser(beforeNode: location.beforeNode, afterNode: location.afterNode)
    }

    private func canShowComparisonNodeInBrowser(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) -> Bool {
        guard let nodeID = currentScanNodeID(beforeNode: beforeNode, afterNode: afterNode) else {
            return false
        }
        return isVisibleNavigationNode(nodeID)
    }

    private func showComparisonNodeInBrowser(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) {
        guard let nodeID = currentScanNodeID(beforeNode: beforeNode, afterNode: afterNode) else {
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
            return
        }
        // Don't tear down the comparison unless the reveal will actually land — a node that
        // is hidden (e.g. in the discard pile) would be filtered by performNavigationAction,
        // leaving the user on an empty browser with their comparison gone.
        guard isVisibleNavigationNode(nodeID) else { return }
        closeScanComparison()
        revealAfterViewUpdate(nodeID: nodeID)
    }

    /// The node ID for a comparison row within the current live scan, or nil when the row's
    /// side is not the current scan (e.g. comparing two imported archives) or the node is gone.
    private func currentScanNode(
        for beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) -> FileNodeRecord? {
        guard let comparison = scanComparison,
              let currentSnapshotID = scanCoordinator.snapshot?.id else {
            return nil
        }
        if comparison.after.id == currentSnapshotID, let afterNode {
            return afterNode
        }
        if comparison.before.id == currentSnapshotID, let beforeNode {
            return beforeNode
        }
        return nil
    }

    private func currentScanNodeID(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) -> String? {
        currentScanNode(for: beforeNode, afterNode: afterNode)?.id
    }

    func swapPendingComparisonSetup() {
        guard var setup = pendingComparisonSetup else { return }
        setup.swap()
        setup.errorMessage = setup.validationMessage
        pendingComparisonSetup = setup
    }

    func cancelComparisonSetup() {
        guard pendingComparisonSetup != nil else { return }
        cancelArchiveOperation()
        pendingComparisonSetup = nil
    }

    func confirmComparisonSetup() {
        guard let setup = pendingComparisonSetup else { return }
        guard setup.canCompare,
              setup.resolvedCandidates != nil else {
            var updatedSetup = setup
            updatedSetup.errorMessage = setup.validationMessage ?? "Choose two scans to compare."
            pendingComparisonSetup = updatedSetup
            return
        }
        if let currentSnapshotID = setup.currentSnapshotID,
           scanCoordinator.snapshot?.id != currentSnapshotID {
            pendingComparisonSetup = nil
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
            return
        }

        pendingComparisonSetup = nil
        startComparison(setup)
    }

    func chooseComparisonSnapshot(for slot: ScanComparisonSlot) {
        guard pendingComparisonSetup != nil else { return }
        guard pendingComparisonSetup?.loadingSlot == nil else { return }
        let setupID = pendingComparisonSetup?.id

        comparisonPanelTask?.cancel()
        comparisonPanelTask = Task { @MainActor [weak self] in
            defer { self?.comparisonPanelTask = nil }
            guard let self,
                  let sourceURL = await self.dependencies.systemActions.presentComparisonSnapshotPanel(),
                  self.pendingComparisonSetup?.id == setupID,
                  self.pendingComparisonSetup?.loadingSlot == nil else {
                return
            }
            self.previewComparisonSnapshot(from: sourceURL, for: slot)
        }
    }

    func dropComparisonSnapshot(_ sourceURL: URL, for slot: ScanComparisonSlot) {
        guard pendingComparisonSetup != nil else { return }
        guard pendingComparisonSetup?.loadingSlot == nil else { return }
        guard sourceURL.pathExtension.lowercased() == ScanArchiveService.fileExtension else {
            pendingComparisonSetup?.errorMessage =
                "Drop a .\(ScanArchiveService.fileExtension) saved scan."
            return
        }

        previewComparisonSnapshot(from: sourceURL, for: slot)
    }

    func useCurrentScanForComparisonSlot(_ slot: ScanComparisonSlot) {
        guard var setup = pendingComparisonSetup else { return }
        guard canUseCurrentScanInComparisonSetup,
              let snapshot = scanCoordinator.snapshot else {
            setup.errorMessage = "Complete a live scan before using it in a comparison."
            pendingComparisonSetup = setup
            return
        }
        setup.setCandidate(ScanComparisonCandidate(snapshot: snapshot), for: slot)
        setup.errorMessage = setup.validationMessage
        pendingComparisonSetup = setup
    }

    func clearComparisonSlot(_ slot: ScanComparisonSlot) {
        guard var setup = pendingComparisonSetup else { return }
        setup.setCandidate(nil, for: slot)
        setup.errorMessage = nil
        pendingComparisonSetup = setup
    }

    private func beginComparisonSetup(
        before: ScanComparisonCandidate? = nil,
        after: ScanComparisonCandidate? = nil
    ) {
        cancelArchiveOperation()
        pendingComparisonSetup = ScanComparisonSetup(before: before, after: after)
    }

    private func previewComparisonSnapshot(from sourceURL: URL, for slot: ScanComparisonSlot) {
        guard var setup = pendingComparisonSetup,
              setup.loadingSlot == nil else {
            return
        }

        cancelArchiveOperation()
        setup.loadingSlot = slot
        setup.errorMessage = nil
        setup.setCandidate(nil, for: slot)
        pendingComparisonSetup = setup
        let setupID = setup.id

        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.clearComparisonSetupLoadingSlot(setupID: setupID, slot: slot)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let previewTask = Task.detached(priority: .utility) {
                    try await archiveService.previewSnapshot(from: sourceURL)
                }
                let preview = try await Self.value(cancelling: previewTask)
                guard !Task.isCancelled,
                      var currentSetup = self.pendingComparisonSetup,
                      currentSetup.id == setupID,
                      currentSetup.loadingSlot == slot else {
                    return
                }
                currentSetup.setCandidate(ScanComparisonCandidate(preview: preview), for: slot)
                currentSetup.loadingSlot = nil
                currentSetup.errorMessage = currentSetup.validationMessage
                self.pendingComparisonSetup = currentSetup
                self.lastErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard var currentSetup = self.pendingComparisonSetup,
                      currentSetup.id == setupID else {
                    return
                }
                currentSetup.loadingSlot = nil
                currentSetup.errorMessage = error.localizedDescription
                self.pendingComparisonSetup = currentSetup
            }
        }
    }

    private func clearComparisonSetupLoadingSlot(setupID: UUID, slot: ScanComparisonSlot) {
        guard var setup = pendingComparisonSetup,
              setup.id == setupID,
              setup.loadingSlot == slot else {
            return
        }
        setup.loadingSlot = nil
        pendingComparisonSetup = setup
    }

    private func previewArchiveSnapshotComparison(sourceURLs: [URL]) {
        cancelArchiveOperation()
        pendingComparisonSetup = nil
        let operationID = beginArchiveOperation(
            kind: .compare,
            title: "Preparing Comparison",
            message: "Reading snapshots",
            progressReporter: nil
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let setupTask = Task.detached(priority: .utility) {
                    let first = try await archiveService.previewSnapshot(from: sourceURLs[0])
                    try Task.checkCancellation()
                    let second = try await archiveService.previewSnapshot(from: sourceURLs[1])
                    try Task.checkCancellation()
                    let candidates = Self.orderedComparisonCandidates(
                        ScanComparisonCandidate(preview: first),
                        ScanComparisonCandidate(preview: second)
                    )
                    return ScanComparisonSetup(before: candidates.before, after: candidates.after)
                }
                let setup = try await Self.value(cancelling: setupTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                self.pendingComparisonSetup = setup
                self.lastErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error, title: "Comparison Failed")
            }
        }
    }

    private func startComparison(_ setup: ScanComparisonSetup) {
        guard let candidates = setup.resolvedCandidates else { return }
        cancelArchiveOperation()
        scanComparison = nil
        let currentSnapshot = scanCoordinator.snapshot
        let operationID = beginArchiveOperation(
            kind: .compare,
            title: "Comparing Snapshots",
            message: "Reading archives",
            progressReporter: nil
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let comparisonTask = Task.detached(priority: .utility) {
                    let before = try await Self.snapshot(
                        for: candidates.before.source,
                        archiveService: archiveService,
                        currentSnapshot: currentSnapshot
                    )
                    try Task.checkCancellation()
                    let after = try await Self.snapshot(
                        for: candidates.after.source,
                        archiveService: archiveService,
                        currentSnapshot: currentSnapshot
                    )
                    try Task.checkCancellation()
                    return try await ScanComparisonService().compare(before: before, after: after)
                }
                let comparison = try await Self.value(cancelling: comparisonTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                if let currentSnapshotID = setup.currentSnapshotID,
                   self.scanCoordinator.snapshot?.id != currentSnapshotID {
                    return
                }
                self.quickLookController.closePreview()
                self.scanComparison = comparison
                self.lastErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error, title: "Comparison Failed")
            }
        }
    }

    func confirmImportPreview() {
        guard canConfirmImportPreview,
              let preview = pendingImportPreview else {
            return
        }

        pendingImportPreview = nil
        importApprovedScanSnapshot(from: preview.archiveURL)
    }

    func cancelImportPreview() {
        cancelArchiveOperation()
        pendingImportPreview = nil
    }

    func cancelArchiveOperation() {
        snapshotArchiveTask?.cancel()
        snapshotArchiveTask = nil
        snapshotArchiveProgressTask?.cancel()
        snapshotArchiveProgressTask = nil
        archiveOperation = nil
    }

    private func previewImportScanSnapshot(from sourceURL: URL) {
        pendingImportPreview = nil
        cancelArchiveOperation()
        let operationID = beginArchiveOperation(
            kind: .importPreview,
            title: "Reading Snapshot",
            message: "Reading manifest",
            progressReporter: nil
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let previewTask = Task.detached(priority: .utility) {
                    try await archiveService.previewSnapshot(from: sourceURL)
                }
                let preview = try await Self.value(cancelling: previewTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                self.pendingImportPreview = preview
                self.lastErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error)
            }
        }
    }

    private func importApprovedScanSnapshot(from sourceURL: URL) {
        cancelArchiveOperation()
        let progressReporter = ScanArchiveProgressReporter()
        let operationID = beginArchiveOperation(
            kind: .import,
            title: "Importing Snapshot",
            message: "Reading archive",
            progressReporter: progressReporter
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                progressReporter.finish()
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let importTask = Task.detached(priority: .utility) {
                    try await archiveService.importSnapshot(
                        from: sourceURL,
                        progressReporter: progressReporter
                    )
                }
                let result = try await Self.value(cancelling: importTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                progressReporter.report(ScanArchiveProgress(
                    phase: .openingSnapshot,
                    message: "Opening snapshot"
                ))
                self.updateArchiveOperation(id: operationID, message: "Opening snapshot", progressFraction: nil)
                try await Task.sleep(for: .milliseconds(1))
                self.restoreImportedSnapshot(result.snapshot)
                self.lastErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error)
            }
        }
    }

    private func beginArchiveOperation(
        kind: ArchiveOperationKind,
        title: String,
        message: String,
        progressReporter: ScanArchiveProgressReporter?
    ) -> UUID {
        dismissExportConfirmation()
        let operationID = UUID()
        archiveOperation = ArchiveOperationState(
            id: operationID,
            kind: kind,
            title: title,
            message: message,
            progressFraction: nil
        )

        if let progressReporter {
            snapshotArchiveProgressTask = Task { @MainActor [weak self] in
                for await progress in progressReporter.updates {
                    guard let self else { return }
                    updateArchiveOperation(
                        id: operationID,
                        message: progress.message,
                        progressFraction: progress.fractionCompleted
                    )
                }
            }
        }

        return operationID
    }

    private func updateArchiveOperation(
        id operationID: UUID,
        message: String,
        progressFraction: Double?
    ) {
        guard var operation = archiveOperation,
              operation.id == operationID else {
            return
        }
        operation.message = message
        operation.progressFraction = progressFraction
        archiveOperation = operation
    }

    private func finishArchiveOperation(id operationID: UUID) {
        guard archiveOperation?.id == operationID || archiveOperation == nil else {
            return
        }
        snapshotArchiveTask = nil
        if archiveOperation?.id == operationID {
            archiveOperation = nil
        }
        snapshotArchiveProgressTask?.cancel()
        snapshotArchiveProgressTask = nil
    }

    private func isCurrentArchiveOperation(id operationID: UUID) -> Bool {
        archiveOperation?.id == operationID
    }

    nonisolated private static func value<T: Sendable>(cancelling task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func orderedComparisonCandidates(
        _ lhs: ScanComparisonCandidate,
        _ rhs: ScanComparisonCandidate
    ) -> (before: ScanComparisonCandidate, after: ScanComparisonCandidate) {
        let lhsDate = lhs.scanDate
        let rhsDate = rhs.scanDate
        if lhsDate == rhsDate {
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
                ? (rhs, lhs)
                : (lhs, rhs)
        }
        return lhsDate < rhsDate ? (lhs, rhs) : (rhs, lhs)
    }

    nonisolated private static func snapshot(
        for source: ScanComparisonCandidateSource,
        archiveService: any ScanArchiveServicing,
        currentSnapshot: ScanSnapshot?
    ) async throws -> ScanSnapshot {
        switch source {
        case .archive(let url):
            return try await archiveService.importSnapshot(from: url).snapshot
        case .currentSnapshot(let id):
            guard let currentSnapshot,
                  currentSnapshot.id == id else {
                throw FileActionError.currentComparisonSnapshotUnavailable
            }
            return currentSnapshot
        case .retainedSnapshot(let snapshot):
            return snapshot
        }
    }

    func startScan(_ target: ScanTarget) {
        // Defer state mutations to the next runloop to avoid
        // "Publishing changes from within view updates is not allowed."
        cancelArchiveOperation()
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationContextUpdate()
        cancelDeferredDiscardPileAdd()
        cancelPostTrashSnapshotRemoval()
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()

        scheduleDeferredViewUpdate(
            id: \.deferredScanStartID,
            task: \.deferredScanStartTask
        ) { model in
            model.startScanNow(target)
        }
    }

    private func cancelDeferredScanStart() {
        deferredScanStartID = nil
        deferredScanStartTask?.cancel()
        deferredScanStartTask = nil
    }

    private func cancelDeferredSidebarSelection() {
        deferredSidebarSelectionID = nil
        deferredSidebarSelectionTask?.cancel()
        deferredSidebarSelectionTask = nil
    }

    private func cancelDeferredNavigationAction() {
        deferredNavigationActionID = nil
        deferredNavigationActionTask?.cancel()
        deferredNavigationActionTask = nil
    }

    private func cancelDeferredDiscardPileAdd() {
        deferredDiscardPileAddID = nil
        deferredDiscardPileAddTask?.cancel()
        deferredDiscardPileAddTask = nil
    }

    private func cancelDeferredNavigationContextUpdate() {
        deferredNavigationContextSnapshotID = nil
        deferredNavigationContextID = nil
        deferredNavigationContextTask?.cancel()
        deferredNavigationContextTask = nil
    }

    private func scheduleDeferredNavigationContextUpdate(for snapshotID: UUID) {
        scheduleDeferredViewUpdate(
            id: \.deferredNavigationContextID,
            task: \.deferredNavigationContextTask
        ) { model in
            guard model.deferredNavigationContextSnapshotID == snapshotID,
                  model.scanCoordinator.snapshot?.id == snapshotID else {
                if model.deferredNavigationContextSnapshotID == snapshotID {
                    model.deferredNavigationContextSnapshotID = nil
                }
                return
            }

            model.deferredNavigationContextSnapshotID = nil
            model.navigationModel.refreshTableNodesForCurrentContext()
        }
    }

    private func cancelPostTrashSnapshotRemoval() {
        postTrashRemovalRequests.removeAll()
        postTrashRemovalTask?.cancel()
        postTrashRemovalTask = nil
    }

    private func clearOptimisticTrashVisibility() {
        guard optimisticTrashVisibility.snapshotID != nil else { return }
        optimisticTrashVisibility = OptimisticTrashVisibilityState()
    }

    private func scheduleDeferredViewUpdate(
        id idKeyPath: ReferenceWritableKeyPath<AppModel, UUID?>,
        task taskKeyPath: ReferenceWritableKeyPath<AppModel, Task<Void, Never>?>,
        perform: @MainActor @Sendable @escaping (AppModel) -> Void
    ) {
        let actionID = UUID()
        self[keyPath: idKeyPath] = actionID
        self[keyPath: taskKeyPath] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.viewUpdateDeferralDelay)
            guard let self,
                  self[keyPath: idKeyPath] == actionID,
                  !Task.isCancelled else {
                return
            }

            self[keyPath: idKeyPath] = nil
            self[keyPath: taskKeyPath] = nil
            perform(self)
        }
    }

    private func startScanNow(_ target: ScanTarget) {
        cancelArchiveOperation()
        let options = scanOptions(for: target)
        previousScanComparisonBaseline = nil
        pendingScanComparisonBaseline = comparisonBaseline(
            for: target,
            options: options,
            currentSnapshot: scanCoordinator.snapshot
        )
        sidebarScanCacheController.prepareForScanStart(target: target, options: options)
        scanCoordinator.startScan(
            target,
            options: options,
            baseline: pendingScanComparisonBaseline
        ) {
            prepareForScan(target)
        }
    }

    private func comparisonBaseline(
        for target: ScanTarget,
        options: ScanOptions,
        currentSnapshot: ScanSnapshot?
    ) -> ScanSnapshot? {
        guard let currentSnapshot,
              currentSnapshot.isComplete,
              currentSnapshot.source.allowsFileMutation,
              currentSnapshot.target.kind == target.kind,
              Self.normalizedTargetPath(currentSnapshot.target) == Self.normalizedTargetPath(target),
              currentSnapshot.scanOptions == options else {
            return nil
        }
        return currentSnapshot
    }

    private func retainComparisonBaseline(for completedSnapshot: ScanSnapshot) {
        defer { pendingScanComparisonBaseline = nil }
        guard let pendingScanComparisonBaseline,
              Self.canUseAsComparisonBaseline(pendingScanComparisonBaseline, for: completedSnapshot) else {
            previousScanComparisonBaseline = nil
            return
        }

        previousScanComparisonBaseline = pendingScanComparisonBaseline
    }

    nonisolated private static func canUseAsComparisonBaseline(
        _ previousSnapshot: ScanSnapshot,
        for currentSnapshot: ScanSnapshot
    ) -> Bool {
        guard previousSnapshot.id != currentSnapshot.id,
              previousSnapshot.isComplete,
              currentSnapshot.isComplete,
              previousSnapshot.source.allowsFileMutation,
              currentSnapshot.source.allowsFileMutation,
              previousSnapshot.target.kind == currentSnapshot.target.kind,
              normalizedTargetPath(previousSnapshot.target) == normalizedTargetPath(currentSnapshot.target),
              let previousOptions = previousSnapshot.scanOptions,
              let currentOptions = currentSnapshot.scanOptions,
              previousOptions == currentOptions else {
            return false
        }

        let previousDate = previousSnapshot.finishedAt ?? previousSnapshot.startedAt
        let currentDate = currentSnapshot.finishedAt ?? currentSnapshot.startedAt
        guard previousDate <= currentDate else { return false }

        if let previousRootIdentity = previousSnapshot.root.fileIdentity,
           let currentRootIdentity = currentSnapshot.root.fileIdentity,
           previousRootIdentity != currentRootIdentity {
            return false
        }
        return true
    }

    nonisolated private static func normalizedTargetPath(_ target: ScanTarget) -> String {
        URL(filePath: target.url.path, directoryHint: .isDirectory)
            .standardizedFileURL
            .path
    }

    func rescan() {
        guard let selectedTarget = scanCoordinator.selectedTarget else { return }
        startScan(selectedTarget)
    }

    func sunburstFreeSpaceAvailableCapacity(for snapshot: ScanSnapshot, focusNode: FileNodeRecord) -> Int64? {
        guard showFreeSpaceInSunburst,
              snapshot.target.kind == .volume,
              focusNode.id == snapshot.root.id else {
            return nil
        }

        return dependencies.systemActions.volumeAvailableCapacityForImportantUsage(snapshot.target.url)
    }

    func stopScan(resetState: Bool = true) {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        clearOptimisticTrashVisibility()
        pendingScanComparisonBaseline = nil
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()
        sidebarScanCacheController.clearActiveScanTracking()
        if resetState, scanCoordinator.snapshot == nil {
            sidebarModel.setActiveTargetID(nil)
            sidebarScanCacheController.clearDisplayedSnapshot()
        }
        scanCoordinator.stopScan(resetState: resetState)
    }

    func select(nodeID: String?) {
        cancelDeferredNavigationAction()
        performNavigationAction(.select(nodeID))
    }

    func select(nodeIDs: Set<String>, primaryNodeID: String?) {
        cancelDeferredNavigationAction()
        performNavigationAction(.selectMultiple(nodeIDs, primary: primaryNodeID))
    }

    func selectAfterViewUpdate(nodeID: String?) {
        scheduleDeferredNavigationAction(.select(nodeID))
    }

    func selectAfterViewUpdate(nodeIDs: Set<String>, primaryNodeID: String?) {
        scheduleDeferredNavigationAction(.selectMultiple(nodeIDs, primary: primaryNodeID))
    }

    func focus(nodeID: String?) {
        cancelDeferredNavigationAction()
        performNavigationAction(.focus(nodeID))
    }

    func focusAfterViewUpdate(nodeID: String?) {
        scheduleDeferredNavigationAction(.focus(nodeID))
    }

    func selectAndFocusAfterViewUpdate(nodeID: String) {
        scheduleDeferredNavigationAction(.selectAndFocus(nodeID))
    }

    func revealAfterViewUpdate(nodeID: String) {
        scheduleDeferredNavigationAction(.reveal(nodeID))
    }

    func clearSelection() {
        cancelDeferredNavigationAction()
        performNavigationAction(.clearSelection)
    }

    func setWorkspaceWindowNumber(_ windowNumber: Int?) {
        quickLookController.setWorkspaceWindowNumber(windowNumber)
    }

    func zoomIntoSelection() {
        do {
            let node = try validatedSelection(requiresDirectory: true, requiresLivePath: false)
            guard navigationModel.canZoomIntoSelection else {
                if shouldPresentPackageContentsHint(for: node) {
                    throw FileActionError.packageContentsHidden(settingEnabled: treatPackagesAsDirectories)
                }
                throw FileActionError.directoryRequired
            }
            focus(nodeID: node.id)
        } catch {
            presentError(error)
        }
    }

    func navigateBack() {
        cancelDeferredNavigationAction()
        performNavigationAction(.navigateBack)
    }

    func navigateForward() {
        cancelDeferredNavigationAction()
        performNavigationAction(.navigateForward)
    }

    func navigateToParent() {
        cancelDeferredNavigationAction()
        performNavigationAction(.navigateToParent)
    }

    func resetFocusToRoot() {
        cancelDeferredNavigationAction()
        performNavigationAction(.resetFocusToRoot)
    }

    private func scheduleDeferredNavigationAction(_ action: NavigationAction) {
        cancelDeferredNavigationAction()

        scheduleDeferredViewUpdate(
            id: \.deferredNavigationActionID,
            task: \.deferredNavigationActionTask
        ) { model in
            model.performNavigationAction(action)
        }
    }

    private func performNavigationAction(_ action: NavigationAction) {
        switch action {
        case .select(let nodeID):
            guard let nodeID else {
                navigationModel.select(nodeID: nil)
                return
            }
            guard isVisibleNavigationNode(nodeID) else { return }
            navigationModel.select(nodeID: nodeID)
        case .selectMultiple(let nodeIDs, let primary):
            let visibleNodeIDs = visibleNavigationNodeIDs(from: nodeIDs)
            guard !visibleNodeIDs.isEmpty || nodeIDs.isEmpty else { return }
            let visiblePrimary = primary.flatMap { visibleNodeIDs.contains($0) ? $0 : nil }
            navigationModel.select(nodeIDs: visibleNodeIDs, primaryNodeID: visiblePrimary)
        case .focus(let nodeID):
            guard let nodeID else {
                navigationModel.focus(nodeID: nil)
                return
            }
            guard isVisibleNavigationNode(nodeID) else { return }
            navigationModel.focus(nodeID: nodeID)
        case .selectAndFocus(let nodeID):
            guard isVisibleNavigationNode(nodeID) else { return }
            navigationModel.selectAndFocus(nodeID: nodeID)
        case .reveal(let nodeID):
            guard isVisibleNavigationNode(nodeID) else { return }
            navigationModel.reveal(nodeID: nodeID)
        case .navigateBack:
            navigationModel.navigateBack()
        case .navigateForward:
            navigationModel.navigateForward()
        case .navigateToParent:
            navigationModel.navigateToParent()
        case .resetFocusToRoot:
            navigationModel.resetFocusToRoot()
        case .clearSelection:
            navigationModel.clearSelection()
        }
    }

    private func visibleNavigationNodeIDs(from nodeIDs: Set<FileNodeRecord.ID>) -> Set<FileNodeRecord.ID> {
        guard let snapshotID = scanCoordinator.snapshot?.id,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            return nodeIDs
        }

        let hiddenIDs = hiddenNodeIDs(for: snapshotID)
        guard !hiddenIDs.isEmpty else { return nodeIDs }
        return nodeIDs.filter { !fileTreeStore.isNodeOrDescendant($0, of: hiddenIDs) }
    }

    private func isVisibleNavigationNode(_ nodeID: FileNodeRecord.ID) -> Bool {
        visibleNavigationNodeIDs(from: [nodeID]).contains(nodeID)
    }

    func selectSidebarTarget(id: String?) {
        cancelDeferredSidebarSelection()
        selectSidebarTargetNow(id: id)
    }

    func selectSidebarTargetAfterViewUpdate(id: String?) {
        cancelDeferredSidebarSelection()

        scheduleDeferredViewUpdate(
            id: \.deferredSidebarSelectionID,
            task: \.deferredSidebarSelectionTask
        ) { model in
            model.selectSidebarTargetNow(id: id)
        }
    }

    private func selectSidebarTargetNow(id: String?) {
        guard let id,
              let target = sidebarTarget(id: id) else {
            return
        }

        if scanCoordinator.selectedTarget?.id != target.id {
            cancelPostTrashSnapshotRemoval()
        }
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()
        sidebarModel.setActiveTargetID(target.id)
        guard applyCachedOrContainedSidebarTarget(target) else { return }
        startScan(target)
    }

    @discardableResult
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        guard isDirectoryURL(first) else {
            presentError(FileActionError.folderRequiredForDrop)
            return false
        }
        startScan(ScanTarget(url: first))
        return true
    }

    func revealSelectedInFinder() {
        do {
            let nodes = try validatedSelectedNodes(requiresLivePath: true)
            if let node = nodes.first, nodes.count == 1 {
                dependencies.systemActions.reveal(node.url)
            } else {
                dependencies.systemActions.revealMany(nodes.map(\.url))
            }
        } catch {
            presentError(error)
        }
    }

    func revealPrimarySelectionInFinder() {
        do {
            let node = try validatedSelection(requiresLivePath: true)
            dependencies.systemActions.reveal(node.url)
        } catch {
            presentError(error)
        }
    }

    func revealNodesInFinder(_ nodes: [FileNodeRecord]) {
        do {
            let nodes = try validatedNodes(nodes, requiresLivePath: true)
            if let node = nodes.first, nodes.count == 1 {
                dependencies.systemActions.reveal(node.url)
            } else {
                dependencies.systemActions.revealMany(nodes.map(\.url))
            }
        } catch {
            presentError(error)
        }
    }

    func revealTargetInFinder(_ target: ScanTarget) {
        dependencies.systemActions.reveal(target.url)
    }

    func openSelected() {
        do {
            let node = try validatedSelection(requiresLivePath: true)
            try dependencies.systemActions.open(node.url)
        } catch {
            presentError(error)
        }
    }

    func previewSelectedWithQuickLook() {
        quickLookController.previewSelected()
    }

    func toggleQuickLookForSelected() {
        quickLookController.toggleSelected()
    }

    func copySelectedPath() {
        do {
            let nodes = try validatedSelectedNodesForPathCopy()
            if let node = nodes.first, nodes.count == 1 {
                try dependencies.systemActions.copyPath(node.url)
            } else {
                try dependencies.systemActions.copyPaths(nodes.map(\.url))
            }
        } catch {
            presentError(error)
        }
    }

    func copyPrimarySelectionPath() {
        do {
            let node = try validatedSelectionForPathCopy()
            try dependencies.systemActions.copyPath(node.url)
        } catch {
            presentError(error)
        }
    }

    func copyPaths(for nodes: [FileNodeRecord]) {
        do {
            let nodes = try validatedNodesForPathCopy(nodes)
            if let node = nodes.first, nodes.count == 1 {
                try dependencies.systemActions.copyPath(node.url)
            } else {
                try dependencies.systemActions.copyPaths(nodes.map(\.url))
            }
        } catch {
            presentError(error)
        }
    }

    func requestMoveSelectedToTrash() {
        do {
            try requestTrashMove(for: validatedSelectedNodesForMutation())
        } catch {
            presentError(error)
        }
    }

    func requestMovePrimarySelectionToTrash() {
        do {
            let node = try validatedSelectionForMutation()
            guard node.supportsMoveToTrash(
                activeTarget: scanCoordinator.selectedTarget,
                trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
            ) else {
                throw FileActionError.unsupported
            }

            pendingTrashNode = node
            pendingTrashSelection = PendingTrashSelection(nodes: [node])
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func requestMoveNodesToTrash(_ nodes: [FileNodeRecord]) -> Bool {
        requestMoveNodesToTrash(nodes, allowingHiddenNodes: false)
    }

    @discardableResult
    private func requestMoveNodesToTrash(
        _ nodes: [FileNodeRecord],
        allowingHiddenNodes: Bool
    ) -> Bool {
        do {
            let nodes = try validatedNodesForMutation(
                nodes,
                allowingHiddenNodes: allowingHiddenNodes
            )
            try requestTrashMove(
                for: nodes,
                allowingHiddenNodes: allowingHiddenNodes
            )
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func requestTrashMove(
        for nodes: [FileNodeRecord],
        allowingHiddenNodes: Bool = false
    ) throws {
        guard nodes.allSatisfy({ node in
            node.supportsMoveToTrash(
                activeTarget: scanCoordinator.selectedTarget,
                trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
            )
        }) else {
            throw FileActionError.unsupported
        }

        let trashNodes = topLevelTrashNodes(from: nodes)
        pendingTrashNode = trashNodes.first
        pendingTrashSelection = PendingTrashSelection(
            nodes: trashNodes,
            allowsHiddenNodes: allowingHiddenNodes
        )
    }

    @discardableResult
    func addSelectedNodesToDiscardPile() -> Bool {
        addNodesToDiscardPile(navigationModel.selectedNodes)
    }

    @discardableResult
    func addPrimarySelectionToDiscardPile() -> Bool {
        guard let node = navigationModel.selectedNode else {
            presentError(FileActionError.noSelection)
            return false
        }

        return addNodesToDiscardPile([node])
    }

    func addPrimarySelectionToDiscardPileAfterViewUpdate() {
        guard let node = navigationModel.selectedNode else {
            presentError(FileActionError.noSelection)
            return
        }

        scheduleDeferredDiscardPileAdd([node])
    }

    @discardableResult
    func addNodeToDiscardPile(_ node: FileNodeRecord) -> Bool {
        addNodesToDiscardPile([node])
    }

    @discardableResult
    func addNodeIDsToDiscardPile(
        _ nodeIDs: [FileNodeRecord.ID],
        snapshotID: UUID
    ) -> Bool {
        guard scanCoordinator.snapshot?.id == snapshotID else {
            presentError(FileActionError.unsupported)
            return false
        }
        guard let fileTreeStore = scanCoordinator.fileTreeStore else {
            presentError(FileActionError.unsupported)
            return false
        }

        guard !nodeIDs.isEmpty else {
            presentError(FileActionError.unsupported)
            return false
        }

        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(nodeIDs.count)
        for nodeID in nodeIDs {
            guard let node = fileTreeStore.node(id: nodeID) else {
                presentError(FileActionError.unsupported)
                return false
            }
            nodes.append(node)
        }

        return addNodesToDiscardPile(nodes)
    }

    @discardableResult
    func addNodesToDiscardPile(_ nodes: [FileNodeRecord]) -> Bool {
        do {
            let nodes = try validatedNodesForDiscardPile(nodes)
            guard nodes.allSatisfy({ node in
                node.supportsMoveToTrash(
                    activeTarget: scanCoordinator.selectedTarget,
                    trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
                )
            }) else {
                throw FileActionError.unsupported
            }
            guard let snapshot = scanCoordinator.snapshot,
                  let fileTreeStore = scanCoordinator.fileTreeStore else {
                throw FileActionError.unsupported
            }

            addDiscardPileNodes(
                topLevelTrashNodes(from: nodes),
                snapshot: snapshot,
                fileTreeStore: fileTreeStore
            )
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func scheduleDeferredDiscardPileAdd(_ nodes: [FileNodeRecord]) {
        cancelDeferredDiscardPileAdd()

        scheduleDeferredViewUpdate(
            id: \.deferredDiscardPileAddID,
            task: \.deferredDiscardPileAddTask
        ) { model in
            model.addNodesToDiscardPile(nodes)
        }
    }

    func removeDiscardPileNode(id nodeID: FileNodeRecord.ID) {
        guard discardPile.nodeIDs.contains(nodeID) else { return }
        let remainingIDs = discardPile.nodeIDs.filter { $0 != nodeID }
        discardPile = DiscardPileState(
            nodeIDs: remainingIDs,
            snapshotID: discardPile.snapshotID
        )
    }

    func clearDiscardPile() {
        guard !discardPile.isEmpty else { return }
        discardPile = DiscardPileState()
    }

    @discardableResult
    func requestMoveDiscardPileToTrash() -> Bool {
        reconcileDiscardPile()
        return requestMoveNodesToTrash(
            topLevelTrashNodes(from: resolvedDiscardPileNodes()),
            allowingHiddenNodes: true
        )
    }

    func confirmMovePendingNodeToTrash() {
        confirmMovePendingSelectionToTrash()
    }

    func confirmMovePendingSelectionToTrash() {
        let allowsHiddenNodes = pendingTrashSelection?.allowsHiddenNodes == true
        let nodes = pendingTrashSelection?.nodes ?? pendingTrashNode.map { [$0] }
        guard let nodes, !nodes.isEmpty else { return }
        pendingTrashNode = nil
        self.pendingTrashSelection = nil

        if !allowsHiddenNodes {
            do {
                try validateMutationDoesNotIncludeHiddenNodes(nodes)
            } catch {
                presentError(error)
                return
            }
        }

        let originalSnapshotID = scanCoordinator.snapshot?.id
        let statsFileTreeStore = scanCoordinator.fileTreeStore

        if usesAsyncTrashActions {
            Task { @MainActor [weak self] in
                await self?.performConfirmedTrashMove(
                    nodes,
                    originalSnapshotID: originalSnapshotID,
                    statsFileTreeStore: statsFileTreeStore
                )
            }
        } else {
            performConfirmedTrashMoveSynchronously(
                nodes,
                originalSnapshotID: originalSnapshotID,
                statsFileTreeStore: statsFileTreeStore
            )
        }
    }

    private var usesAsyncTrashActions: Bool {
        dependencies.systemActions.asyncMoveToTrash != nil ||
            dependencies.systemActions.asyncVerifyTrashIdentity != nil
    }

    private func performConfirmedTrashMoveSynchronously(
        _ nodes: [FileNodeRecord],
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?
    ) {
        var movedNodes: [FileNodeRecord] = []

        if let actionError = trashIdentityError(for: nodes) {
            presentError(actionError)
            return
        }

        hideTrashNodesDuringMove(nodes, snapshotID: originalSnapshotID)

        var actionError: Error?
        for node in nodes {
            do {
                try dependencies.systemActions.moveToTrash(node.url)
                movedNodes.append(node)
            } catch {
                actionError = error
                break
            }
        }

        finishConfirmedTrashMove(
            requestedNodes: nodes,
            movedNodes,
            actionError: actionError,
            originalSnapshotID: originalSnapshotID,
            statsFileTreeStore: statsFileTreeStore
        )
    }

    private func performConfirmedTrashMove(
        _ nodes: [FileNodeRecord],
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?
    ) async {
        var movedNodes: [FileNodeRecord] = []

        if let actionError = await asyncTrashIdentityError(for: nodes) {
            presentError(actionError)
            return
        }

        hideTrashNodesDuringMove(nodes, snapshotID: originalSnapshotID)

        var actionError: Error?
        for node in nodes {
            do {
                try await moveToTrash(node.url)
                movedNodes.append(node)
            } catch {
                actionError = error
                break
            }
        }

        finishConfirmedTrashMove(
            requestedNodes: nodes,
            movedNodes,
            actionError: actionError,
            originalSnapshotID: originalSnapshotID,
            statsFileTreeStore: statsFileTreeStore
        )
    }

    private func trashIdentityError(for nodes: [FileNodeRecord]) -> Error? {
        for node in nodes {
            if let error = fileActionError(
                for: dependencies.systemActions.verifyTrashIdentity(node),
                node: node
            ) {
                return error
            }
        }
        return nil
    }

    private func asyncTrashIdentityError(for nodes: [FileNodeRecord]) async -> Error? {
        for node in nodes {
            let result: TrashIdentityVerificationResult
            if let asyncVerifyTrashIdentity = dependencies.systemActions.asyncVerifyTrashIdentity {
                result = await asyncVerifyTrashIdentity(node)
            } else {
                result = dependencies.systemActions.verifyTrashIdentity(node)
            }

            if let error = fileActionError(for: result, node: node) {
                return error
            }
        }
        return nil
    }

    private func fileActionError(
        for result: TrashIdentityVerificationResult,
        node: FileNodeRecord
    ) -> Error? {
        switch result {
        case .matches:
            return nil
        case .missingCurrentItem:
            return FileActionError.unavailable(path: node.url.path)
        case .missingScannedIdentity:
            return FileActionError.missingScannedIdentity(path: node.url.path)
        case .mismatch:
            return FileActionError.changedSinceScan(path: node.url.path)
        case .metadataUnavailable(let reason):
            return FileActionError.currentIdentityUnavailable(path: node.url.path, reason: reason)
        }
    }

    private func moveToTrash(_ url: URL) async throws {
        if let asyncMoveToTrash = dependencies.systemActions.asyncMoveToTrash {
            try await asyncMoveToTrash(url)
        } else {
            try dependencies.systemActions.moveToTrash(url)
        }
    }

    private func finishConfirmedTrashMove(
        requestedNodes: [FileNodeRecord],
        _ movedNodes: [FileNodeRecord],
        actionError: Error?,
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?
    ) {
        if !movedNodes.isEmpty {
            if discardPile.snapshotID == originalSnapshotID {
                removeMovedNodesFromDiscardPile(movedNodes, fileTreeStore: statsFileTreeStore)
            }
            recordTrashMove(movedNodes, fileTreeStore: statsFileTreeStore)
            sidebarScanCacheController.clearCache()
            if shouldApplyPostTrashSnapshotUpdate(originalSnapshotID: originalSnapshotID) {
                handleMovedToTrash(movedNodes)
            }
            refreshAvailableTargets()
        }

        if let actionError {
            unhideTrashNodesAfterFailedMove(
                requestedNodes: requestedNodes,
                movedNodes: movedNodes,
                snapshotID: originalSnapshotID
            )
            presentError(actionError)
        }
    }

    private func shouldApplyPostTrashSnapshotUpdate(originalSnapshotID: UUID?) -> Bool {
        guard let originalSnapshotID else { return true }
        return scanCoordinator.snapshot?.id == originalSnapshotID
    }

    private func handleMovedToTrash(_ nodes: [FileNodeRecord]) {
        var shouldClearActiveScan = false

        for node in nodes {
            switch ScanPostTrashAction.afterRemovingNode(activeTargetID: scanCoordinator.selectedTarget?.id, removedNodeID: node.id) {
            case .clearActiveScan:
                shouldClearActiveScan = true
            case .removeFromActiveScan:
                enqueuePostTrashSnapshotRemoval(
                    nodeID: node.id,
                    fallbackFocusID: postTrashFocusFallbackID(for: node)
                )
            case .none:
                break
            }
        }

        if shouldClearActiveScan {
            cancelPostTrashSnapshotRemoval()
            scanCoordinator.clearScan()
            navigationModel.reset()
            sidebarModel.setActiveTargetID(nil)
            sidebarScanCacheController.clearDisplayedSnapshot()
        }
    }

    func cancelPendingTrash() {
        pendingTrashNode = nil
        pendingTrashSelection = nil
    }

    func reconcileDiscardPile() {
        guard !discardPile.isEmpty else { return }
        guard let snapshot = scanCoordinator.snapshot,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            discardPile = DiscardPileState()
            return
        }
        guard discardPile.snapshotID == snapshot.id else {
            discardPile = DiscardPileState()
            return
        }

        reconcileDiscardPile(snapshotID: snapshot.id, fileTreeStore: fileTreeStore)
    }

    private func postTrashFocusFallbackID(for node: FileNodeRecord) -> FileNodeRecord.ID? {
        guard let treeStore = scanCoordinator.fileTreeStore,
              treeStore.isAncestor(node.id, of: navigationModel.focusedNodeID) else {
            return nil
        }

        return treeStore.parent(of: node.id)?.id ?? treeStore.root.id
    }

    private func enqueuePostTrashSnapshotRemoval(
        nodeID: FileNodeRecord.ID,
        fallbackFocusID: FileNodeRecord.ID?
    ) {
        postTrashRemovalRequests.append(PostTrashRemovalRequest(
            nodeID: nodeID,
            fallbackFocusID: fallbackFocusID
        ))
        startPostTrashSnapshotRemovalIfNeeded()
    }

    private func startPostTrashSnapshotRemovalIfNeeded() {
        guard postTrashRemovalTask == nil else { return }

        postTrashRemovalTask = Task { @MainActor [weak self] in
            while let self, !self.postTrashRemovalRequests.isEmpty {
                if Task.isCancelled {
                    self.postTrashRemovalRequests.removeAll()
                    self.postTrashRemovalTask = nil
                    return
                }

                let request = self.postTrashRemovalRequests.removeFirst()
                let didRemove = await self.scanCoordinator.removeNodeFromCurrentSnapshot(id: request.nodeID)
                guard !Task.isCancelled else {
                    self.postTrashRemovalRequests.removeAll()
                    self.postTrashRemovalTask = nil
                    return
                }

                if didRemove,
                   let fallbackFocusID = request.fallbackFocusID,
                   self.scanCoordinator.fileTreeStore?.node(id: fallbackFocusID) != nil {
                    self.navigationModel.setFocusedNodeID(fallbackFocusID)
                }
                self.navigationModel.reconcileAfterSnapshotApplied(self.scanCoordinator.snapshot)
            }

            self?.postTrashRemovalTask = nil
        }
    }

    func prepareAndOpenFullDiskAccessSettings() {
        guard dependencies.systemActions.prepareAndOpenFullDiskAccessSettings() else {
            presentError(FileActionError.fullDiskAccessSettingsUnavailable)
            return
        }
    }

    func prepareAndOpenFullDiskAccessSettingsFromOnboarding() {
        guard dependencies.systemActions.prepareAndOpenFullDiskAccessSettings() else {
            presentError(FileActionError.fullDiskAccessSettingsUnavailable)
            return
        }

        dependencies.preferences.markOnboardingIncomplete()
    }

    private func presentError(_ error: Error, title: String? = nil) {
        if let title {
            lastActionErrorTitle = title
        } else if let fileActionError = error as? FileActionError {
            lastActionErrorTitle = fileActionError.alertTitle
        } else {
            lastActionErrorTitle = nil
        }
        lastErrorMessage = error.localizedDescription
    }

    private func presentErrorMessage(_ message: String) {
        lastActionErrorTitle = nil
        lastErrorMessage = message
    }

    private func shouldPresentPackageContentsHint(for node: FileNodeRecord) -> Bool {
        node.isPackage && (node.descendantFileCount > 0 || node.allocatedSize > 0 || node.logicalSize > 0)
    }

    private func validatedSelection(requiresDirectory: Bool = false) throws -> FileNodeRecord {
        try validatedSelection(requiresDirectory: requiresDirectory, requiresLivePath: true)
    }

    private func validatedSelection(
        requiresDirectory: Bool = false,
        requiresLivePath: Bool
    ) throws -> FileNodeRecord {
        guard let selectedNode = navigationModel.selectedNode else {
            throw FileActionError.noSelection
        }
        guard isVisibleNavigationNode(selectedNode.id) else {
            clearSelection()
            throw FileActionError.noSelection
        }
        guard selectedNode.supportsFileActions else {
            throw FileActionError.unsupported
        }
        if requiresDirectory, !selectedNode.isDirectory {
            throw FileActionError.directoryRequired
        }
        if requiresLivePath {
            try validateLivePathAction(selectedNode)
        }
        return selectedNode
    }

    private func validatedSelectedNodes(requiresLivePath: Bool) throws -> [FileNodeRecord] {
        let visibleNodes = navigationModel.selectedNodes.filter { isVisibleNavigationNode($0.id) }
        if visibleNodes.isEmpty, !navigationModel.selectedNodes.isEmpty {
            clearSelection()
        }
        return try validatedNodes(visibleNodes, requiresLivePath: requiresLivePath)
    }

    private func validatedNodes(
        _ nodes: [FileNodeRecord],
        requiresLivePath: Bool
    ) throws -> [FileNodeRecord] {
        guard !nodes.isEmpty else {
            throw FileActionError.noSelection
        }

        for node in nodes {
            guard node.supportsFileActions else {
                throw FileActionError.unsupported
            }
            if requiresLivePath {
                try validateLivePathAction(node)
            }
        }

        return nodes
    }

    private func validatedSelectionForPathCopy() throws -> FileNodeRecord {
        try validatePathCopyAllowed()
        return try validatedSelection(requiresLivePath: false)
    }

    private func validatedSelectedNodesForPathCopy() throws -> [FileNodeRecord] {
        try validatePathCopyAllowed()
        return try validatedSelectedNodes(requiresLivePath: false)
    }

    private func validatedNodesForPathCopy(_ nodes: [FileNodeRecord]) throws -> [FileNodeRecord] {
        try validatePathCopyAllowed()
        return try validatedNodes(nodes, requiresLivePath: false)
    }

    private func validatedSelectionForMutation() throws -> FileNodeRecord {
        try validateSnapshotAllowsMutation()
        let node = try validatedSelection(requiresLivePath: true)
        try validateMutationDoesNotIncludeHiddenNodes([node])
        return node
    }

    private func validatedNodesForMutation(
        _ nodes: [FileNodeRecord],
        allowingHiddenNodes: Bool = false
    ) throws -> [FileNodeRecord] {
        try validateSnapshotAllowsMutation()
        let nodes = try validatedNodes(nodes, requiresLivePath: true)
        if !allowingHiddenNodes {
            try validateMutationDoesNotIncludeHiddenNodes(nodes)
        }
        return nodes
    }

    private func validatedSelectedNodesForMutation() throws -> [FileNodeRecord] {
        try validateSnapshotAllowsMutation()
        let nodes = try validatedSelectedNodes(requiresLivePath: true)
        try validateMutationDoesNotIncludeHiddenNodes(nodes)
        return nodes
    }

    private func validatedNodesForDiscardPile(_ nodes: [FileNodeRecord]) throws -> [FileNodeRecord] {
        try validateSnapshotAllowsMutation()
        return try validatedNodes(nodes, requiresLivePath: false)
    }

    private func validateLivePathAction(_ node: FileNodeRecord) throws {
        guard scanCoordinator.snapshotSource.allowsLivePathActions else {
            throw FileActionError.unsupported
        }
        guard dependencies.systemActions.fileExists(node.url) else {
            clearSelection()
            throw FileActionError.unavailable(path: node.url.path)
        }
        try validateImportedIdentityIfAvailable(node)
    }

    private func validateImportedIdentityIfAvailable(_ node: FileNodeRecord) throws {
        guard scanCoordinator.snapshotSource.isImported,
              node.fileIdentity != nil else {
            return
        }

        switch dependencies.systemActions.verifyTrashIdentity(node) {
        case .matches, .missingScannedIdentity:
            return
        case .missingCurrentItem:
            clearSelection()
            throw FileActionError.unavailable(path: node.url.path)
        case .mismatch:
            throw FileActionError.changedSinceScan(path: node.url.path)
        case .metadataUnavailable(let reason):
            throw FileActionError.currentIdentityUnavailable(path: node.url.path, reason: reason)
        }
    }

    private func validatePathCopyAllowed() throws {
        guard scanCoordinator.snapshotSource.allowsArchivedPathCopy else {
            throw FileActionError.unsupported
        }
    }

    private func validateSnapshotAllowsMutation() throws {
        guard scanCoordinator.snapshotSource.allowsFileMutation else {
            throw FileActionError.readOnlySnapshot
        }
    }

    private func validateMutationDoesNotIncludeHiddenNodes(_ nodes: [FileNodeRecord]) throws {
        guard let snapshotID = scanCoordinator.snapshot?.id,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            return
        }

        let hiddenIDs = hiddenNodeIDs(for: snapshotID)
        guard !hiddenIDs.isEmpty else { return }

        let requestedIDs = Set(nodes.map(\.id))
        let requestedNodeIsHidden = requestedIDs.contains(where: { requestedID in
            fileTreeStore.isNodeOrDescendant(requestedID, of: hiddenIDs)
        })
        let requestedNodeContainsHiddenNode = hiddenIDs.contains(where: { hiddenID in
            requestedIDs.contains(hiddenID) || fileTreeStore.hasAncestor(in: requestedIDs, of: hiddenID)
        })

        guard !requestedNodeIsHidden && !requestedNodeContainsHiddenNode else {
            throw FileActionError.unsupported
        }
    }

    private func topLevelTrashNodes(from nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        guard let fileTreeStore = scanCoordinator.fileTreeStore else { return nodes }
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fileTreeStore.topLevelNodeIDs(from: nodes.map(\.id)).compactMap { nodesByID[$0] }
    }

    private func hiddenNodeIDs(for snapshotID: UUID?) -> Set<FileNodeRecord.ID> {
        guard let snapshotID else { return [] }

        var nodeIDs = Set<FileNodeRecord.ID>()
        if discardPile.snapshotID == snapshotID {
            nodeIDs.formUnion(discardPile.nodeIDs)
        }
        if optimisticTrashVisibility.snapshotID == snapshotID {
            nodeIDs.formUnion(optimisticTrashVisibility.nodeIDs)
        }
        return nodeIDs
    }

    private func addDiscardPileNodes(
        _ nodes: [FileNodeRecord],
        snapshot: ScanSnapshot,
        fileTreeStore: FileTreeStore
    ) {
        guard !nodes.isEmpty else { return }

        let queuedIDs = (discardPile.snapshotID == snapshot.id ? discardPile.nodeIDs : []) + nodes.map(\.id)
        let deduplicatedIDs = deduplicatedDiscardPileIDs(queuedIDs, fileTreeStore: fileTreeStore)
        reconcileNavigationForDiscardPileHiddenNodes(
            hiddenNodeIDs: hiddenNodeIDs(for: snapshot.id).union(deduplicatedIDs),
            fileTreeStore: fileTreeStore
        )
        discardPile = DiscardPileState(nodeIDs: deduplicatedIDs, snapshotID: snapshot.id)
    }

    private func hideTrashNodesDuringMove(
        _ nodes: [FileNodeRecord],
        snapshotID: UUID?
    ) {
        guard let snapshotID,
              scanCoordinator.snapshot?.id == snapshotID,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            return
        }

        let nodeIDs = Set(fileTreeStore.topLevelNodeIDs(from: nodes.map(\.id)))
        guard !nodeIDs.isEmpty else { return }

        let existingIDs = optimisticTrashVisibility.snapshotID == snapshotID
            ? optimisticTrashVisibility.nodeIDs
            : []
        let hiddenIDs = existingIDs.union(nodeIDs)
        optimisticTrashVisibility = OptimisticTrashVisibilityState(
            nodeIDs: hiddenIDs,
            snapshotID: snapshotID
        )
        reconcileNavigationForDiscardPileHiddenNodes(
            hiddenNodeIDs: hiddenNodeIDs(for: snapshotID),
            fileTreeStore: fileTreeStore
        )
    }

    private func unhideTrashNodesAfterFailedMove(
        requestedNodes: [FileNodeRecord],
        movedNodes: [FileNodeRecord],
        snapshotID: UUID?
    ) {
        guard let snapshotID,
              optimisticTrashVisibility.snapshotID == snapshotID else {
            return
        }

        let movedNodeIDs = Set(movedNodes.map(\.id))
        let unmovedNodeIDs = Set(
            requestedNodes
                .map(\.id)
                .filter { !movedNodeIDs.contains($0) }
        )
        guard !unmovedNodeIDs.isEmpty else { return }

        let hiddenIDs = optimisticTrashVisibility.nodeIDs.subtracting(unmovedNodeIDs)
        optimisticTrashVisibility = OptimisticTrashVisibilityState(
            nodeIDs: hiddenIDs,
            snapshotID: snapshotID
        )
    }

    private func deduplicatedDiscardPileIDs(
        _ nodeIDs: [FileNodeRecord.ID],
        fileTreeStore: FileTreeStore
    ) -> [FileNodeRecord.ID] {
        fileTreeStore.topLevelNodeIDs(from: nodeIDs)
    }

    private func resolvedDiscardPileNodes() -> [FileNodeRecord] {
        guard let fileTreeStore = scanCoordinator.fileTreeStore else { return [] }
        return discardPile.nodeIDs.compactMap { fileTreeStore.node(id: $0) }
    }

    private func reconcileNavigationForDiscardPileHiddenNodes(
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore
    ) {
        guard !hiddenNodeIDs.isEmpty else { return }

        if let focusedNodeID = navigationModel.focusedNodeID,
           fileTreeStore.isNodeOrDescendant(focusedNodeID, of: hiddenNodeIDs) {
            navigationModel.setFocusedNodeID(
                discardPileFocusFallbackID(
                    for: focusedNodeID,
                    hiddenNodeIDs: hiddenNodeIDs,
                    fileTreeStore: fileTreeStore
                )
            )
        }

        if navigationModel.selectedNodeIDs.contains(where: { selectedNodeID in
            fileTreeStore.isNodeOrDescendant(selectedNodeID, of: hiddenNodeIDs)
        }) {
            navigationModel.clearSelection()
        }
    }

    private func discardPileFocusFallbackID(
        for nodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore
    ) -> FileNodeRecord.ID? {
        var parentID = fileTreeStore.parent(of: nodeID)?.id
        while let candidateID = parentID {
            if !fileTreeStore.isNodeOrDescendant(candidateID, of: hiddenNodeIDs) {
                return candidateID
            }
            parentID = fileTreeStore.parent(of: candidateID)?.id
        }
        return fileTreeStore.rootID
    }

    private func removeMovedNodesFromDiscardPile(
        _ movedNodes: [FileNodeRecord],
        fileTreeStore: FileTreeStore?
    ) {
        guard !discardPile.isEmpty, !movedNodes.isEmpty else { return }

        let movedIDs = Set(movedNodes.map(\.id))
        let remainingIDs = discardPile.nodeIDs.filter { queuedID in
            guard !movedIDs.contains(queuedID) else { return false }
            guard let fileTreeStore else { return true }
            return !fileTreeStore.isNodeOrDescendant(queuedID, of: movedIDs)
        }
        guard remainingIDs != discardPile.nodeIDs else { return }
        discardPile = DiscardPileState(
            nodeIDs: remainingIDs,
            snapshotID: discardPile.snapshotID
        )
    }

    private func syncDiscardPile(with snapshot: ScanSnapshot?) {
        guard !discardPile.isEmpty else { return }
        guard let snapshot else {
            discardPile = DiscardPileState()
            return
        }
        guard discardPile.snapshotID == snapshot.id else {
            discardPile = DiscardPileState()
            return
        }
        reconcileDiscardPile(snapshotID: snapshot.id, fileTreeStore: snapshot.treeStore)
    }

    private func syncOptimisticTrashVisibility(with snapshot: ScanSnapshot?) {
        guard optimisticTrashVisibility.snapshotID != nil else { return }
        guard let snapshot,
              optimisticTrashVisibility.snapshotID == snapshot.id else {
            optimisticTrashVisibility = OptimisticTrashVisibilityState()
            return
        }

        let nodeIDs = optimisticTrashVisibility.nodeIDs.filter { snapshot.treeStore.node(id: $0) != nil }
        guard nodeIDs != optimisticTrashVisibility.nodeIDs else { return }
        optimisticTrashVisibility = OptimisticTrashVisibilityState(
            nodeIDs: nodeIDs,
            snapshotID: snapshot.id
        )
    }

    private func reconcileDiscardPile(
        snapshotID: UUID,
        fileTreeStore: FileTreeStore
    ) {
        let reconciledIDs = deduplicatedDiscardPileIDs(
            discardPile.nodeIDs.filter { fileTreeStore.node(id: $0) != nil },
            fileTreeStore: fileTreeStore
        )
        guard reconciledIDs != discardPile.nodeIDs else { return }
        discardPile = DiscardPileState(
            nodeIDs: reconciledIDs,
            snapshotID: snapshotID
        )
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        dependencies.systemActions.isExistingDirectory(url)
    }

    private func prepareForScan(_ target: ScanTarget) {
        lastErrorMessage = nil
        scanComparison = nil
        navigationModel.reset()
        pendingComparisonSetup = nil
        pendingImportPreview = nil
        pendingTrashNode = nil
        pendingTrashSelection = nil
        discardPile = DiscardPileState()
        clearOptimisticTrashVisibility()
        sidebarModel.setActiveTargetID(target.id)

        registerRecentTarget(target)
        refreshAvailableTargets()
    }

    private func restoreImportedSnapshot(_ snapshot: ScanSnapshot) {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()
        sidebarScanCacheController.clearActiveScanTracking()
        sidebarScanCacheController.clearDisplayedSnapshot()
        previousScanComparisonBaseline = nil
        pendingScanComparisonBaseline = nil

        deferredNavigationContextSnapshotID = snapshot.id
        scanCoordinator.restoreCompletedSnapshot(snapshot) {
            prepareForImportedSnapshot()
        }
        navigationModel.updateScanContext(snapshot: snapshot, loadTableNodesImmediately: false)
        scheduleDeferredNavigationContextUpdate(for: snapshot.id)
    }

    private func prepareForImportedSnapshot() {
        lastErrorMessage = nil
        scanComparison = nil
        navigationModel.reset()
        pendingComparisonSetup = nil
        pendingImportPreview = nil
        pendingTrashNode = nil
        pendingTrashSelection = nil
        discardPile = DiscardPileState()
        clearOptimisticTrashVisibility()
        previousScanComparisonBaseline = nil
        pendingScanComparisonBaseline = nil
        sidebarModel.setActiveTargetID(nil)
        quickLookController.closePreview()
    }

    private func scanOptions(
        for target: ScanTarget,
        autoSummarizeDirectories: Bool? = nil,
        preferredExclusionRootPath: String? = nil
    ) -> ScanOptions {
        let exclusionPatterns = activeExclusionPatterns
        return ScanOptions(
            includeHiddenFiles: showHiddenFiles || target.kind == .volume,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            autoSummarizeDirectories: autoSummarizeDirectories ?? self.autoSummarizeDirectories,
            includeCloudStorage: scanCloudStorageFolders,
            exclusionPatterns: exclusionPatterns,
            exclusionRootPath: exclusionRootPath(
                for: target,
                patterns: exclusionPatterns,
                preferredRootPath: preferredExclusionRootPath
            )
        )
    }

    private var activeExclusionPatterns: [String] {
        guard useScanExclusions else { return [] }
        return ScanExclusionMatcher.normalizedPatterns(exclusionPatterns)
    }

    private var currentScanExclusionRootPath: String? {
        sidebarScanCacheController.currentScanExclusionRootPath(currentSnapshot: scanCoordinator.snapshot)
    }

    private func exclusionRootPath(
        for target: ScanTarget,
        patterns: [String],
        preferredRootPath: String?
    ) -> String? {
        guard !patterns.isEmpty,
              ScanExclusionMatcher.patternsRequirePathScopedRoot(patterns) else {
            return nil
        }

        return ScanExclusionMatcher.normalizedRootPath(preferredRootPath ?? target.url.path)
    }

    private func registerRecentTarget(_ target: ScanTarget) {
        recentTargets = dependencies.recentTargets.record(target, currentTargets: recentTargets)
    }

    private func refreshAvailableTargets() {
        targetCapacityDescriptionsRefreshTask?.cancel()
        scanCoordinator.replaceTrashSafetyPolicy(dependencies.systemActions.trashSafetyPolicy())
        availableTargets = dependencies.systemActions.defaultTargets()

        guard dependencies.systemActions.usesAsyncTargetCapacityDescriptions else {
            sidebarModel.replaceTargetCapacityDescriptions(
                dependencies.systemActions.currentTargetCapacityDescriptions()
            )
            targetCapacityDescriptionsRefreshTask = nil
            return
        }

        targetCapacityDescriptionsRefreshTask = Task { [weak self] in
            guard let self else { return }
            let descriptions = await self.dependencies.systemActions.loadCurrentTargetCapacityDescriptions()
            guard !Task.isCancelled else { return }
            self.sidebarModel.replaceTargetCapacityDescriptions(descriptions)
            self.targetCapacityDescriptionsRefreshTask = nil
        }
    }

    private func observeNavigationModel() {
        navigationModel.onSelectionChanged = { [weak self] in
            self?.quickLookController.syncVisiblePreview()
        }
    }

    private func observeScanCoordinator() {
        scanCoordinator.onScanFinished = { [weak self] snapshot in
            self?.recordCompletedScan(snapshot)
            self?.retainComparisonBaseline(for: snapshot)
        }

        scanCoordinator.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                syncOptimisticTrashVisibility(with: snapshot)
                syncDiscardPile(with: snapshot)
                if let snapshotID = snapshot?.id,
                   snapshotID == deferredNavigationContextSnapshotID {
                    return
                }

                cancelDeferredNavigationContextUpdate()
                navigationModel.updateScanContext(snapshot: snapshot)
            }
            .store(in: &cancellables)

        scanCoordinator.$completedScanSnapshot
            .compactMap { $0 }
            .sink { [weak self] snapshot in
                self?.sidebarScanCacheController.handleCompletedScanSnapshot(snapshot)
            }
            .store(in: &cancellables)

        scanCoordinator.$scanErrorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.presentErrorMessage(message)
            }
            .store(in: &cancellables)
    }

    private func recordCompletedScan(_ snapshot: ScanSnapshot) {
        updateUsageStats { stats in
            stats.recordCompletedScan(snapshot)
        }
    }

    private func recordTrashMove(_ nodes: [FileNodeRecord]) {
        recordTrashMove(nodes, fileTreeStore: scanCoordinator.fileTreeStore)
    }

    private func recordTrashMove(_ nodes: [FileNodeRecord], fileTreeStore: FileTreeStore?) {
        updateUsageStats { stats in
            stats.recordTrashMove(nodes: nodes, fileTreeStore: fileTreeStore)
        }
    }

    private func updateUsageStats(_ update: (inout AppUsageStats) -> Void) {
        var updatedStats = usageStats
        update(&updatedStats)
        guard updatedStats != usageStats else { return }
        usageStats = updatedStats
        dependencies.usageStats.saveUsageStats(updatedStats)
    }

    private func applyCachedOrContainedSidebarTarget(_ target: ScanTarget) -> Bool {
        let options = scanOptions(for: target)
        return sidebarScanCacheController.applyCachedOrContainedSidebarTarget(
            target,
            options: options,
            currentSnapshot: scanCoordinator.snapshot,
            isTargetActive: { [weak self] target in
                self?.sidebarModel.activeTargetID == target.id
            },
            cancelDeferredScanStart: { [weak self] in
                self?.cancelDeferredScanStart()
            },
            restoreSnapshot: { [weak self] snapshot, target in
                self?.restoreSidebarSnapshot(snapshot, target: target)
            },
            startScan: { [weak self] target in
                self?.startScan(target)
            }
        )
    }

    private func restoreSidebarSnapshot(_ snapshot: ScanSnapshot, target: ScanTarget) {
        scanCoordinator.restoreCompletedSnapshot(snapshot) {
            prepareForScan(target)
        }
    }

    private func sidebarTarget(id: String) -> ScanTarget? {
        sidebarModel.target(id: id)
    }

    private func observeMountedVolumes() {
        dependencies.systemActions.mountedVolumeEvents()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAvailableTargets()
            }
            .store(in: &cancellables)
    }

    private func observePreferences() {
        Publishers.CombineLatest4(
            $showHiddenFiles,
            $treatPackagesAsDirectories,
            $maxRenderedDepth,
            $scanCloudStorageFolders
        )
            .combineLatest(Publishers.CombineLatest4(
                $autoSummarizeDirectories,
                $showFreeSpaceInSunburst,
                $useScanExclusions,
                $exclusionPatterns
            ))
            .map { scanBasics, scanFilters in
                Self.scanPreferences(scanBasics, scanFilters)
            }
            .dropFirst()
            .removeDuplicates()
            .debounce(for: Self.scanPreferencePersistenceDebounce, scheduler: RunLoop.main)
            .sink { [weak self] preferences in
                self?.persistScanPreferences(preferences)
            }
            .store(in: &cancellables)
    }

    private var currentScanPreferences: AppScanPreferences {
        AppScanPreferences(
            showHiddenFiles: showHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            maxRenderedDepth: maxRenderedDepth,
            autoSummarizeDirectories: autoSummarizeDirectories,
            showFreeSpaceInSunburst: showFreeSpaceInSunburst,
            scanCloudStorageFolders: scanCloudStorageFolders,
            useScanExclusions: useScanExclusions,
            exclusionPatterns: exclusionPatterns
        )
    }

    private func flushPendingScanPreferences() {
        persistScanPreferences(currentScanPreferences)
    }

    private func persistScanPreferences(_ preferences: AppScanPreferences) {
        guard lastPersistedScanPreferences != preferences else { return }
        dependencies.preferences.saveScanPreferences(preferences)
        lastPersistedScanPreferences = preferences
    }

    private static func scanPreferences(
        _ scanBasics: (Bool, Bool, Int, Bool),
        _ scanFilters: (Bool, Bool, Bool, [String])
    ) -> AppScanPreferences {
        AppScanPreferences(
            showHiddenFiles: scanBasics.0,
            treatPackagesAsDirectories: scanBasics.1,
            maxRenderedDepth: scanBasics.2,
            autoSummarizeDirectories: scanFilters.0,
            showFreeSpaceInSunburst: scanFilters.1,
            scanCloudStorageFolders: scanBasics.3,
            useScanExclusions: scanFilters.2,
            exclusionPatterns: scanFilters.3
        )
    }

    private func defaultExportFileName(for snapshot: ScanSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dateText = formatter.string(from: snapshot.finishedAt ?? Date())
        let targetName = sanitizedFileName(snapshot.target.displayName)
        return "\(targetName) \(dateText)"
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = name.components(separatedBy: invalidCharacters)
        let sanitizedName = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitizedName.isEmpty ? "Radix Scan" : sanitizedName
    }

    private static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

extension AppModel: AppQuickLookControllerDelegate {
    var quickLookSelectionContext: AppQuickLookSelectionContext {
        AppQuickLookSelectionContext(
            selectedNode: navigationModel.selectedNode,
            activeTarget: scanCoordinator.selectedTarget,
            trashSafetyPolicy: scanCoordinator.trashSafetyPolicy,
            snapshotSource: scanCoordinator.snapshotSource
        )
    }

    var isQuickLookKeyboardShortcutBlocked: Bool {
        showsOnboarding ||
            !canUseWorkspaceCommands ||
            pendingTrashNode != nil ||
            pendingTrashSelection != nil ||
            navigationModel.selectedNodeIDs.count > 1
    }

    func validatedSelectionForQuickLook() throws -> FileNodeRecord {
        try validatedSelection(requiresLivePath: true)
    }

    func appQuickLookController(_ controller: AppQuickLookController, didFailWith error: Error) {
        presentError(error)
    }
}
