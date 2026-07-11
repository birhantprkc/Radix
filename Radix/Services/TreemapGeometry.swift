//
//  TreemapGeometry.swift
//  Radix
//

import CoreGraphics
import Foundation

struct TreemapSegment: Identifiable, Hashable, Sendable {
    let id: String
    let nodeID: String?
    let label: String
    /// A unit-space rectangle. The renderer scales it to the current chart size.
    let rect: CGRect
    let depth: Int
    let colorToken: SunburstColorToken
    let totalSize: Int64
    let isAggregate: Bool
    let isDirectory: Bool
    let showsContainerHeader: Bool
}

enum TreemapLayout {
    private nonisolated static let containerInset: CGFloat = 2
    private nonisolated static let containerHeaderHeight: CGFloat = 18
    private nonisolated static let minimumContainerWidth: CGFloat = 52
    private nonisolated static let minimumContainerHeight: CGFloat = 46

    typealias CancellationCheck = () throws -> Void

    nonisolated static func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        minimumTileArea: CGFloat = 120
    ) -> [TreemapSegment] {
        (try? segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            size: size,
            minimumTileArea: minimumTileArea,
            cancellationCheck: {}
        )) ?? []
    }

    nonisolated static func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        minimumTileArea: CGFloat = 120,
        cancellationCheck: CancellationCheck
    ) throws -> [TreemapSegment] {
        guard depthLimit > 0, size.width > 0, size.height > 0 else { return [] }
        try cancellationCheck()
        guard let root = treeStore.node(id: rootID) else { return [] }

        let rootChildren = try treeStore.children(of: root.id, cancellationCheck: cancellationCheck)
        let visibleChildren = rootChildren.isEmpty ? [root] : rootChildren
        let rootBounds = CGRect(origin: .zero, size: size)
        let colorBranchContext = ColorBranchContext(rootChildIDs: rootColorBranchIDs(in: treeStore))

        var result: [TreemapSegment] = []
        try appendSegments(
            in: treeStore,
            children: visibleChildren,
            parentID: root.id,
            bounds: rootBounds,
            rootSize: size,
            depth: 0,
            depthLimit: depthLimit,
            branchContext: nil,
            colorBranchContext: colorBranchContext,
            minimumTileArea: max(minimumTileArea, 1),
            cancellationCheck: cancellationCheck,
            into: &result
        )
        return result
    }

    private nonisolated static func appendSegments(
        in treeStore: FileTreeStore,
        children: [FileNodeRecord],
        parentID: String,
        bounds: CGRect,
        rootSize: CGSize,
        depth: Int,
        depthLimit: Int,
        branchContext: ColorBranch?,
        colorBranchContext: ColorBranchContext,
        minimumTileArea: CGFloat,
        cancellationCheck: CancellationCheck,
        into segments: inout [TreemapSegment]
    ) throws {
        guard depth < depthLimit, bounds.width > 0, bounds.height > 0 else { return }
        try cancellationCheck()

        let entries = try groupedChildren(
            children,
            parentID: parentID,
            bounds: bounds,
            minimumTileArea: minimumTileArea,
            cancellationCheck: cancellationCheck
        )
        let tiles = try squarifiedTiles(
            for: entries,
            in: bounds,
            cancellationCheck: cancellationCheck
        )
        let siblingIndexes = colorableIndexes(for: entries)
        let siblingCount = max(siblingIndexes.count, 1)

        for tile in tiles {
            try cancellationCheck()
            let entry = tile.entry
            let siblingIndex = siblingIndexes[entry.id] ?? 0
            let branch = branchContext ?? colorBranch(
                for: entry,
                in: treeStore,
                context: colorBranchContext,
                fallbackIndex: siblingIndex,
                fallbackCount: siblingCount
            )

            let childNodes: [FileNodeRecord]
            if let node = entry.node,
               node.isDirectory,
               depth + 1 < depthLimit {
                childNodes = try treeStore.children(of: node.id, cancellationCheck: cancellationCheck)
            } else {
                childNodes = []
            }

            let childBounds = childContentBounds(in: tile.rect)
            let showsContainerHeader = !childNodes.isEmpty && childBounds != nil
            let colorToken = SunburstColorToken(
                branchID: branch.id,
                localID: entry.colorID,
                branchIndex: branch.index,
                branchCount: branch.count,
                siblingIndex: siblingIndex,
                siblingCount: siblingCount,
                depth: depth,
                role: colorRole(for: entry)
            )
            segments.append(TreemapSegment(
                id: entry.id,
                nodeID: entry.nodeID,
                label: entry.label,
                rect: normalized(tile.rect, in: rootSize),
                depth: depth,
                colorToken: colorToken,
                totalSize: entry.totalSize,
                isAggregate: entry.isAggregate,
                isDirectory: entry.node?.isDirectory == true,
                showsContainerHeader: showsContainerHeader
            ))

            if let node = entry.node,
               let childBounds,
               !childNodes.isEmpty {
                try appendSegments(
                    in: treeStore,
                    children: childNodes,
                    parentID: node.id,
                    bounds: childBounds,
                    rootSize: rootSize,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    branchContext: branch,
                    colorBranchContext: colorBranchContext,
                    minimumTileArea: minimumTileArea,
                    cancellationCheck: cancellationCheck,
                    into: &segments
                )
            }
        }
    }

    private nonisolated static func groupedChildren(
        _ children: [FileNodeRecord],
        parentID: String,
        bounds: CGRect,
        minimumTileArea: CGFloat,
        cancellationCheck: CancellationCheck
    ) throws -> [Entry] {
        guard children.count > 1 else {
            return children.map(Entry.init(node:))
        }

        var totalWeight = 0.0
        for child in children {
            try cancellationCheck()
            totalWeight += Double(max(child.allocatedSize, 1))
        }
        let availableArea = max(bounds.width * bounds.height, 1)
        var visible: [Entry] = []
        var grouped: [FileNodeRecord] = []
        var groupedSize: Int64 = 0

        for child in children {
            try cancellationCheck()
            let size = max(child.allocatedSize, 1)
            let projectedArea = availableArea * CGFloat(Double(size) / max(totalWeight, 1))
            if projectedArea < minimumTileArea {
                grouped.append(child)
                groupedSize = addingClamped(groupedSize, size)
            } else {
                visible.append(Entry(node: child))
            }
        }

        if grouped.count > 1 {
            visible.append(Entry(
                id: "treemap-aggregate-\(parentID)",
                nodeID: nil,
                label: "Smaller Items",
                totalSize: groupedSize,
                isAggregate: true,
                colorID: "treemap-aggregate-\(parentID)",
                node: nil
            ))
        } else if let onlyGrouped = grouped.first {
            visible.append(Entry(node: onlyGrouped))
        }

        return visible
    }

    private nonisolated static func squarifiedTiles(
        for entries: [Entry],
        in bounds: CGRect,
        cancellationCheck: CancellationCheck
    ) throws -> [Tile] {
        guard !entries.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let totalWeight = entries.reduce(0.0) { total, entry in
            total + Double(max(entry.totalSize, 1))
        }
        let scale = Double(bounds.width * bounds.height) / max(totalWeight, 1)
        let weightedEntries = entries.map {
            WeightedEntry(entry: $0, area: CGFloat(Double(max($0.totalSize, 1)) * scale))
        }
        var nextEntryIndex = 0
        var remainingBounds = bounds
        var row: [WeightedEntry] = []
        var result: [Tile] = []

        while nextEntryIndex < weightedEntries.count {
            try cancellationCheck()
            let next = weightedEntries[nextEntryIndex]
            let shortSide = min(remainingBounds.width, remainingBounds.height)
            if row.isEmpty || worstAspectRatio(for: row + [next], shortSide: shortSide)
                <= worstAspectRatio(for: row, shortSide: shortSide) {
                row.append(next)
                nextEntryIndex += 1
            } else {
                remainingBounds = layoutRow(row, in: remainingBounds, into: &result)
                row.removeAll(keepingCapacity: true)
            }
        }

        if !row.isEmpty {
            _ = layoutRow(row, in: remainingBounds, into: &result)
        }

        return result
    }

    private nonisolated static func worstAspectRatio(
        for row: [WeightedEntry],
        shortSide: CGFloat
    ) -> CGFloat {
        guard !row.isEmpty, shortSide > 0 else { return .infinity }
        let sum = row.reduce(CGFloat(0)) { $0 + $1.area }
        let maximum = row.reduce(CGFloat(0)) { max($0, $1.area) }
        let minimum = row.reduce(CGFloat.greatestFiniteMagnitude) { min($0, $1.area) }
        guard sum > 0, minimum > 0 else { return .infinity }

        let sumSquared = sum * sum
        let sideSquared = shortSide * shortSide
        return max(
            (sideSquared * maximum) / sumSquared,
            sumSquared / (sideSquared * minimum)
        )
    }

    @discardableResult
    private nonisolated static func layoutRow(
        _ row: [WeightedEntry],
        in bounds: CGRect,
        into result: inout [Tile]
    ) -> CGRect {
        guard !row.isEmpty, bounds.width > 0, bounds.height > 0 else { return bounds }
        let rowArea = row.reduce(CGFloat(0)) { $0 + $1.area }

        if bounds.width >= bounds.height {
            let columnWidth = min(rowArea / bounds.height, bounds.width)
            var cursorY = bounds.minY
            for (index, weightedEntry) in row.enumerated() {
                let height = index == row.count - 1
                    ? max(bounds.maxY - cursorY, 0)
                    : min(weightedEntry.area / max(columnWidth, .leastNonzeroMagnitude), bounds.maxY - cursorY)
                result.append(Tile(
                    entry: weightedEntry.entry,
                    rect: CGRect(x: bounds.minX, y: cursorY, width: columnWidth, height: height)
                ))
                cursorY += height
            }
            return CGRect(
                x: bounds.minX + columnWidth,
                y: bounds.minY,
                width: max(bounds.width - columnWidth, 0),
                height: bounds.height
            )
        }

        let rowHeight = min(rowArea / bounds.width, bounds.height)
        var cursorX = bounds.minX
        for (index, weightedEntry) in row.enumerated() {
            let width = index == row.count - 1
                ? max(bounds.maxX - cursorX, 0)
                : min(weightedEntry.area / max(rowHeight, .leastNonzeroMagnitude), bounds.maxX - cursorX)
            result.append(Tile(
                entry: weightedEntry.entry,
                rect: CGRect(x: cursorX, y: bounds.minY, width: width, height: rowHeight)
            ))
            cursorX += width
        }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY + rowHeight,
            width: bounds.width,
            height: max(bounds.height - rowHeight, 0)
        )
    }

    private nonisolated static func childContentBounds(in rect: CGRect) -> CGRect? {
        guard rect.width >= minimumContainerWidth,
              rect.height >= minimumContainerHeight else {
            return nil
        }

        var content = rect.insetBy(dx: containerInset, dy: containerInset)
        content.origin.y += containerHeaderHeight
        content.size.height -= containerHeaderHeight
        guard content.width > 0, content.height > 0 else { return nil }
        return content
    }

    private nonisolated static func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }

    private nonisolated static func colorRole(for entry: Entry) -> SunburstColorRole {
        if entry.isAggregate { return .aggregate }
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(entry.nodeID) { return .freeSpace }
        return .normal
    }

    private nonisolated static func colorBranch(
        for entry: Entry,
        in treeStore: FileTreeStore,
        context: ColorBranchContext,
        fallbackIndex: Int,
        fallbackCount: Int
    ) -> ColorBranch {
        guard let branchID = topLevelBranchID(for: entry.nodeID, in: treeStore),
              let branch = context.branch(id: branchID) else {
            return ColorBranch(id: entry.colorID, index: fallbackIndex, count: fallbackCount)
        }
        return branch
    }

    private nonisolated static func rootColorBranchIDs(in treeStore: FileTreeStore) -> [String] {
        treeStore.children(of: treeStore.rootID)
            .map(\.id)
            .filter { !SunburstFreeSpaceVisualization.isFreeSpaceNodeID($0) }
    }

    private nonisolated static func topLevelBranchID(
        for nodeID: String?,
        in treeStore: FileTreeStore
    ) -> String? {
        guard let nodeID else { return nil }
        guard nodeID != treeStore.rootID else { return nodeID }

        var currentID = nodeID
        while let parentID = treeStore.parentID(of: currentID) {
            if parentID == treeStore.rootID { return currentID }
            currentID = parentID
        }
        return nodeID
    }

    private nonisolated static func colorableIndexes(for entries: [Entry]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for entry in entries where !entry.isAggregate {
            indexes[entry.id] = indexes.count
        }
        return indexes
    }

    private nonisolated static func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private nonisolated struct ColorBranch {
        let id: String
        let index: Int
        let count: Int
    }

    private nonisolated struct ColorBranchContext {
        private let indexByID: [String: Int]
        private let count: Int

        nonisolated init(rootChildIDs: [String]) {
            var indexByID: [String: Int] = [:]
            for id in rootChildIDs where indexByID[id] == nil {
                indexByID[id] = indexByID.count
            }
            self.indexByID = indexByID
            self.count = max(indexByID.count, 1)
        }

        nonisolated func branch(id: String) -> ColorBranch? {
            guard let index = indexByID[id] else { return nil }
            return ColorBranch(id: id, index: index, count: count)
        }
    }

    private nonisolated struct Entry {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let isAggregate: Bool
        let colorID: String
        let node: FileNodeRecord?

        nonisolated init(node: FileNodeRecord) {
            id = node.id
            nodeID = node.id
            label = node.name
            totalSize = max(node.allocatedSize, 1)
            isAggregate = false
            colorID = node.id
            self.node = node
        }

        nonisolated init(
            id: String,
            nodeID: String?,
            label: String,
            totalSize: Int64,
            isAggregate: Bool,
            colorID: String,
            node: FileNodeRecord?
        ) {
            self.id = id
            self.nodeID = nodeID
            self.label = label
            self.totalSize = max(totalSize, 1)
            self.isAggregate = isAggregate
            self.colorID = colorID
            self.node = node
        }
    }

    private nonisolated struct WeightedEntry {
        let entry: Entry
        let area: CGFloat
    }

    private nonisolated struct Tile {
        let entry: Entry
        let rect: CGRect
    }
}

