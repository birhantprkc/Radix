import SwiftUI

struct ActiveWorkspaceView: View {
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let visualizationMode: ScanVisualizationMode
    let maxRenderedDepth: Int
    let showFreeSpaceInDiskMaps: Bool
    let discardPileHiddenNodeIDs: Set<FileNodeRecord.ID>
    let fullDiskAccessStatus: FullDiskAccessStatus
    let freeSpaceAvailableCapacity: (ScanSnapshot, FileNodeRecord) -> Int64?
    let actions: WorkspaceActions

    // Dismissal is scoped to a single target scan: transformed snapshots keep it hidden.
    @State private var dismissedWarningsScanScope: WarningDismissalScope?
    @StateObject private var visualizationFilter = DiskMapVisualizationFilterModel()

    private var shouldSuggestFullDiskAccess: Bool {
        PermissionAdvisor.shouldSuggestFullDiskAccess(
            for: snapshot,
            fullDiskAccessStatus: fullDiskAccessStatus
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(
                navigation: navigation,
                snapshot: snapshot,
                focusNode: focusNode,
                actions: actions
            )

            Divider()

            resizableWorkspacePanes
        }
    }

    private var resizableWorkspacePanes: some View {
        WorkspaceSplitView(topMinHeight: 260, bottomMinHeight: 200) {
            visualizationPane
        } bottom: {
            contentsPane
        }
    }

    private var visualizationPane: some View {
        chartContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var chartContent: some View {
        let baseVisualizationInput = diskMapVisualizationInput
        let filterRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseVisualizationInput,
            snapshotID: snapshot.id,
            focusNodeID: focusNode.id,
            hiddenNodeIDs: discardPileHiddenNodeIDs
        )
        let visualizationInput = visualizationFilter.input(
            baseInput: baseVisualizationInput,
            request: filterRequest
        )
        let isVisualizationInputPending = visualizationFilter.isFiltering
            || visualizationFilter.isInputPending(for: filterRequest)

        let layoutID = [
            snapshot.id.uuidString,
            focusNode.id,
            visualizationInput.rootNode.id,
            visualizationInput.treeContentID.uuidString,
            String(maxRenderedDepth),
            visualizationInput.layoutIDComponent
        ].joined(separator: "|")

        Group {
            switch visualizationMode {
            case .sunburst:
                SunburstChartView(
                    rootNode: visualizationInput.rootNode,
                    parentNode: visualizationParentNode(for: visualizationInput),
                    treeStore: visualizationInput.treeStore,
                    snapshotID: snapshot.id,
                    activeTarget: scanState.selectedTarget,
                    trashSafetyPolicy: scanState.trashSafetyPolicy,
                    snapshotSource: scanState.snapshotSource,
                    focusedWorkspaceTarget: $focusedWorkspaceTarget,
                    selectedNodeID: navigation.selectedNodeID,
                    selectedAncestorIDs: navigation.selectedAncestorIDs,
                    depthLimit: maxRenderedDepth,
                    layoutID: layoutID,
                    isInputPending: isVisualizationInputPending,
                    onSelect: actions.selectNode,
                    onZoom: actions.selectAndFocusNode,
                    onSegmentClick: actions.recordSunburstSegmentClick,
                    onNavigateToParent: actions.navigateToParent,
                    onDiscardPileDragActiveChange: actions.setDiscardPileDragActive
                )
            case .treemap:
                TreemapChartView(
                    rootNode: visualizationInput.rootNode,
                    treeStore: visualizationInput.treeStore,
                    snapshotID: snapshot.id,
                    activeTarget: scanState.selectedTarget,
                    trashSafetyPolicy: scanState.trashSafetyPolicy,
                    snapshotSource: scanState.snapshotSource,
                    focusedWorkspaceTarget: $focusedWorkspaceTarget,
                    selectedNodeID: navigation.selectedNodeID,
                    depthLimit: maxRenderedDepth,
                    layoutID: layoutID,
                    isInputPending: isVisualizationInputPending,
                    onSelect: actions.selectNode,
                    onZoom: actions.selectAndFocusNode,
                    onDiscardPileDragActiveChange: actions.setDiscardPileDragActive
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: filterRequest, initial: true) { _, request in
            visualizationFilter.update(
                baseInput: baseVisualizationInput,
                request: request
            )
        }
    }

    private var contentsPane: some View {
        VStack(spacing: 0) {
            FileBrowserTableView(
                scanState: scanState,
                navigation: navigation,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                hiddenNodeIDs: discardPileHiddenNodeIDs,
                actions: fileBrowserActions
            )

            if showsWarningFooter {
                Divider()
                WarningFooter(
                    warnings: snapshot.scanWarnings,
                    fullDiskAccessStatus: fullDiskAccessStatus,
                    shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess,
                    actions: actions,
                    onDismiss: { dismissedWarningsScanScope = warningDismissalScope }
                )
            }
        }
    }

    private var showsWarningFooter: Bool {
        !snapshot.scanWarnings.isEmpty && dismissedWarningsScanScope != warningDismissalScope
    }

    private var warningDismissalScope: WarningDismissalScope {
        WarningDismissalScope(targetID: snapshot.target.id, startedAt: snapshot.startedAt)
    }

    private var diskMapVisualizationInput: DiskMapVisualizationInput {
        DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: focusNode,
            showFreeSpace: showFreeSpaceInDiskMaps,
            availableCapacity: freeSpaceAvailableCapacity(snapshot, focusNode)
        )
    }

    private func visualizationParentNode(for input: DiskMapVisualizationInput) -> FileNodeRecord? {
        guard input.rootNode.id == focusNode.id else { return nil }
        return input.treeStore.parent(of: input.rootNode.id)
    }

    private var fileBrowserActions: FileBrowserActions {
        FileBrowserActions(
            selectNode: actions.selectNodeImmediately,
            selectNodeAfterViewUpdate: actions.selectNode,
            selectNodes: actions.selectNodesImmediately,
            selectNodesAfterViewUpdate: actions.selectNodes,
            expandSummarizedNode: actions.expandSummarizedNode,
            zoomIntoSelection: actions.zoomIntoSelection,
            selectedFileActions: actions.selectedFileActions,
            bulkFileActions: actions.bulkFileActions,
            setDiscardPileDragActiveAfterThreshold: actions.setDiscardPileDragActiveAfterThreshold
        )
    }
}

private struct WarningDismissalScope: Equatable {
    let targetID: String
    let startedAt: Date
}
