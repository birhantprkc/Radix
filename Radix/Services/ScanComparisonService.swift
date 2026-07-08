//
//  ScanComparisonService.swift
//  Radix
//

import Foundation

nonisolated struct ComparedSnapshotSummary: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let rootPath: String
    let startedAt: Date
    let finishedAt: Date?
    let sourceURL: URL?

    init(snapshot: ScanSnapshot) {
        self.id = snapshot.id
        self.displayName = snapshot.target.displayName
        self.rootPath = snapshot.target.url.path
        self.startedAt = snapshot.startedAt
        self.finishedAt = snapshot.finishedAt
        if case .imported(let context) = snapshot.source {
            self.sourceURL = context.sourceURL
        } else {
            self.sourceURL = nil
        }
    }

    var comparisonDate: Date {
        finishedAt ?? startedAt
    }
}

nonisolated enum ScanComparisonChangeKind: String, CaseIterable, Sendable {
    case added
    case removed
    case grew
    case shrank

    var title: String {
        switch self {
        case .added:
            return "Added"
        case .removed:
            return "Removed"
        case .grew:
            return "Grew"
        case .shrank:
            return "Shrank"
        }
    }

    var sortRank: Int {
        switch self {
        case .added:
            return 0
        case .removed:
            return 1
        case .grew:
            return 2
        case .shrank:
            return 3
        }
    }
}

nonisolated struct ScanComparisonSummary: Equatable, Sendable {
    let beforeAllocatedSize: Int64
    let afterAllocatedSize: Int64
    let beforeLogicalSize: Int64
    let afterLogicalSize: Int64
    let beforeFileCount: Int
    let afterFileCount: Int
    let beforeDirectoryCount: Int
    let afterDirectoryCount: Int
    let beforeWarningCount: Int
    let afterWarningCount: Int
    let addedCount: Int
    let removedCount: Int
    let grewCount: Int
    let shrankCount: Int

    init(before: ScanSnapshot, after: ScanSnapshot, rows: [ScanComparisonRow]) {
        self.beforeAllocatedSize = before.aggregateStats.totalAllocatedSize
        self.afterAllocatedSize = after.aggregateStats.totalAllocatedSize
        self.beforeLogicalSize = before.aggregateStats.totalLogicalSize
        self.afterLogicalSize = after.aggregateStats.totalLogicalSize
        self.beforeFileCount = before.aggregateStats.fileCount
        self.afterFileCount = after.aggregateStats.fileCount
        self.beforeDirectoryCount = before.aggregateStats.directoryCount
        self.afterDirectoryCount = after.aggregateStats.directoryCount
        self.beforeWarningCount = before.scanWarnings.count
        self.afterWarningCount = after.scanWarnings.count

        var counts: [ScanComparisonChangeKind: Int] = [:]
        for row in rows {
            counts[row.kind, default: 0] += 1
        }
        self.addedCount = counts[.added, default: 0]
        self.removedCount = counts[.removed, default: 0]
        self.grewCount = counts[.grew, default: 0]
        self.shrankCount = counts[.shrank, default: 0]
    }

    var allocatedDelta: Int64 {
        afterAllocatedSize - beforeAllocatedSize
    }

    var logicalDelta: Int64 {
        afterLogicalSize - beforeLogicalSize
    }

    var fileCountDelta: Int {
        afterFileCount - beforeFileCount
    }

    var directoryCountDelta: Int {
        afterDirectoryCount - beforeDirectoryCount
    }

    var warningCountDelta: Int {
        afterWarningCount - beforeWarningCount
    }

    var changedCount: Int {
        addedCount + removedCount + grewCount + shrankCount
    }
}