enum TreemapRenderer {
    private nonisolated static let displayInset: CGFloat = 0.75

    nonisolated static func rect(for segment: TreemapSegment, in size: CGSize) -> CGRect {
        CGRect(
            x: segment.rect.minX * size.width,
            y: segment.rect.minY * size.height,
            width: segment.rect.width * size.width,
            height: segment.rect.height * size.height
        )
    }

    nonisolated static func displayRect(for segment: TreemapSegment, in size: CGSize) -> CGRect {
        let rect = rect(for: segment, in: size)
        let inset = min(
            displayInset,
            min(rect.width, rect.height) * 0.12
        )
        return rect.insetBy(dx: inset, dy: inset)
    }

    nonisolated static func strokeRect(
        for segment: TreemapSegment,
        in size: CGSize,
        lineWidth: CGFloat
    ) -> CGRect? {
        let displayRect = displayRect(for: segment, in: size)
        let effectiveLineWidth = max(lineWidth, 0)
        guard min(displayRect.width, displayRect.height) >= effectiveLineWidth else {
            return nil
        }

        return displayRect.insetBy(
            dx: effectiveLineWidth / 2,
            dy: effectiveLineWidth / 2
        )
    }
}

struct TreemapHitTestIndex: Sendable {
    private nonisolated static let columnCount = 32
    private nonisolated static let rowCount = 24

