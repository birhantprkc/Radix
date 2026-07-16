import SwiftUI

struct TreemapChartView: View {
    private static let chartPadding: CGFloat = 18
    private static let loadingDiskMapDelay: Duration = .milliseconds(150)
    /// The tooltip sizes itself vertically. This maximum keeps edge placement safe
    /// when a long name wraps onto its second line.
    private static let tooltipMaximumSize = CGSize(width: 272, height: 122)

    let rootNode: FileNodeRecord
    let treeStore: DiskMapTreeStore
    let snapshotID: UUID
    let activeTarget: ScanTarget?
    let trashSafetyPolicy: TrashSafetyPolicy
    let snapshotSource: ScanSnapshotSource
    let selectedNodeID: String?
    let depthLimit: Int
    let layoutID: String
    let isInputPending: Bool
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void
    let onDiscardPileDragActiveChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chartModel: TreemapChartModel
    @State private var showsLoadingDiskMapProgress = false
    @State private var tooltipAnchor: CGPoint?
    @State private var layoutRetryGeneration = 0

    init(
        rootNode: FileNodeRecord,
        treeStore: DiskMapTreeStore,
        snapshotID: UUID,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        snapshotSource: ScanSnapshotSource,
        selectedNodeID: String?,
        depthLimit: Int,
        layoutID: String,
        isInputPending: Bool,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void,
        onDiscardPileDragActiveChange: @escaping (Bool) -> Void,
        chartModel: @autoclosure @escaping () -> TreemapChartModel = TreemapChartModel()
    ) {
        self.rootNode = rootNode
        self.treeStore = treeStore
        self.snapshotID = snapshotID
        self.activeTarget = activeTarget
        self.trashSafetyPolicy = trashSafetyPolicy
        self.snapshotSource = snapshotSource
        self.selectedNodeID = selectedNodeID
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.isInputPending = isInputPending
        self.onSelect = onSelect
        self.onZoom = onZoom
        self.onDiscardPileDragActiveChange = onDiscardPileDragActiveChange
        _chartModel = StateObject(wrappedValue: chartModel())
    }

    private var displayedNode: FileNodeRecord {
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

    private var tooltipContent: TreemapTooltipContent? {
        guard let hoveredSegment = chartModel.hoveredSegment else { return nil }
        return TreemapTooltipContent.content(
            for: hoveredSegment,
            rootNode: rootNode,
            treeStore: treeStore
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let chartFrame = chartFrame(in: geometry.size)
            let layoutTaskID = TreemapLayoutTaskID(
                layoutID: layoutID,
                size: chartFrame.size,
                retryGeneration: layoutRetryGeneration
            )
            let isDiskMapPending = isInputPending
                || chartModel.isRenderingPending(layoutID: layoutTaskID.requestID)

            ZStack {
                TreemapRenderedChartLayer(
                    segments: chartModel.renderedSegments,
                    renderVersion: chartModel.renderedLayoutVersion,
                    selectedSegment: chartModel.selectedSegment(nodeID: selectedNodeID),
                    hoveredSegment: isDiskMapPending ? nil : chartModel.hoveredSegment,
                    chartFrame: chartFrame
                )
                .id(chartModel.renderedLayoutVersion)
                .transition(chartTransition)
                .allowsHitTesting(false)

                if isDiskMapPending {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.28)
                        .allowsHitTesting(false)

                    if showsLoadingDiskMapProgress {
                        ProgressView("Loading Disk Map…")
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                } else if chartModel.layoutError == nil,
                          chartModel.renderedSegments.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                TreemapInteractionOverlay(
                    onHover: { location in
                        guard !isDiskMapPending else { return }
                        updateHover(at: location, in: chartFrame)
                    },
                    onClick: { location, clickCount in
                        guard !isDiskMapPending else { return }
                        handleClick(at: location, in: chartFrame, clickCount: clickCount)
                    },
                    discardPileDragItem: { location in
                        discardPileDragItem(at: location, in: chartFrame)
                    },
                    onDiscardPileDragActiveChange: onDiscardPileDragActiveChange
                )
                .accessibilityHidden(true)
                .allowsHitTesting(!isDiskMapPending)
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Treemap disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Select a tile to inspect it. Double-click a folder tile to zoom in. Use the breadcrumb to go up.")
            .overlay(alignment: .topLeading) {
                if !isDiskMapPending,
                   let tooltipContent,
                   let tooltipAnchor {
                    TreemapHoverTooltip(content: tooltipContent)
                        .frame(width: Self.tooltipMaximumSize.width)
                        .offset(tooltipOrigin(at: tooltipAnchor, in: geometry.size))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let layoutError = chartModel.layoutError,
                   !isDiskMapPending {
                    ChartLayoutFailureBanner(failure: layoutError) {
                        layoutRetryGeneration += 1
                    }
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
            .animation(loadingIndicatorAnimation, value: showsLoadingDiskMapProgress)
            .task(id: "\(layoutTaskID.requestID)|\(isDiskMapPending)") {
                await updateLoadingDiskMapProgress(
                    isPending: isDiskMapPending,
                    layoutID: layoutTaskID.requestID
                )
            }
            .task(id: layoutTaskID) {
                await chartModel.loadLayout(
                    treeStore: treeStore,
                    rootID: rootNode.id,
                    depthLimit: depthLimit,
                    size: chartFrame.size,
                    layoutID: layoutTaskID.requestID
                )
            }
        }
    }

    private var chartTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.992, anchor: .center))
    }

    private var chartTransitionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.22)
    }

