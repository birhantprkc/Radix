import SwiftUI

struct TreemapChartView: View {
    private static let chartPadding: CGFloat = 18
    private static let loadingDiskMapDelay: Duration = .milliseconds(150)
    private static let tooltipSize = CGSize(width: 208, height: 82)

    let rootNode: FileNodeRecord
    let treeStore: FileTreeStore
    let snapshotID: UUID
    let activeTarget: ScanTarget?
    let trashSafetyPolicy: TrashSafetyPolicy
    let snapshotSource: ScanSnapshotSource
    let selectedNodeID: String?
    let depthLimit: Int
    let layoutID: String
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void
    let onDiscardPileDragActiveChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chartModel: TreemapChartModel
    @State private var showsLoadingDiskMapProgress = false
    @State private var hoverLocation: CGPoint?

    init(
        rootNode: FileNodeRecord,
        treeStore: FileTreeStore,
        snapshotID: UUID,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        snapshotSource: ScanSnapshotSource,
        selectedNodeID: String?,
        depthLimit: Int,
        layoutID: String,
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

    private var hoverSummary: ChartSummary? {
        guard let hoveredSegment = chartModel.hoveredSegment else { return nil }
        if let nodeID = hoveredSegment.nodeID,
           let node = treeStore.node(id: nodeID) {
            return summary(for: node)
        }
        return ChartSummary(
            status: "Grouped Items",
            title: hoveredSegment.label,
            value: RadixFormatters.size(hoveredSegment.totalSize),
            detail: "Too small to show individually"
        )
    }

    private var loadingDiskMapProgressTaskID: String {
        "\(layoutID)|\(chartModel.isLayoutPending)"
    }

    var body: some View {
        GeometryReader { geometry in
            let chartFrame = chartFrame(in: geometry.size)
            let layoutTaskID = TreemapLayoutTaskID(layoutID: layoutID, size: chartFrame.size)

            ZStack {
                TreemapRenderedChartLayer(
                    segments: chartModel.renderedSegments,
                    renderVersion: chartModel.renderedLayoutVersion,
                    selectedSegment: chartModel.selectedSegment(nodeID: selectedNodeID),
                    hoveredSegment: chartModel.hoveredSegment,
                    chartFrame: chartFrame
                )
                .id(chartModel.renderedLayoutVersion)
                .transition(chartTransition)
                .allowsHitTesting(false)

                if chartModel.isLayoutPending {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.28)
                        .allowsHitTesting(false)

                    if showsLoadingDiskMapProgress {
                        ProgressView("Loading Disk Map…")
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                } else if chartModel.renderedSegments.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                TreemapInteractionOverlay(
                    onHover: { location in
                        guard !chartModel.isLayoutPending else { return }
                        updateHover(at: location, in: chartFrame)
                    },
                    onClick: { location, clickCount in
                        guard !chartModel.isLayoutPending else { return }
                        handleClick(at: location, in: chartFrame, clickCount: clickCount)
                    },
                    discardPileDragItem: { location in
                        discardPileDragItem(at: location, in: chartFrame)
                    },
                    onDiscardPileDragActiveChange: onDiscardPileDragActiveChange
                )
                .accessibilityHidden(true)
                .allowsHitTesting(!chartModel.isLayoutPending)
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Treemap disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Select a tile to inspect it. Double-click a folder tile to zoom in. Use the breadcrumb to go up.")
            .overlay(alignment: .topLeading) {
                if let hoverSummary, let hoverLocation {
                    TreemapHoverTooltip(summary: hoverSummary)
                        .frame(
                            width: Self.tooltipSize.width,
                            height: Self.tooltipSize.height
                        )
                        .offset(tooltipOrigin(at: hoverLocation, in: geometry.size))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
            .animation(loadingIndicatorAnimation, value: showsLoadingDiskMapProgress)
            .task(id: loadingDiskMapProgressTaskID) {
                await updateLoadingDiskMapProgress(isPending: chartModel.isLayoutPending)
            }
            .task(id: layoutTaskID) {
                await chartModel.loadLayout(
                    treeStore: treeStore,
                    rootID: rootNode.id,
                    depthLimit: depthLimit,
                    size: chartFrame.size,
                    layoutID: layoutTaskID.cacheID
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
        if let hoverSummary {
            return hoverSummary.accessibilityDescription
        }

        return "\(displayedNode.name), \(RadixFormatters.size(displayedNode.allocatedSize)), \(summaryStatus(for: displayedNode))"
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
            hoverLocation = nil
            chartModel.setHoveredSegmentID(nil)
            return
        }
        hoverLocation = location
        chartModel.setHoveredSegmentID(segment.id)
    }

    private func tooltipOrigin(at location: CGPoint, in size: CGSize) -> CGSize {
        let origin = TreemapTooltipPlacement.origin(
            for: location,
            tooltipSize: Self.tooltipSize,
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

        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) {
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
              !SunburstFreeSpaceVisualization.isFreeSpaceNodeID(nodeID),
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

    private func summary(for node: FileNodeRecord) -> ChartSummary {
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            return ChartSummary(
                status: summaryStatus(for: node),
                title: node.name,
                value: RadixFormatters.size(node.allocatedSize),
                detail: "APFS available capacity"
            )
        }

        let detail: String
        if node.id != rootNode.id,
           let percentage = RadixFormatters.percentage(part: node.allocatedSize, total: rootNode.allocatedSize) {
            detail = percentage + " of current focus"
        } else {
            detail = node.itemKind
        }

        return ChartSummary(
            status: node.itemKind,
            title: node.name,
            value: RadixFormatters.size(node.allocatedSize),
            detail: detail
        )
    }

    private func summaryStatus(for node: FileNodeRecord) -> String {
        SunburstFreeSpaceVisualization.isFreeSpaceNodeID(node.id)
            ? "Available Space"
            : node.itemKind
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
        guard chartModel.isLayoutPending else { return }
        showsLoadingDiskMapProgress = true
    }
}

private struct TreemapHoverTooltip: View {
    let summary: ChartSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(summary.value)
                    .font(.subheadline.weight(.semibold))
            }

            Text(summary.title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            Text(summary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 2)
    }
}

private struct TreemapLayoutTaskID: Hashable {
    private nonisolated static let sizeBucket: CGFloat = 24

    let layoutID: String
    let widthBucket: Int
    let heightBucket: Int

    init(layoutID: String, size: CGSize) {
        self.layoutID = layoutID
        widthBucket = Int((size.width / Self.sizeBucket).rounded())
        heightBucket = Int((size.height / Self.sizeBucket).rounded())
    }

    var cacheID: String {
        "\(layoutID)|treemap:\(widthBucket)x\(heightBucket)"
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
