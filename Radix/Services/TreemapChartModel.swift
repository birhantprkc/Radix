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

    private let layoutService: any TreemapLayouting
    private var layoutGeneration = 0
    private var activeLayoutID: String?
    private var layoutTask: Task<[TreemapSegment], Error>?
    private var selectionOverlayCache = TreemapSelectionOverlayCache(capacity: 8)

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

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [TreemapSelectionOverlaySegment] {
        let key = TreemapSelectionOverlayCacheKey(
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
        treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        layoutID: String
    ) async -> Bool {
        layoutGeneration += 1
        let generation = layoutGeneration
        activeLayoutID = layoutID
        layoutTask?.cancel()
        clearHover()
        setIsLayoutPending(true)

        let task = Task(priority: .userInitiated) { [layoutService] in
            try await layoutService.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit,
                size: size
            )
        }
        layoutTask = task

        do {
            let segments = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }

            layoutTask = nil
            apply(segments)
            setIsLayoutPending(false)
            return true
        } catch is CancellationError {
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }
            layoutTask = nil
            setIsLayoutPending(false)
            return false
        } catch {
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }
            layoutTask = nil
            apply([])
            setIsLayoutPending(false)
            return true
        }
    }

    private func isCurrentLayout(generation: Int, layoutID: String) -> Bool {
        layoutGeneration == generation && activeLayoutID == layoutID
    }

    private func apply(_ segments: [TreemapSegment]) {
        selectionOverlayCache.removeAll()
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
}

enum TreemapSelectionRole: Equatable, Sendable {
    case ancestor
    case selected
}

struct TreemapSelectionOverlaySegment: Identifiable, Equatable, Sendable {
    let segment: TreemapSegment
    let role: TreemapSelectionRole

    var id: TreemapSegment.ID { segment.id }
}

private struct TreemapSelectionOverlayCacheKey: Hashable {
    let renderVersion: Int
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
}

private struct TreemapSelectionOverlayCache {
    private let capacity: Int
    private var segmentsByKey: [TreemapSelectionOverlayCacheKey: [TreemapSelectionOverlaySegment]] = [:]
    private var keysByRecency: [TreemapSelectionOverlayCacheKey] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    mutating func segments(
        for key: TreemapSelectionOverlayCacheKey,
        build: () -> [TreemapSelectionOverlaySegment]
    ) -> [TreemapSelectionOverlaySegment] {
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

    private mutating func markRecentlyUsed(_ key: TreemapSelectionOverlayCacheKey) {
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

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [TreemapSelectionOverlaySegment] {
        guard let selectedNodeID else { return [] }
        var overlays: [TreemapSelectionOverlaySegment] = []

        for segment in segments {
            guard let nodeID = segment.nodeID,
                  nodeID != selectedNodeID,
                  selectedAncestorIDs.contains(nodeID) else {
                continue
            }
            overlays.append(TreemapSelectionOverlaySegment(segment: segment, role: .ancestor))
        }

        if let selectedSegment = segmentByNodeID[selectedNodeID] {
            overlays.append(TreemapSelectionOverlaySegment(segment: selectedSegment, role: .selected))
        }
        return overlays
    }
}
