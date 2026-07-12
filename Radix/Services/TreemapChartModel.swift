//
//  TreemapChartModel.swift
//  Radix
//

import Combine
import CoreGraphics
import Foundation

protocol TreemapLayouting: Sendable {
    func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment]
}

actor TreemapLayoutService: TreemapLayouting {
    func segments(
        in treeStore: FileTreeStore,
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
    @Published private(set) var isLayoutPending = false
    @Published private(set) var layoutError: ChartLayoutFailure?

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

    @discardableResult
    func loadLayout(
        treeStore: FileTreeStore,
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
        setLayoutError(nil)
        setIsLayoutPending(true)

        switch await layoutRequests.outcome(for: request) {
        case let .success(segments):
            apply(segments)
            setIsLayoutPending(false)
            return true
        case let .failure(error):
            setLayoutError(error)
            setIsLayoutPending(false)
            return false
        case .cancelled:
            setIsLayoutPending(false)
            return false
        case .superseded:
            return false
        }
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

    private func setIsLayoutPending(_ isPending: Bool) {
        guard isLayoutPending != isPending else { return }
        isLayoutPending = isPending
    }

    private func setLayoutError(_ error: ChartLayoutFailure?) {
        guard layoutError != error else { return }
        layoutError = error
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
