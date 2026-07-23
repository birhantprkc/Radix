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

    func keyboardSelection(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection
    ) -> SunburstSegment? {
        let selectableSegments = renderedSegments.filter { segment in
            guard let nodeID = segment.nodeID else { return false }
            return !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID)
        }
        guard let selectedNodeID,
              let current = selectableSegments.first(where: {
                  $0.nodeID == selectedNodeID
              }) else {
            return firstTopLevelSegment(in: selectableSegments)
        }

        switch direction {
        case .left, .right:
            return adjacentSegment(
                to: current,
                moving: direction,
                among: selectableSegments
            )
        case .up:
            return segment(
                atSameAngleAs: current,
                depthOffset: -1,
                among: selectableSegments
            )
        case .down:
            return segment(
                atSameAngleAs: current,
                depthOffset: 1,
                among: selectableSegments
            )
        }
    }

    func keyboardSelectionPoint(
        for segment: SunburstSegment,
        in frame: CGRect
    ) -> CGPoint {
        let angle = ((segment.startAngle.radians + segment.endAngle.radians) / 2)
            - (.pi / 2)
        let normalizedRadius = (segment.innerRadius + segment.outerRadius) / 2
        let radius = min(frame.width, frame.height) / 2
        return CGPoint(
            x: frame.midX + (cos(angle) * normalizedRadius * radius),
            y: frame.midY + (sin(angle) * normalizedRadius * radius)
        )
    }

    private func firstTopLevelSegment(
        in segments: [SunburstSegment]
    ) -> SunburstSegment? {
        guard let minimumDepth = segments.map(\.depth).min() else { return nil }
        return ordered(segments.filter { $0.depth == minimumDepth }).first
    }

    private func adjacentSegment(
        to current: SunburstSegment,
        moving direction: ChartSpatialSelectionDirection,
        among segments: [SunburstSegment]
    ) -> SunburstSegment? {
        let ring = ordered(segments.filter { $0.depth == current.depth })
        guard ring.count > 1,
              let currentIndex = ring.firstIndex(where: {
                  $0.nodeID == current.nodeID
              }) else {
            return nil
        }

        switch direction {
        case .left:
            return ring[(currentIndex - 1 + ring.count) % ring.count]
        case .right:
            return ring[(currentIndex + 1) % ring.count]
        case .up, .down:
            return nil
        }
    }

    private func segment(
        atSameAngleAs current: SunburstSegment,
        depthOffset: Int,
        among segments: [SunburstSegment]
    ) -> SunburstSegment? {
        let targetDepth = current.depth + depthOffset
        guard targetDepth >= 0 else { return nil }
        let midpoint = angularMidpoint(of: current)
        return ordered(segments
            .filter {
                $0.depth == targetDepth
                    && contains(angle: midpoint, in: $0)
            })
            .first
    }

    private func ordered(_ segments: [SunburstSegment]) -> [SunburstSegment] {
        segments.sorted {
            if $0.startAngle.radians != $1.startAngle.radians {
                return $0.startAngle.radians < $1.startAngle.radians
            }
            return $0.id < $1.id
        }
    }

    private func angularMidpoint(of segment: SunburstSegment) -> Double {
        (segment.startAngle.radians + segment.endAngle.radians) / 2
    }

    private func contains(angle: Double, in segment: SunburstSegment) -> Bool {
        let tolerance = 0.000_000_001
        return angle >= segment.startAngle.radians - tolerance
            && angle <= segment.endAngle.radians + tolerance
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