    private let segments: [TreemapSegment]
    private let segmentIndexesByBucket: [[Int]]

    nonisolated init(segments: [TreemapSegment]) {
        self.segments = segments
        var buckets = Array(
            repeating: [Int](),
            count: Self.columnCount * Self.rowCount
        )

        for (segmentIndex, segment) in segments.enumerated() {
            let columns = Self.bucketRange(
                minimum: segment.rect.minX,
                maximum: segment.rect.maxX,
                count: Self.columnCount
            )
            let rows = Self.bucketRange(
                minimum: segment.rect.minY,
                maximum: segment.rect.maxY,
                count: Self.rowCount
            )
            for row in rows {
                for column in columns {
                    buckets[(row * Self.columnCount) + column].append(segmentIndex)
                }
            }
        }

        for bucketIndex in buckets.indices {
            buckets[bucketIndex].sort { lhs, rhs in
                let left = segments[lhs]
                let right = segments[rhs]
                if left.depth == right.depth { return lhs > rhs }
                return left.depth > right.depth
            }
        }
        segmentIndexesByBucket = buckets
    }

    nonisolated func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        guard size.width > 0, size.height > 0 else { return nil }
        let unitPoint = CGPoint(x: point.x / size.width, y: point.y / size.height)
        guard unitPoint.x >= 0, unitPoint.x <= 1,
              unitPoint.y >= 0, unitPoint.y <= 1 else {
            return nil
        }

        let column = min(Int(unitPoint.x * CGFloat(Self.columnCount)), Self.columnCount - 1)
        let row = min(Int(unitPoint.y * CGFloat(Self.rowCount)), Self.rowCount - 1)
        let candidates = segmentIndexesByBucket[(row * Self.columnCount) + column]

        for index in candidates {
            let segment = segments[index]
            guard segment.rect.containsInclusively(unitPoint) else { continue }
            if TreemapRenderer.displayRect(for: segment, in: size).contains(point) {
                return segment
            }
        }
        return nil
    }

    private nonisolated static func bucketRange(
        minimum: CGFloat,
        maximum: CGFloat,
        count: Int
    ) -> ClosedRange<Int> {
        let lower = min(max(Int(floor(minimum * CGFloat(count))), 0), count - 1)
        let adjustedMaximum = max(maximum - CGFloat.ulpOfOne, minimum)
        let upper = min(max(Int(floor(adjustedMaximum * CGFloat(count))), 0), count - 1)
        return lower...max(lower, upper)
    }
}

private extension CGRect {
    nonisolated func containsInclusively(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
