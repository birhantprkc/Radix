//
//  SunburstChartModel.swift
//  Radix
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI

protocol SunburstLayouting: Sendable {
    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment]
}

actor SunburstLayoutService: SunburstLayouting {
    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        try SunburstLayout.segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            cancellationCheck: Task.checkCancellation
        )
    }
}

@MainActor
final class SunburstChartModel: ObservableObject {
    @Published private var renderState = SunburstChartRenderState()
    @Published private(set) var layoutReadiness = ChartLayoutReadiness()

    private let layoutService: any SunburstLayouting
    private let layoutRequests = ChartLayoutRequestCoordinator<[SunburstSegment]>()
    private var selectionOverlayCache = SunburstSelectionOverlayCache(capacity: 8)

    init(layoutService: any SunburstLayouting = SunburstLayoutService()) {
        self.layoutService = layoutService
    }

    var renderedSegments: [SunburstSegment] {
        renderState.segments
    }

    var hoveredSegmentID: SunburstSegment.ID? {
        renderState.hoveredSegmentID
    }

    var hoveredSegment: SunburstSegment? {
        renderState.hoveredSegment
    }

    var renderedLayoutVersion: Int {
        renderState.version
    }

    func setHoveredSegmentID(_ segmentID: SunburstSegment.ID?) {
        guard hoveredSegmentID != segmentID else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = segmentID
        renderState = nextState
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        renderState.segment(at: point, in: size)
    }

    func spatialSelectionNodeID(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection
    ) -> String? {
        spatialSelection(from: selectedNodeID, moving: direction)?.nodeID
    }

    func spatialSelection(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection
    ) -> ChartSpatialSelectionResult? {
        let selectableSegments = renderedSegments.filter { segment in
            guard let nodeID = segment.nodeID else { return false }
            return !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID)
        }
        let hasRenderedSelection = selectableSegments.contains {
            $0.nodeID == selectedNodeID
        }
        let candidateSegments: [SunburstSegment]
        if hasRenderedSelection {
            candidateSegments = selectableSegments
        } else if let minimumDepth = selectableSegments.map(\.depth).min() {
            candidateSegments = selectableSegments.filter { $0.depth == minimumDepth }
        } else {
            candidateSegments = []
        }