nonisolated struct ScanComparisonRow: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let kind: ScanComparisonChangeKind
    let beforeNode: FileNodeRecord?
    let afterNode: FileNodeRecord?
    let beforeAllocatedSize: Int64?
    let afterAllocatedSize: Int64?
    let beforeLogicalSize: Int64?
    let afterLogicalSize: Int64?
    let isDirectory: Bool
    let itemKind: String
    let beforeDescendantFileCount: Int?
    let afterDescendantFileCount: Int?
    let lastModified: Date?

    init(
        relativePath: String,
        kind: ScanComparisonChangeKind,
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) {
        let displayNode = afterNode ?? beforeNode
        self.id = "\(kind.rawValue):\(relativePath)"
        self.relativePath = relativePath
        self.name = displayNode?.name ?? URL(filePath: relativePath).lastPathComponent
        self.kind = kind
        self.beforeNode = beforeNode
        self.afterNode = afterNode
        self.beforeAllocatedSize = beforeNode?.allocatedSize
        self.afterAllocatedSize = afterNode?.allocatedSize
        self.beforeLogicalSize = beforeNode?.logicalSize
        self.afterLogicalSize = afterNode?.logicalSize
        self.isDirectory = displayNode?.isDirectory ?? false
        self.itemKind = displayNode?.itemKind ?? "Item"
        self.beforeDescendantFileCount = beforeNode?.descendantFileCount
        self.afterDescendantFileCount = afterNode?.descendantFileCount
        self.lastModified = afterNode?.lastModified ?? beforeNode?.lastModified
    }

    var allocatedDelta: Int64 {
        (afterAllocatedSize ?? 0) - (beforeAllocatedSize ?? 0)
    }

    var logicalDelta: Int64 {
        (afterLogicalSize ?? 0) - (beforeLogicalSize ?? 0)
    }

    var absoluteAllocatedDelta: Int64 {
        abs(allocatedDelta)
    }

    /// The filesystem location this row points at — the after node when present (added, grew,
    /// shrank), otherwise the before node (removed). Used for Finder reveal and path copy.
    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }
}

nonisolated struct ScanComparison: Identifiable, Equatable, Sendable {
    let id: UUID
    let before: ComparedSnapshotSummary
    let after: ComparedSnapshotSummary
    let summary: ScanComparisonSummary
    let rows: [ScanComparisonRow]

    init(beforeSnapshot: ScanSnapshot, afterSnapshot: ScanSnapshot, rows: [ScanComparisonRow]) {
        self.id = UUID()
        self.before = ComparedSnapshotSummary(snapshot: beforeSnapshot)
        self.after = ComparedSnapshotSummary(snapshot: afterSnapshot)
        self.rows = rows
        self.summary = ScanComparisonSummary(before: beforeSnapshot, after: afterSnapshot, rows: rows)
    }
}

