import SwiftUI

struct SelectionInspectorActions {
    let selectNodeAfterViewUpdate: (String?) -> Void
    let selectAndFocusNodeAfterViewUpdate: (String) -> Void
    let expandSummarizedNode: (FileNodeRecord) -> Void
    let selectedFileActions: SelectedFileActions
    let addPrimarySelectionToDiscardPile: () -> Void
    let bulkFileActions: BulkFileActions
    let openFullDiskAccessSettings: () -> Void
}

struct SelectionInspectorView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    let fullDiskAccessStatus: FullDiskAccessStatus
    let actions: SelectionInspectorActions

    var body: some View {
        let selectedNodes = navigation.selectedNodes

        Group {
            if selectedNodes.count > 1 {
                multiSelectionView(selectedNodes)
            } else if let node = navigation.selectedNode {
                singleSelectionView(node)
            } else {
                InspectorNoSelectionView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func multiSelectionView(_ selectedNodes: [FileNodeRecord]) -> some View {
        let summary = InspectorSelectionSummary(
            selectedNodes: selectedNodes,
            fileTreeStore: scanState.fileTreeStore
        )
        let availability = FileNodeActionAvailability(
            nodes: selectedNodes,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )
        let removalAvailability = FileNodeActionAvailability(
            nodes: summary.topLevelSelectedNodes,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )
        let canMoveSelectionToTrash = summary.missingSelectedNodeCount == 0
            && removalAvailability.canMoveToTrash
        let warnings = relevantWarnings(for: summary.topLevelSelectedNodes)

        return InspectorMultiSelectionView(
            summary: summary,
            percentOfScan: selectionPercentOfScanText(summary) ?? "—",
            availability: availability,
            canMoveSelectionToTrash: canMoveSelectionToTrash,
            availabilityNotice: multiSelectionAvailabilityNotice(
                summary: summary,
                canMoveSelectionToTrash: canMoveSelectionToTrash
            ),
            warnings: warnings,
            fullDiskAccessAdvice: fullDiskAccessAdvice(for: warnings),
            actions: actions.bulkFileActions,
            openFullDiskAccessSettings: actions.openFullDiskAccessSettings
        )
    }

    private func singleSelectionView(_ node: FileNodeRecord) -> some View {
        let availability = FileNodeActionAvailability(
            node: node,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )
        let warnings = relevantWarnings(for: [node])
        let largestChildren = largestChildren(of: node)

        return VStack(spacing: 0) {
            Form {
                InspectorSummarySection(
                    node: node,
                    availability: availability,
                    actions: actions.selectedFileActions
                )

                InspectorStorageSection(
                    allocatedSize: node.allocatedSize,
                    percentOfParent: selectedNodePercentOfParentText,
                    percentOfScan: selectedNodePercentOfScanText ?? "—"
                )

                if node.cloneIdentity != nil || node.mayShareDataBlocks {
                    InspectorSharedStorageSection(node: node)
                }

                if !warnings.isEmpty {
                    InspectorWarningsSection(
                        selectionName: node.name,
                        warnings: warnings,
                        fullDiskAccessAdvice: fullDiskAccessAdvice(for: warnings),
                        openFullDiskAccessSettings: actions.openFullDiskAccessSettings
                    )
                }

                if let notice = singleSelectionAvailabilityNotice(for: node) {
                    InspectorAvailabilityNotice(kind: notice)
                }

                if canExpandSummarizedSelection(node) {
                    InspectorSummarizedSection {
                        actions.expandSummarizedNode(node)
                    }
                }

                if !largestChildren.isEmpty {
                    InspectorLargestChildrenSection(children: largestChildren) { child in
                        selectLargestChild(child)
                    }
                }

                if !node.isSynthetic {
                    InspectorDetailsSection(
                        node: node,
                        activeTarget: scanState.selectedTarget
                    )
                }
            }
            .formStyle(.grouped)

            if availability.canRevealInFinder || availability.canMoveToTrash {
                InspectorActionBar(
                    revealAction: availability.canRevealInFinder
                        ? { actions.selectedFileActions.perform(.revealInFinder) }
                        : nil,
                    addToDiscardPileAction: availability.canMoveToTrash
                        ? actions.addPrimarySelectionToDiscardPile
                        : nil,
                    addToDiscardPileTitle: String(
                        localized: "Add to Discard Pile",
                        comment: "Action for marking the selected item for possible deletion."
                    )
                )
            }
        }
    }

    private func relevantWarnings(for nodes: [FileNodeRecord]) -> [ScanWarning] {
        guard let warnings = scanState.snapshot?.scanWarnings, !warnings.isEmpty else {
            return []
        }
        let rootPaths = nodes
            .filter { !$0.isSynthetic }
            .map { $0.url.standardizedFileURL.path }
        guard !rootPaths.isEmpty else { return [] }

        return warnings.filter { warning in
            let warningPath = URL(filePath: warning.path).standardizedFileURL.path
            return rootPaths.contains { rootPath in
                warningPath == rootPath || warningPath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
            }
        }
    }

    private func fullDiskAccessAdvice(for warnings: [ScanWarning]) -> FullDiskAccessAdvice {
        PermissionAdvisor.fullDiskAccessAdvice(
            for: warnings,
            fullDiskAccessStatus: fullDiskAccessStatus,
            snapshotSource: scanState.snapshotSource
        )
    }

    private func largestChildren(of node: FileNodeRecord) -> [FileNodeRecord] {
        guard node.isDirectory, let fileTreeStore = scanState.fileTreeStore else {
            return []
        }
        return fileTreeStore.childrenPrefix(of: node.id, maxCount: 3)
    }

    private var selectedNodePercentOfParentText: String? {
        guard let selectedNode = navigation.selectedNode,
              let parent = navigation.selectedNodeParent else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: parent.allocatedSize)
    }

    private var selectedNodePercentOfScanText: String? {
        guard let selectedNode = navigation.selectedNode,
              let root = scanState.snapshot?.root else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: root.allocatedSize)
    }

    private func selectionPercentOfScanText(_ summary: InspectorSelectionSummary) -> String? {
        guard let root = scanState.snapshot?.root else { return nil }
        return RadixFormatters.percentage(part: summary.allocatedSize, total: root.allocatedSize)
    }

    private func singleSelectionAvailabilityNotice(
        for node: FileNodeRecord
    ) -> InspectorAvailabilityNoticeKind? {
        if scanState.snapshotSource.isImported {
            return .savedScan
        }
        if scanState.selectedTarget?.kind == .volume,
           scanState.selectedTarget?.id == node.id {
            return .scanRoot
        }
        if scanState.trashSafetyPolicy.blockReason(for: node.url) != nil {
            return .protectedLocation
        }
        return nil
    }

    private func multiSelectionAvailabilityNotice(
        summary: InspectorSelectionSummary,
        canMoveSelectionToTrash: Bool
    ) -> InspectorAvailabilityNoticeKind? {
        if scanState.snapshotSource.isImported {
            return .savedScan
        }
        if summary.selectedNodes.contains(where: { !$0.supportsFileActions }) {
            return .limitedSelection
        }
        if summary.missingSelectedNodeCount == 0, !canMoveSelectionToTrash {
            return .protectedSelection
        }
        return nil
    }

    private func canExpandSummarizedSelection(_ node: FileNodeRecord) -> Bool {
        node.isAutoSummarized && !scanState.snapshotSource.isImported
    }

    private func selectLargestChild(_ child: FileNodeRecord) {
        guard child.isDirectory,
              scanState.fileTreeStore?.containsChildren(id: child.id) == true else {
            actions.selectNodeAfterViewUpdate(child.id)
            return
        }

        actions.selectAndFocusNodeAfterViewUpdate(child.id)
    }
}