    private var loadingIndicatorAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12)
    }

    private var accessibilityValue: String {
        if let tooltipContent {
            return tooltipContent.accessibilityDescription
        }

        return String(localized: "\(displayedNode.name), \(RadixFormatters.size(displayedNode.allocatedSize)), \(summaryStatus(for: displayedNode))", comment: "Accessibility value describing the selected treemap tile.")
    }

    private func chartFrame(in size: CGSize) -> CGRect {
        let inset = Self.chartPadding
        return CGRect(
            x: inset,
            y: inset,
            width: max(size.width - (inset * 2), 1),
            height: max(size.height - (inset * 2), 1)
        )
    }

    private func updateHover(at location: CGPoint?, in frame: CGRect) {
        guard let location,
              let segment = hitTest(at: location, in: frame) else {
            tooltipAnchor = nil
            chartModel.setHoveredSegmentID(nil)
            return
        }

        tooltipAnchor = location
        chartModel.setHoveredSegmentID(segment.id)
    }

    private func tooltipOrigin(at location: CGPoint, in size: CGSize) -> CGSize {
        let origin = TreemapTooltipPlacement.origin(
            for: location,
            tooltipSize: Self.tooltipMaximumSize,
            in: CGRect(origin: .zero, size: size)
        )
        return CGSize(width: origin.x, height: origin.y)
    }

    private func handleClick(at location: CGPoint, in frame: CGRect, clickCount: Int) {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID else {
            if clickCount == 1 { onSelect(nil) }
            return
        }

        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) {
            if clickCount == 1 { onSelect(nil) }
            return
        }

        if clickCount >= 2,
           treeStore.node(id: nodeID)?.isDirectory == true {
            onZoom(nodeID)
        } else {
            onSelect(nodeID)
        }
    }

    private func hitTest(at location: CGPoint, in frame: CGRect) -> TreemapSegment? {
        guard frame.contains(location) else { return nil }
        let localPoint = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        return chartModel.segment(at: localPoint, in: frame.size)
    }

    private func discardPileDragItem(
        at location: CGPoint,
        in frame: CGRect
    ) -> TreemapDiscardPileDragItem? {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID,
              !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID),
              let node = treeStore.node(id: nodeID),
              canDragToDiscardPile(node) else {
            return nil
        }

        return TreemapDiscardPileDragItem(
            payload: DiscardPileDragPayload(snapshotID: snapshotID, nodeIDs: [nodeID]),
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

    private func summaryStatus(for node: FileNodeRecord) -> String {
        DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id)
            ? String(localized: "Available Space", comment: "Chart status for free capacity on a volume.")
            : node.itemKind(activeTarget: activeTarget)
    }

    private func updateLoadingDiskMapProgress(
        isPending: Bool,
        layoutID: String
    ) async {
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
        guard isInputPending || chartModel.isRenderingPending(layoutID: layoutID) else { return }
        showsLoadingDiskMapProgress = true
    }
}

private struct TreemapHoverTooltip: View {
    private static let iconColumnWidth: CGFloat = 18

    let content: TreemapTooltipContent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: content.systemImageName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconColumnWidth)

                Text(content.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            tooltipTextRow {
                Text(content.sizeAndSignificance)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder")
                        .frame(width: Self.iconColumnWidth)

                    Text(content.location)
                        .truncationMode(.middle)
                }

                tooltipTextRow {
                    Text(content.metadata)
                }
            }
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.76))
            .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 2)
    }

    private func tooltipTextRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Color.clear
                .frame(width: Self.iconColumnWidth, height: 0)
                .accessibilityHidden(true)
            content()
        }
    }
}

private struct TreemapLayoutTaskID: Hashable {
    private nonisolated static let sizeBucket: CGFloat = 24

    let layoutID: String
    let widthBucket: Int
    let heightBucket: Int
    let retryGeneration: Int

    init(layoutID: String, size: CGSize, retryGeneration: Int) {
        self.layoutID = layoutID
        widthBucket = Int((size.width / Self.sizeBucket).rounded())
        heightBucket = Int((size.height / Self.sizeBucket).rounded())
        self.retryGeneration = retryGeneration
    }

    var cacheID: String {
        "\(layoutID)|treemap:\(widthBucket)x\(heightBucket)"
    }

    var requestID: String {
        "\(cacheID)|retry:\(retryGeneration)"
    }
}

private struct TreemapRenderedChartLayer: View {
    let segments: [TreemapSegment]
    let renderVersion: Int
    let selectedSegment: TreemapSegment?
    let hoveredSegment: TreemapSegment?
    let chartFrame: CGRect

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            TreemapBaseCanvas(
                segments: segments,
                renderVersion: renderVersion,
                colorScheme: colorScheme
            )
                .equatable()

            TreemapHoverOverlay(
                segment: hoveredSegment,
                colorScheme: colorScheme
            )
                .equatable()
                .allowsHitTesting(false)

            TreemapSelectionOverlay(segment: selectedSegment)
                .equatable()
                .allowsHitTesting(false)

            TreemapLabelCanvas(
                segments: segments,
                renderVersion: renderVersion,
                colorScheme: colorScheme
            )
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: chartFrame.width, height: chartFrame.height)
        .position(x: chartFrame.midX, y: chartFrame.midY)
        .compositingGroup()
    }
}
