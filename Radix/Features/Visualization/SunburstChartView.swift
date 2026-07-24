import AppKit
import SwiftUI

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 22
    private static let loadingDiskMapDelay: Duration = .milliseconds(150)

    let rootNode: FileNodeRecord
    let parentNode: FileNodeRecord?
    let treeStore: DiskMapTreeStore
    let snapshotID: UUID
    let activeTarget: ScanTarget?
    let trashSafetyPolicy: TrashSafetyPolicy
    let snapshotSource: ScanSnapshotSource
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
    let depthLimit: Int
    let layoutID: String
    let isInputPending: Bool
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void
    let onSegmentClick: () -> Void
    let onNavigateToParent: () -> Void
    let onDiscardPileDragActiveChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chartModel: SunburstChartModel
    @State private var isHoveringCenter = false
    @State private var showsLoadingDiskMapProgress = false
    @State private var viewportTransform = ChartViewportTransform.identity
    @State private var layoutRetryGeneration = 0

    init(
        rootNode: FileNodeRecord,
        parentNode: FileNodeRecord?,
        treeStore: DiskMapTreeStore,
        snapshotID: UUID,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        snapshotSource: ScanSnapshotSource,
        focusedWorkspaceTarget: FocusState<WorkspaceFocusTarget?>.Binding,
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>,
        depthLimit: Int,
        layoutID: String,
        isInputPending: Bool,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void,
        onSegmentClick: @escaping () -> Void,
        onNavigateToParent: @escaping () -> Void,
        onDiscardPileDragActiveChange: @escaping (Bool) -> Void,
        chartModel: @autoclosure @escaping () -> SunburstChartModel = SunburstChartModel()
    ) {
        self.rootNode = rootNode
        self.parentNode = parentNode
        self.treeStore = treeStore
        self.snapshotID = snapshotID
        self.activeTarget = activeTarget
        self.trashSafetyPolicy = trashSafetyPolicy
        self.snapshotSource = snapshotSource
        self._focusedWorkspaceTarget = focusedWorkspaceTarget
        self.selectedNodeID = selectedNodeID
        self.selectedAncestorIDs = selectedAncestorIDs
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.isInputPending = isInputPending
        self.onSelect = onSelect
        self.onZoom = onZoom
        self.onSegmentClick = onSegmentClick
        self.onNavigateToParent = onNavigateToParent
        self.onDiscardPileDragActiveChange = onDiscardPileDragActiveChange
        _chartModel = StateObject(wrappedValue: chartModel())
    }

    private var displayedNode: FileNodeRecord? {
        if isHoveringCenter, let parentNode {
            return parentNode
        }
        if let hoveredNodeID = chartModel.hoveredSegment?.nodeID,
           let hoveredNode = treeStore.node(id: hoveredNodeID) {
            return hoveredNode
        }
        if let selectedNodeID,
           let selectedNode = treeStore.node(id: selectedNodeID) {
            return selectedNode
        }
        return rootNode
    }

    private var hoverSummary: ChartSummary? {
        guard layoutPresentationState.canUseRenderedLayout else { return nil }
        guard let hoveredSegment = chartModel.hoveredSegment else { return nil }

        if let hoveredNodeID = hoveredSegment.nodeID,
           let hoveredNode = treeStore.node(id: hoveredNodeID) {
            return summary(for: hoveredNode)
        }

        return ChartSummary(
            status: String(localized: "Grouped Items", comment: "Chart status for several small items grouped into one segment."),
            title: hoveredSegment.label,
            value: RadixFormatters.size(hoveredSegment.totalSize),
            detail: String(localized: "Too small to show individually", comment: "Chart detail explaining why grouped items are combined.")
        )
    }

    private var canAdjustViewport: Bool {
        layoutPresentationState.canUseRenderedLayout
            && !chartModel.renderedSegments.isEmpty
    }

    private var isAwaitingLayout: Bool {
        layoutPresentationState.isAwaitingLayout
    }

    private var layoutPresentationState: ChartLayoutPresentationState {
        ChartLayoutPresentationState(
            readiness: chartModel.layoutReadiness,
            layoutID: layoutRequestID,
            isInputPending: isInputPending
        )
    }

    private var layoutRequestID: String {
        "\(layoutID)|retry:\(layoutRetryGeneration)"
    }

    private var loadingDiskMapProgressTaskID: String {
        "\(layoutRequestID)|\(isAwaitingLayout)"
    }

    var body: some View {
        GeometryReader { geometry in
            let baseChartFrame = chartFrame(in: geometry.size)
            let chartFrame = viewportTransform.frame(for: baseChartFrame)
            let layoutPresentation = layoutPresentationState
            let canAdjustViewport = self.canAdjustViewport

            ZStack {
                SunburstRenderedChartLayer(
                    segments: chartModel.renderedSegments,
                    renderVersion: chartModel.renderedLayoutVersion,
                    selectionSegments: chartModel.selectionOverlaySegments(
                        selectedNodeID: selectedNodeID,
                        selectedAncestorIDs: selectedAncestorIDs
                    ),
                    chartFrame: chartFrame
                )
                .id(chartModel.renderedLayoutVersion)
                .transition(chartTransition)
                .allowsHitTesting(false)

                SunburstHoverOverlay(
                    segment: layoutPresentation.canUseRenderedLayout
                        ? chartModel.hoveredSegment
                        : nil
                )
                .equatable()
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .allowsHitTesting(false)

                if parentNode != nil,
                   isHoveringCenter,
                   layoutPresentation.canUseRenderedLayout,
                   !chartModel.renderedSegments.isEmpty {
                    SunburstCenterAffordance()
                        .equatable()
                        .frame(
                            width: centerAffordanceSize(in: chartFrame),
                            height: centerAffordanceSize(in: chartFrame)
                        )
                        .position(x: chartFrame.midX, y: chartFrame.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if layoutPresentation.shouldObscureRenderedLayout {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.28)
                        .allowsHitTesting(false)

                    if layoutPresentation.isAwaitingLayout,
                       showsLoadingDiskMapProgress {
                        ProgressView("Loading Disk Map…")
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                } else if chartModel.layoutReadiness.failure == nil,
                          chartModel.renderedSegments.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                SunburstInteractionOverlay(
                    onHover: { location in
                        guard layoutPresentation.canUseRenderedLayout else { return }
                        updateHover(at: location, in: baseChartFrame)
                    },
                    onClick: { location, clickCount in
                        guard layoutPresentation.canUseRenderedLayout else { return }
                        handleClick(at: location, in: baseChartFrame, clickCount: clickCount)
                    },
                    onMove: { direction in
                        guard layoutPresentation.canUseRenderedLayout else { return false }
                        return handleSpatialMove(direction, in: baseChartFrame)
                    },
                    onKeyboardFocus: {
                        focusedWorkspaceTarget = .chart
                    },
                    isKeyboardFocused: focusedWorkspaceTarget == .chart,
                    onPan: { delta, location in
                        let nextTransform = panViewport(
                            by: delta,
                            in: baseChartFrame
                        )
                        updateHover(
                            at: location,
                            in: baseChartFrame,
                            using: nextTransform
                        )
                    },
                    onMagnify: { location, factor in
                        let nextTransform = zoomViewport(
                            by: factor,
                            anchor: location,
                            in: baseChartFrame,
                            animated: false
                        )
                        updateHover(
                            at: location,
                            in: baseChartFrame,
                            using: nextTransform
                        )
                    },
                    canStartPan: { location in
                        canStartPan(at: location, in: baseChartFrame)
                    },
                    discardPileDragItem: { location in
                        discardPileDragItem(at: location, in: baseChartFrame)
                    },
                    onDiscardPileDragActiveChange: onDiscardPileDragActiveChange,
                    help: { location in
                        guard layoutPresentation.canUseRenderedLayout else { return nil }
                        return help(at: location, in: baseChartFrame)
                    },
                    isPanEnabled: canAdjustViewport && viewportTransform.isZoomed
                )
                .accessibilityHidden(true)
                .allowsHitTesting(layoutPresentation.canUseRenderedLayout)

            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction(named: String(localized: "Zoom In", comment: "Accessibility action for zooming into the disk map.")) {
                zoomViewport(by: ChartViewportTransform.zoomInFactor, anchor: nil, in: baseChartFrame, animated: true)
            }
            .accessibilityAction(named: String(localized: "Zoom Out", comment: "Accessibility action for zooming out of the disk map.")) {
                zoomViewport(by: ChartViewportTransform.zoomOutFactor, anchor: nil, in: baseChartFrame, animated: true)
            }
            .accessibilityAction(named: String(localized: "Reset Zoom", comment: "Accessibility action for resetting the disk map zoom.")) {
                resetViewport(animated: true)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focusedWorkspaceTarget, equals: .chart)
            .overlay(alignment: .topLeading) {
                if let hoverSummary {
                    FloatingSummaryCard(summary: hoverSummary)
                        .padding(.top, 16)
                        .padding(.leading, 18)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if canAdjustViewport {
                    ChartViewportControls(
                        zoomText: viewportZoomText,
                        canZoomOut: viewportTransform.isZoomed,
                        canZoomIn: viewportTransform.scale < ChartViewportTransform.maximumScale,
                        zoomOut: {
                            zoomViewport(by: ChartViewportTransform.zoomOutFactor, anchor: nil, in: baseChartFrame, animated: true)
                        },
                        zoomIn: {
                            zoomViewport(by: ChartViewportTransform.zoomInFactor, anchor: nil, in: baseChartFrame, animated: true)
                        },
                        reset: {
                            resetViewport(animated: true)
                        }
                    )
                    .padding(.top, 16)
                    .padding(.trailing, 18)
                }
            }
            .overlay(alignment: .bottom) {
                if let layoutError = chartModel.layoutReadiness.failure,
                   layoutPresentation.showsFailure {
                    ChartLayoutFailureBanner(failure: layoutError) {
                        layoutRetryGeneration += 1
                    }
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
            .animation(centerHoverAnimation, value: isHoveringCenter)
            .animation(loadingIndicatorAnimation, value: showsLoadingDiskMapProgress)
            .onChange(of: baseChartFrame) { _, nextFrame in
                viewportTransform = viewportTransform.constrained(to: nextFrame)
            }
            .onChange(of: layoutID) { _, _ in
                resetViewport(animated: false)
            }
            .focusedSceneValue(\.chartViewportAction) { action in
                handleViewportAction(action, in: baseChartFrame)
            }
            .task(id: loadingDiskMapProgressTaskID) {
                await updateLoadingDiskMapProgress(isPending: isAwaitingLayout)
            }
            .task(id: SunburstLayoutTaskID(layoutID: layoutID, retryGeneration: layoutRetryGeneration)) {
                await chartModel.loadLayout(
                    treeStore: treeStore,
                    rootID: rootNode.id,
                    depthLimit: depthLimit,
                    layoutID: layoutRequestID
                )
            }
        }
    }

    private func handleSpatialMove(
        _ direction: ChartSpatialSelectionDirection,
        in baseChartFrame: CGRect
    ) -> Bool {
        guard layoutPresentationState.canUseRenderedLayout,
              let segment = chartModel.keyboardSelection(
            from: selectedNodeID,
            moving: direction
        ), let nodeID = segment.nodeID else {
            return false
        }

        let transformedFrame = viewportTransform.frame(for: baseChartFrame)
        let point = chartModel.keyboardSelectionPoint(for: segment, in: transformedFrame)
        viewportTransform = viewportTransform.revealing(
            point: point,
            within: baseChartFrame,
            padding: 12
        )
        isHoveringCenter = false
        chartModel.setHoveredSegmentID(nil)
        onSelect(nodeID)
        return true
    }

    private var chartTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.985, anchor: .center))
    }

    private var chartTransitionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.22)
    }

    private var centerHoverAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14)
    }

    private var loadingIndicatorAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12)
    }

    private var viewportAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16)
    }

    private var viewportZoomText: String {
        "\(Int((viewportTransform.scale * 100).rounded()))%"
    }

    private func updateHover(
        at location: CGPoint?,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) {
        guard let location else {
            isHoveringCenter = false
            chartModel.setHoveredSegmentID(nil)
            return
        }

        let transform = transform ?? viewportTransform
        if parentNode != nil,
           isCenterHit(at: location, in: frame, using: transform) {
            isHoveringCenter = true
            chartModel.setHoveredSegmentID(nil)
            return
        }

        isHoveringCenter = false
        let nextSegment = hitTest(at: location, in: frame, using: transform)
        chartModel.setHoveredSegmentID(nextSegment?.id)
    }

    private func handleClick(at location: CGPoint, in frame: CGRect, clickCount: Int) {
        if isCenterHit(at: location, in: frame) {
            if clickCount == 1, parentNode != nil {
                onNavigateToParent()
            }
            return
        }

        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID else {
            if clickCount == 1 {
                onSelect(nil)
            }
            return
        }

        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) {
            if clickCount == 1 {
                onSelect(nil)
            }
            return
        }

        if clickCount >= 2,
           treeStore.node(id: nodeID)?.isDirectory == true {
            onSegmentClick()
            onZoom(nodeID)
        } else {
            onSegmentClick()
            onSelect(nodeID)
        }
    }

    private var accessibilityValue: String {
        if let hoverSummary {
            return hoverSummary.accessibilityDescription
        }

        let node = displayedNode ?? rootNode
        return String(localized: "\(node.name), \(RadixFormatters.size(node.allocatedSize)), \(summaryStatus(for: node))", comment: "Accessibility value describing the selected sunburst segment.")
    }

    private var accessibilityHint: String {
        if parentNode != nil {
            return String(localized: "Click a segment or use the arrow keys to select it. Double-click a folder or press Command-Down Arrow to zoom in. Click the center or press Command-Up Arrow to go up.", comment: "Accessibility hint for the sunburst chart when navigating upward is available.")
        }

        return String(localized: "Click a segment or use the arrow keys to select it. Double-click a folder or press Command-Down Arrow to zoom in.", comment: "Accessibility hint for the sunburst chart.")
    }

    private func chartFrame(in size: CGSize) -> CGRect {
        let inset = Self.chartPadding
        let width = max(1, size.width - (inset * 2))
        let height = max(1, size.height - (inset * 2))
        let chartSide = min(width, height)

        return CGRect(
            x: inset + ((width - chartSide) / 2),
            y: inset + ((height - chartSide) / 2),
            width: chartSide,
            height: chartSide
        )
    }

    private func centerAffordanceSize(in frame: CGRect) -> CGFloat {
        min(frame.width, frame.height) * SunburstLayout.centerRadius
    }

    private func hitTest(
        at location: CGPoint,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) -> SunburstSegment? {
        let transform = transform ?? viewportTransform
        guard let chartPoint = transform.localChartPoint(for: location, in: frame) else {
            return nil
        }

        return chartModel.segment(at: chartPoint.point, in: chartPoint.size)
    }

    private func canStartPan(at location: CGPoint, in frame: CGRect) -> Bool {
        !isCenterHit(at: location, in: frame) && hitTest(at: location, in: frame) == nil
    }

    private func discardPileDragItem(at location: CGPoint, in frame: CGRect) -> SunburstDiscardPileDragItem? {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID,
              !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID),
              let node = treeStore.node(id: nodeID),
              canDragToDiscardPile(node) else {
            return nil
        }

        return SunburstDiscardPileDragItem(
            payload: DiscardPileDragPayload(
                snapshotID: snapshotID,
                nodeIDs: [nodeID]
            ),
            segment: segment
        )
    }

    private func canDragToDiscardPile(_ node: FileNodeRecord) -> Bool {
        FileNodeActionAvailability(
            node: node,
            activeTarget: activeTarget,
            trashSafetyPolicy: trashSafetyPolicy,
            snapshotSource: snapshotSource
        ).canMoveToTrash
    }

    private func isCenterHit(
        at location: CGPoint,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) -> Bool {
        let transform = transform ?? viewportTransform
        guard let chartPoint = transform.localChartPoint(for: location, in: frame) else {
            return false
        }

        return SunburstCenterHitTester.contains(
            point: chartPoint.point,
            in: chartPoint.size
        )
    }

    private func help(at location: CGPoint, in frame: CGRect) -> String? {
        guard let parentNode, isCenterHit(at: location, in: frame) else { return nil }
        return String(localized: "Go up to \(parentNode.name)", comment: "Tooltip for the sunburst chart center navigation affordance.")
    }

    private func summary(for node: FileNodeRecord) -> ChartSummary {
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            return ChartSummary(
                status: summaryStatus(for: node),
                title: node.name,
                value: RadixFormatters.size(node.allocatedSize),
                detail: String(localized: "APFS available capacity", comment: "Chart detail describing free space on an APFS volume.")
            )
        }

        let detail: String
        if node.id != rootNode.id,
           let percentText = RadixFormatters.percentage(part: node.allocatedSize, total: rootNode.allocatedSize) {
            detail = String(localized: "\(percentText) of current focus", comment: "Chart detail showing an item's percentage of the current focus.")
        } else {
            detail = node.itemKind(activeTarget: activeTarget)
        }

        return ChartSummary(
            status: node.itemKind(activeTarget: activeTarget),
            title: node.name,
            value: RadixFormatters.size(node.allocatedSize),
            detail: detail
        )
    }

    private func summaryStatus(for node: FileNodeRecord) -> String {
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            return String(localized: "Available Space", comment: "Chart status for free capacity on a volume.")
        }
        return node.itemKind(activeTarget: activeTarget)
    }

    @discardableResult
    private func zoomViewport(
        by factor: CGFloat,
        anchor: CGPoint?,
        in baseFrame: CGRect,
        animated: Bool
    ) -> ChartViewportTransform {
        guard canAdjustViewport else { return viewportTransform }

        let nextTransform = viewportTransform.zoomed(
            by: factor,
            anchor: anchor,
            in: baseFrame
        )
        setViewportTransform(nextTransform, animated: animated)
        return nextTransform
    }

    @discardableResult
    private func panViewport(
        by delta: CGSize,
        in baseFrame: CGRect
    ) -> ChartViewportTransform {
        guard canAdjustViewport else { return viewportTransform }

        let nextTransform = viewportTransform.panned(by: delta, in: baseFrame)
        setViewportTransform(nextTransform, animated: false)
        return nextTransform
    }

    private func resetViewport(animated: Bool) {
        setViewportTransform(.identity, animated: animated)
    }

    private func handleViewportAction(
        _ action: ChartViewportAction,
        in baseFrame: CGRect
    ) {
        switch action {
        case .zoomIn:
            zoomViewport(
                by: ChartViewportTransform.zoomInFactor,
                anchor: nil,
                in: baseFrame,
                animated: true
            )
        case .zoomOut:
            zoomViewport(
                by: ChartViewportTransform.zoomOutFactor,
                anchor: nil,
                in: baseFrame,
                animated: true
            )
        case .reset:
            resetViewport(animated: true)
        }
    }

    private func setViewportTransform(
        _ nextTransform: ChartViewportTransform,
        animated: Bool
    ) {
        guard viewportTransform != nextTransform else { return }

        let update = {
            viewportTransform = nextTransform
        }

        if animated {
            withAnimation(viewportAnimation, update)
        } else {
            update()
        }
    }

    private func updateLoadingDiskMapProgress(isPending: Bool) async {
        guard isPending else {
            showsLoadingDiskMapProgress = false
            return
        }

        showsLoadingDiskMapProgress = false

        do {
            try await Task.sleep(for: Self.loadingDiskMapDelay)
        } catch {
            return
        }

        guard isAwaitingLayout else { return }
        showsLoadingDiskMapProgress = true
    }
}

private struct SunburstCenterAffordance: View, Equatable {
    var body: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .shadow(color: Color.black.opacity(0.14), radius: 2, y: 1)
    }
}

private struct SunburstLayoutTaskID: Hashable {
    let layoutID: String
    let retryGeneration: Int
}

private struct SunburstRenderedChartLayer: View {
    let segments: [SunburstSegment]
    let renderVersion: Int
    let selectionSegments: [SunburstSelectionOverlaySegment]
    let chartFrame: CGRect

    var body: some View {
        ZStack {
            SunburstBaseCanvas(
                segments: segments,
                renderVersion: renderVersion
            )
            .equatable()

            SunburstSelectionOverlay(segments: selectionSegments)
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: chartFrame.width, height: chartFrame.height)
        .position(x: chartFrame.midX, y: chartFrame.midY)
        .compositingGroup()
    }
}
