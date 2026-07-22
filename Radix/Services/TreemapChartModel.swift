//
//  TreemapChartModel.swift
//  Radix
//

import Combine
import CoreGraphics
import Foundation

protocol TreemapLayouting: Sendable {
    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment]
}

actor TreemapLayoutService: TreemapLayouting {
    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment] {
        try TreemapLayout.segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            size: size,
            cancellationCheck: Task.checkCancellation
        )
    }
}

@MainActor
final class TreemapChartModel: ObservableObject {
    @Published private var renderState = TreemapChartRenderState()
    @Published private(set) var layoutReadiness = ChartLayoutReadiness()

    private let layoutService: any TreemapLayouting
    private let layoutRequests = ChartLayoutRequestCoordinator<[TreemapSegment]>()

    init(layoutService: any TreemapLayouting = TreemapLayoutService()) {
        self.layoutService = layoutService
    }

    var renderedSegments: [TreemapSegment] {
        renderState.segments
    }

    var hoveredSegmentID: TreemapSegment.ID? {
        renderState.hoveredSegmentID
    }

    var hoveredSegment: TreemapSegment? {
        renderState.hoveredSegment
    }

    var renderedLayoutVersion: Int {
        renderState.version
    }

    func setHoveredSegmentID(_ segmentID: TreemapSegment.ID?) {
        guard hoveredSegmentID != segmentID else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = segmentID
        renderState = nextState
    }

    func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        renderState.segment(at: point, in: size)
    }

    func selectedSegment(nodeID: String?) -> TreemapSegment? {
        renderState.segment(nodeID: nodeID)
    }

    func spatialSelectionNodeID(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        in size: CGSize
    ) -> String? {
        let displayedSegments = renderedSegments.map { segment in
            (segment, TreemapRenderer.displayRect(for: segment, in: size))
        }
        var firstChildYByContainer: [String: CGFloat] = [:]
        for (segment, frame) in displayedSegments {
            firstChildYByContainer[segment.containerNodeID] = min(
                firstChildYByContainer[segment.containerNodeID] ?? .greatestFiniteMagnitude,
                frame.minY
            )
        }

        let candidates = displayedSegments.compactMap { segment, displayFrame
            -> ChartSpatialSelectionCandidate? in
            guard let nodeID = segment.nodeID,
                  !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) else {
                return nil
            }

            let selectionFrame: CGRect
            if segment.showsContainerHeader,
               let firstChildY = firstChildYByContainer[nodeID],
               firstChildY > displayFrame.minY {
                selectionFrame = CGRect(
                    x: displayFrame.minX,
                    y: displayFrame.minY,
                    width: displayFrame.width,
                    height: min(firstChildY - displayFrame.minY, displayFrame.height)
                )
            } else {
                selectionFrame = displayFrame
            }
            return ChartSpatialSelectionCandidate(
                nodeID: nodeID,
                frame: selectionFrame
            )
        }
        return ChartSpatialSelection.nextNodeID(
            from: selectedNodeID,
            moving: direction,
            among: candidates
        )
    }

    @discardableResult
    func loadLayout(
        treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        layoutID: String
    ) async -> Bool {
        let request = layoutRequests.start(layoutID: layoutID) { [layoutService] in
            try await layoutService.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit,
                size: size
            )
        }
        clearHover()
        layoutReadiness.start()

        switch await layoutRequests.outcome(for: request) {
        case let .success(segments):
            apply(segments)
            layoutReadiness.succeed(layoutID: layoutID)
            return true
        case let .failure(error):
            layoutReadiness.fail(error, layoutID: layoutID)
            return false
        case .cancelled:
            layoutReadiness.cancel()
            return false
        case .superseded:
            return false
        }
    }

    @discardableResult
    func loadLayout(
        treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        layoutID: String
    ) async -> Bool {
        await loadLayout(
            treeStore: DiskMapTreeStore(treeStore),
            rootID: rootID,
            depthLimit: depthLimit,
            size: size,
            layoutID: layoutID
        )
    }

    private func apply(_ segments: [TreemapSegment]) {
        renderState = TreemapChartRenderState(
            segments: segments,
            version: renderState.version + 1
        )
    }

    private func clearHover() {
        guard hoveredSegmentID != nil else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = nil
        renderState = nextState
    }
}

private struct TreemapChartRenderState {
    var segments: [TreemapSegment]
    var hoveredSegmentID: TreemapSegment.ID?
    var version: Int

    private var segmentLookup: [TreemapSegment.ID: TreemapSegment]
    private var segmentByNodeID: [String: TreemapSegment]
    private var hitTestIndex: TreemapHitTestIndex

    init(
        segments: [TreemapSegment] = [],
        hoveredSegmentID: TreemapSegment.ID? = nil,
        version: Int = 0
    ) {
        self.segments = segments
        self.hoveredSegmentID = hoveredSegmentID
        self.version = version
        segmentLookup = segments.reduce(into: [:]) { lookup, segment in
            lookup[segment.id] = segment
        }
        segmentByNodeID = segments.reduce(into: [:]) { lookup, segment in
            guard let nodeID = segment.nodeID else { return }
            lookup[nodeID] = segment
        }
        hitTestIndex = TreemapHitTestIndex(segments: segments)
    }

    var hoveredSegment: TreemapSegment? {
        guard let hoveredSegmentID else { return nil }
        return segmentLookup[hoveredSegmentID]
    }

    func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        hitTestIndex.segment(at: point, in: size)
    }

    func segment(nodeID: String?) -> TreemapSegment? {
        guard let nodeID else { return nil }
        return segmentByNodeID[nodeID]
    }
}