nonisolated struct ScanComparisonService: Sendable {
    func compare(before: ScanSnapshot, after: ScanSnapshot) async throws -> ScanComparison {
        try Task.checkCancellation()
        let beforeNodes = try Self.indexedNodes(in: before)
        let afterNodes = try Self.indexedNodes(in: after)
        try Task.checkCancellation()

        var rows: [ScanComparisonRow] = []
        let beforePaths = Set(beforeNodes.keys)
        let afterPaths = Set(afterNodes.keys)
        let addedPaths = afterPaths.subtracting(beforePaths)
        let removedPaths = beforePaths.subtracting(afterPaths)
        let sharedPaths = beforePaths.intersection(afterPaths)

        rows.reserveCapacity(addedPaths.count + removedPaths.count + sharedPaths.count)

        for relativePath in addedPaths where !Self.hasAncestor(of: relativePath, in: addedPaths) {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: .added,
                beforeNode: nil,
                afterNode: afterNodes[relativePath]
            ))
        }

        for relativePath in removedPaths where !Self.hasAncestor(of: relativePath, in: removedPaths) {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: .removed,
                beforeNode: beforeNodes[relativePath],
                afterNode: nil
            ))
        }

        for relativePath in sharedPaths {
            try Task.checkCancellation()
            guard let beforeNode = beforeNodes[relativePath],
                  let afterNode = afterNodes[relativePath] else {
                continue
            }
            // A directory whose allocated size is the aggregate of indexed descendants has
            // its grew/shrank delta already accounted for by the leaf rows beneath it, so
            // emitting the directory too would spam a redundant row for every ancestor of
            // every changed file. But a leaf-like directory — an auto-summarized subtree or
            // a package collapsed to a single node — has no indexed children and therefore
            // no descendant rows, so its change must be reported here or it becomes invisible.
            let isRedundantDirectory = beforeNode.isDirectory && afterNode.isDirectory
                && before.treeStore.containsChildren(id: beforeNode.id)
                && after.treeStore.containsChildren(id: afterNode.id)
            guard !isRedundantDirectory else { continue }
            let delta = afterNode.allocatedSize - beforeNode.allocatedSize
            guard delta != 0 else { continue }
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: delta > 0 ? .grew : .shrank,
                beforeNode: beforeNode,
                afterNode: afterNode
            ))
        }

        try Task.checkCancellation()
        let sortedRows = rows.sorted { lhs, rhs in
            ScanComparisonRowComparator.defaultOrder.compare(lhs, rhs) == .orderedAscending
        }
        return ScanComparison(beforeSnapshot: before, afterSnapshot: after, rows: sortedRows)
    }

    private static func indexedNodes(in snapshot: ScanSnapshot) throws -> [String: FileNodeRecord] {
        var nodesByRelativePath: [String: FileNodeRecord] = [:]
        nodesByRelativePath.reserveCapacity(max(snapshot.treeStore.nodeCount - 1, 0))

        try snapshot.treeStore.forEachIndexedNodeID(excludingRoot: true) { nodeID in
            try Task.checkCancellation()
            guard let node = snapshot.treeStore.node(id: nodeID),
                  let relativePath = Self.relativePath(for: node.id, rootID: snapshot.treeStore.rootID) else {
                return
            }
            nodesByRelativePath[relativePath] = node
        }

        return nodesByRelativePath
    }

    static func relativePath(for nodeID: String, rootID: String) -> String? {
        guard nodeID != rootID else { return nil }

        if rootID == "/" {
            let relativePath = nodeID.trimmingPrefix("/")
            return relativePath.isEmpty ? nil : relativePath
        }

        let rootPrefix = rootID.hasSuffix("/") ? rootID : rootID + "/"
        guard nodeID.hasPrefix(rootPrefix) else { return nil }
        let relativePath = String(nodeID.dropFirst(rootPrefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    private static func hasAncestor(of relativePath: String, in paths: Set<String>) -> Bool {
        var cursor = relativePath
        while let slashIndex = cursor.lastIndex(of: "/") {
            cursor = String(cursor[..<slashIndex])
            if paths.contains(cursor) {
                return true
            }
        }
        return false
    }
}

nonisolated struct ScanComparisonRowComparator: Equatable, SortComparator, Sendable {
    enum Field: Equatable, Sendable {
        case changeKind
        case relativePath
        case beforeAllocatedSize
        case afterAllocatedSize
        case allocatedDelta
        case absoluteAllocatedDelta
        case itemKind
    }

    static let defaultOrder = ScanComparisonRowComparator(field: .absoluteAllocatedDelta, order: .reverse)

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: ScanComparisonRow, _ rhs: ScanComparisonRow) -> ComparisonResult {
        let result: ComparisonResult = switch field {
        case .changeKind:
            FileNodeSortComparison.compare(lhs.kind.sortRank, rhs.kind.sortRank)
        case .relativePath:
            lhs.relativePath.localizedStandardCompare(rhs.relativePath)
        case .beforeAllocatedSize:
            FileNodeSortComparison.compareOptional(lhs.beforeAllocatedSize, rhs.beforeAllocatedSize)
        case .afterAllocatedSize:
            FileNodeSortComparison.compareOptional(lhs.afterAllocatedSize, rhs.afterAllocatedSize)
        case .allocatedDelta:
            FileNodeSortComparison.compare(lhs.allocatedDelta, rhs.allocatedDelta)
        case .absoluteAllocatedDelta:
            FileNodeSortComparison.compare(lhs.absoluteAllocatedDelta, rhs.absoluteAllocatedDelta)
        case .itemKind:
            lhs.itemKind.localizedStandardCompare(rhs.itemKind)
        }

        let orderedResult = FileNodeSortComparison.applying(order, to: result)
        switch orderedResult {
        case .orderedSame:
            return FileNodeSortComparison.fallback(
                lhsName: lhs.name,
                lhsID: lhs.relativePath,
                rhsName: rhs.name,
                rhsID: rhs.relativePath
            )
        default:
            return orderedResult
        }
    }
}

private nonisolated extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