        let candidates = candidateSegments.compactMap { segment
            -> ChartSpatialSelectionCandidate? in
            guard let nodeID = segment.nodeID else {
                return nil
            }
            let points = spatialSelectionPoints(for: segment)
            guard !points.isEmpty else { return nil }
            return ChartSpatialSelectionCandidate(
                nodeID: nodeID,
                points: points
            )
        }
        return ChartSpatialSelection.nextSelection(
            from: selectedNodeID,
            moving: direction,
            among: candidates
        )
    }

    func spatialSelectionPoint(
        for selection: ChartSpatialSelectionResult,
        in frame: CGRect
    ) -> CGPoint {
        let radius = min(frame.width, frame.height) / 2
        return CGPoint(
            x: frame.midX + (selection.targetPoint.x * radius),
            y: frame.midY + (selection.targetPoint.y * radius)
        )
    }

    private func spatialSelectionPoints(for segment: SunburstSegment) -> [CGPoint] {
        let startAngle = segment.startAngle.radians
        let endAngle = segment.endAngle.radians
        let span = endAngle - startAngle
        guard span > 0 else { return [] }

        let endpointInset = min(span / 4, .pi / 720)
        var angles = [
            startAngle + endpointInset,
            startAngle + (span / 2),
            endAngle - endpointInset
        ]
        for cardinalAngle in stride(from: 0.0, through: .pi * 2, by: .pi / 2)
        where cardinalAngle > startAngle + endpointInset &&
            cardinalAngle < endAngle - endpointInset {
            angles.append(cardinalAngle)
        }

        let radius = (segment.innerRadius + segment.outerRadius) / 2
        var uniqueAngles: [Double] = []
        for angle in angles.sorted() where !uniqueAngles.contains(where: {
            abs($0 - angle) < 0.000_001
        }) {
            uniqueAngles.append(angle)
        }
        return uniqueAngles.map { angle in
            let displayedAngle = angle - (.pi / 2)
            return CGPoint(
                x: cos(displayedAngle) * radius,
                y: sin(displayedAngle) * radius
            )
        }
    }

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        let key = SunburstSelectionOverlayCacheKey(
            renderVersion: renderedLayoutVersion,
            selectedNodeID: selectedNodeID,
            selectedAncestorIDs: selectedAncestorIDs
        )
        return selectionOverlayCache.segments(for: key) {
            renderState.selectionOverlaySegments(
                selectedNodeID: selectedNodeID,
                selectedAncestorIDs: selectedAncestorIDs
            )
        }
    }

    @discardableResult
    func loadLayout(
        treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        layoutID: String
    ) async -> Bool {
        let request = layoutRequests.start(layoutID: layoutID) { [layoutService] in
            try await layoutService.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit
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
        layoutID: String
    ) async -> Bool {
        await loadLayout(
            treeStore: DiskMapTreeStore(treeStore),
            rootID: rootID,
            depthLimit: depthLimit,
            layoutID: layoutID
        )
    }

    private func apply(_ segments: [SunburstSegment]) {
        selectionOverlayCache.removeAll()
        renderState = SunburstChartRenderState(
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

private struct SunburstSelectionOverlayCacheKey: Hashable {
    let renderVersion: Int
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
}

private struct SunburstSelectionOverlayCache {
    private let capacity: Int
    private var segmentsByKey: [SunburstSelectionOverlayCacheKey: [SunburstSelectionOverlaySegment]] = [:]
    private var keysByRecency: [SunburstSelectionOverlayCacheKey] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    mutating func segments(
        for key: SunburstSelectionOverlayCacheKey,
        build: () -> [SunburstSelectionOverlaySegment]
    ) -> [SunburstSelectionOverlaySegment] {
        if let segments = segmentsByKey[key] {
            markRecentlyUsed(key)
            return segments
        }

        let segments = build()
        segmentsByKey[key] = segments
        markRecentlyUsed(key)
        trimToCapacity()
        return segments
    }

    mutating func removeAll() {
        segmentsByKey.removeAll()
        keysByRecency.removeAll()
    }

    private mutating func markRecentlyUsed(_ key: SunburstSelectionOverlayCacheKey) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private mutating func trimToCapacity() {
        while segmentsByKey.count > capacity, let oldestKey = keysByRecency.first {
            keysByRecency.removeFirst()
            segmentsByKey[oldestKey] = nil
        }
    }
}

enum SunburstSelectionRole: Equatable, Sendable {
    case ancestor
    case selected
}

struct SunburstSelectionOverlaySegment: Identifiable, Equatable, Sendable {
    let segment: SunburstSegment
    let role: SunburstSelectionRole

    var id: SunburstSegment.ID {
        segment.id
    }
}

private struct SunburstChartRenderState {
    var segments: [SunburstSegment]
    var hoveredSegmentID: SunburstSegment.ID?
    var version: Int

    private var segmentLookup: [SunburstSegment.ID: SunburstSegment]
    private var segmentByNodeID: [String: SunburstSegment]
    private var hitTestIndex: SunburstHitTestIndex

    init(
        segments: [SunburstSegment] = [],
        hoveredSegmentID: SunburstSegment.ID? = nil,
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
        hitTestIndex = SunburstHitTestIndex(segments: segments)
    }

    var hoveredSegment: SunburstSegment? {
        guard let hoveredSegmentID else { return nil }
        return segmentLookup[hoveredSegmentID]
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        hitTestIndex.segment(at: point, in: size)
    }

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        guard let selectedNodeID else { return [] }

        var overlaySegments: [SunburstSelectionOverlaySegment] = []
        overlaySegments.reserveCapacity(selectedAncestorIDs.count)

        for segment in segments {
            guard let nodeID = segment.nodeID,
                  nodeID != selectedNodeID,
                  selectedAncestorIDs.contains(nodeID) else {
                continue
            }

            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: segment,
                role: .ancestor
            ))
        }

        if let selectedSegment = segmentByNodeID[selectedNodeID] {
            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: selectedSegment,
                role: .selected
            ))
        }

        return overlaySegments
    }
}
