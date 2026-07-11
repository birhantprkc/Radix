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

nonisolated enum ScanComparisonChangeKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case added
    case removed
    case grew
    case shrank
    case moved

    var id: String { rawValue }

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
        case .moved:
            return "Moved"
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
        case .moved:
            return 4
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
    let movedCount: Int
    /// Sum of positive allocated deltas represented by the final, non-overlapping rows.
    let grossIncreasedAllocatedSize: Int64
    /// Sum of reclaimed allocated bytes represented by the final, non-overlapping rows.
    let grossReclaimedAllocatedSize: Int64

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
        var grossIncreasedAllocatedSize: Int64 = 0
        var grossReclaimedAllocatedSize: Int64 = 0
        for row in rows {
            counts[row.kind, default: 0] += 1
            if row.allocatedDelta > 0 {
                grossIncreasedAllocatedSize += row.allocatedDelta
            } else if row.allocatedDelta < 0 {
                grossReclaimedAllocatedSize += -row.allocatedDelta
            }
        }
        self.addedCount = counts[.added, default: 0]
        self.removedCount = counts[.removed, default: 0]
        self.grewCount = counts[.grew, default: 0]
        self.shrankCount = counts[.shrank, default: 0]
        self.movedCount = counts[.moved, default: 0]
        self.grossIncreasedAllocatedSize = grossIncreasedAllocatedSize
        self.grossReclaimedAllocatedSize = grossReclaimedAllocatedSize
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

    /// Items at the same relative path in both scans whose tracked size changed.
    var changedCount: Int {
        grewCount + shrankCount
    }

    /// Net allocated change that can be attributed to final comparison rows.
    ///
    /// This can differ from `allocatedDelta` when incomplete scan coverage suppresses uncertain
    /// additions or removals.
    var attributedAllocatedDelta: Int64 {
        grossIncreasedAllocatedSize - grossReclaimedAllocatedSize
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
    /// The former relative path for an unambiguous file move or rename.
    ///
    /// A non-`nil` value is only produced when the same `FileIdentity` appears exactly once
    /// among the visible removed paths and exactly once among the visible added paths.
    let movedFromRelativePath: String?

    init(
        relativePath: String,
        kind: ScanComparisonChangeKind,
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?,
        beforeAllocatedSize: Int64? = nil,
        afterAllocatedSize: Int64? = nil,
        movedFromRelativePath: String? = nil
    ) {
        let displayNode = afterNode ?? beforeNode
        self.id = if let movedFromRelativePath {
            "\(kind.rawValue):\(movedFromRelativePath)->\(relativePath)"
        } else {
            "\(kind.rawValue):\(relativePath)"
        }
        self.relativePath = relativePath
        self.name = displayNode?.name ?? URL(filePath: relativePath).lastPathComponent
        self.kind = kind
        self.beforeNode = beforeNode
        self.afterNode = afterNode
        self.beforeAllocatedSize = beforeNode.map { beforeAllocatedSize ?? $0.allocatedSize }
        self.afterAllocatedSize = afterNode.map { afterAllocatedSize ?? $0.allocatedSize }
        self.beforeLogicalSize = beforeNode?.logicalSize
        self.afterLogicalSize = afterNode?.logicalSize
        self.isDirectory = displayNode?.isDirectory ?? false
        self.itemKind = displayNode?.itemKind ?? "Item"
        self.beforeDescendantFileCount = beforeNode?.descendantFileCount
        self.afterDescendantFileCount = afterNode?.descendantFileCount
        self.lastModified = afterNode?.lastModified ?? beforeNode?.lastModified
        self.movedFromRelativePath = movedFromRelativePath
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

/// A non-overlapping, top-level attribution of the comparison rows.
///
/// Each final comparison row belongs to exactly one location: its first relative-path
/// component. This lets the UI rank locations without summing a directory and its changed
/// descendants twice. A move belongs to its destination location.
nonisolated struct ScanComparisonLocationChange: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let allocatedDelta: Int64
    let increasedAllocatedSize: Int64
    let reclaimedAllocatedSize: Int64
    let addedCount: Int
    let removedCount: Int
    let grewCount: Int
    let shrankCount: Int
    let movedCount: Int
    /// A changed row within this location, chosen by the largest absolute allocated delta.
    let representativeRelativePath: String
    /// The node at `relativePath` in the before snapshot, when it was indexed.
    let beforeNode: FileNodeRecord?
    /// The node at `relativePath` in the after snapshot, when it was indexed.
    let afterNode: FileNodeRecord?

    /// Non-overlapping comparison rows attributed to this location.
    var affectedCount: Int {
        addedCount + removedCount + grewCount + shrankCount + movedCount
    }

    var absoluteAllocatedDelta: Int64 {
        abs(allocatedDelta)
    }

    var grossChangedAllocatedSize: Int64 {
        increasedAllocatedSize + reclaimedAllocatedSize
    }

    /// Prefer the current node so an overview can navigate to the location in the active scan.
    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }
}

/// Inclusive change totals for one path in the comparison hierarchy.
///
/// Every final, non-overlapping evidence row contributes to each of its path ancestors. Growth
/// and reclamation remain separate so a high-churn, zero-net folder cannot disappear.
nonisolated struct ScanComparisonAggregateChange: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let parentPath: String?
    let childPaths: [String]
    let directRowID: ScanComparisonRow.ID?
    let representativeRowID: ScanComparisonRow.ID
    let beforeNode: FileNodeRecord?
    let afterNode: FileNodeRecord?
    let increasedAllocatedSize: Int64
    let reclaimedAllocatedSize: Int64
    let addedCount: Int
    let removedCount: Int
    let grewCount: Int
    let shrankCount: Int
    let movedCount: Int
    let increasedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64]
    let reclaimedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64]

    var allocatedDelta: Int64 {
        increasedAllocatedSize - reclaimedAllocatedSize
    }

    var grossChangedAllocatedSize: Int64 {
        increasedAllocatedSize + reclaimedAllocatedSize
    }

    var affectedCount: Int {
        addedCount + removedCount + grewCount + shrankCount + movedCount
    }

    var isDirectory: Bool {
        (afterNode ?? beforeNode)?.isDirectory ?? !childPaths.isEmpty
    }

    var itemKind: String {
        (afterNode ?? beforeNode)?.itemKind ?? (isDirectory ? "Folder" : "Item")
    }

    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }

    func changeCount(for kind: ScanComparisonChangeKind) -> Int {
        switch kind {
        case .added: addedCount
        case .removed: removedCount
        case .grew: grewCount
        case .shrank: shrankCount
        case .moved: movedCount
        }
    }

    func includes(any changeKinds: Set<ScanComparisonChangeKind>) -> Bool {
        changeKinds.contains { changeCount(for: $0) > 0 }
    }

    func increasedAllocatedSize(for changeKinds: Set<ScanComparisonChangeKind>) -> Int64 {
        changeKinds.reduce(0) { $0 + increasedAllocatedSizeByKind[$1, default: 0] }
    }

    func reclaimedAllocatedSize(for changeKinds: Set<ScanComparisonChangeKind>) -> Int64 {
        changeKinds.reduce(0) { $0 + reclaimedAllocatedSizeByKind[$1, default: 0] }
    }

    func impact(for kind: ScanComparisonChangeKind) -> Int64 {
        if kind == .moved {
            return Int64(movedCount)
        }
        return increasedAllocatedSizeByKind[kind, default: 0]
            + reclaimedAllocatedSizeByKind[kind, default: 0]
    }

    func impact(for changeKinds: Set<ScanComparisonChangeKind>) -> Int64 {
        let storageKinds = changeKinds.subtracting([.moved])
        if !storageKinds.isEmpty {
            return storageKinds.reduce(0) { $0 + impact(for: $1) }
        }
        return changeKinds.contains(.moved) ? Int64(movedCount) : 0
    }
}

/// A compact graph of aggregate comparison paths. The service stores the graph rather than a
/// recursive value tree so huge comparisons don't duplicate nested arrays for every UI facet.
nonisolated struct ScanComparisonChangeTree: Equatable, Sendable {
    let rootPaths: [String]
    let nodesByPath: [String: ScanComparisonAggregateChange]

    static let empty = ScanComparisonChangeTree(rootPaths: [], nodesByPath: [:])

    func node(at relativePath: String) -> ScanComparisonAggregateChange? {
        nodesByPath[relativePath]
    }

    func significantProjection(
        changeKinds: Set<ScanComparisonChangeKind>,
        coverageTarget: Double = 0.95,
        maximumNamedChildren: Int = 12
    ) -> ScanComparisonChangeTreeProjection {
        let target = min(max(coverageTarget, 0), 1)
        let maximum = max(1, maximumNamedChildren)
        let rootSelection = significantSelection(
            from: rootPaths,
            changeKinds: changeKinds,
            coverageTarget: target,
            maximumNamedChildren: maximum
        )
        let roots = projectedNodes(
            selectedPaths: rootSelection.selected,
            hiddenPaths: rootSelection.hidden,
            parentPath: nil,
            changeKinds: changeKinds,
            coverageTarget: target,
            maximumNamedChildren: maximum
        )

        return ScanComparisonChangeTreeProjection(
            roots: roots,
            changeKinds: changeKinds,
            namedRootCount: rootSelection.selected.count,
            hiddenRootCount: rootSelection.hidden.count,
            representedImpact: rootSelection.representedImpact,
            totalImpact: rootSelection.totalImpact,
            groupedAffectedCount: roots.reduce(0) { partialResult, node in
                partialResult + node.groupedAffectedCount
            }
        )
    }

    private func projectedNodes(
        selectedPaths: [String],
        hiddenPaths: [String],
        parentPath: String?,
        changeKinds: Set<ScanComparisonChangeKind>,
        coverageTarget: Double,
        maximumNamedChildren: Int
    ) -> [ScanComparisonChangeTreeNode] {
        var projected = selectedPaths.compactMap { path -> ScanComparisonChangeTreeNode? in
            guard let aggregate = nodesByPath[path] else { return nil }
            let eligibleChildren = aggregate.childPaths.filter { childPath in
                guard let child = nodesByPath[childPath] else { return false }
                return child.includes(any: changeKinds)
            }
            let selection = significantSelection(
                from: eligibleChildren,
                changeKinds: changeKinds,
                coverageTarget: coverageTarget,
                maximumNamedChildren: maximumNamedChildren
            )
            let children = projectedNodes(
                selectedPaths: selection.selected,
                hiddenPaths: selection.hidden,
                parentPath: path,
                changeKinds: changeKinds,
                coverageTarget: coverageTarget,
                maximumNamedChildren: maximumNamedChildren
            )
            return ScanComparisonChangeTreeNode(
                aggregate: aggregate,
                changeKinds: changeKinds,
                children: children
            )
        }

        if !hiddenPaths.isEmpty {
            let hiddenNodes = hiddenPaths.compactMap { nodesByPath[$0] }
            projected.append(ScanComparisonChangeTreeNode.remainder(
                parentPath: parentPath,
                changeKinds: changeKinds,
                hiddenNodes: hiddenNodes
            ))
        }
        return projected
    }

    private func significantSelection(
        from paths: [String],
        changeKinds: Set<ScanComparisonChangeKind>,
        coverageTarget: Double,
        maximumNamedChildren: Int
    ) -> SignificantSelection {
        let eligible = paths.compactMap { path -> ScanComparisonAggregateChange? in
            guard let node = nodesByPath[path], node.includes(any: changeKinds) else { return nil }
            return node
        }
        guard !eligible.isEmpty else {
            return SignificantSelection(selected: [], hidden: [], representedImpact: 0, totalImpact: 0)
        }

        var selectedIDs = Set<String>()
        for kind in changeKinds {
            var selectedForKind = selectForCoverage(
                eligible,
                value: { $0.impact(for: kind) },
                coverageTarget: coverageTarget,
                maximumCount: maximumNamedChildren
            )
            if selectedForKind.isEmpty {
                selectedForKind = selectForCoverage(
                    eligible,
                    value: { Int64($0.changeCount(for: kind)) },
                    coverageTarget: coverageTarget,
                    maximumCount: maximumNamedChildren
                )
            }
            selectedIDs.formUnion(selectedForKind)
        }

        let ranked = eligible.map { node in
            (
                node: node,
                impact: node.impact(for: changeKinds),
                changeCount: Int64(changeKinds.reduce(0) { $0 + node.changeCount(for: $1) })
            )
        }.sorted { lhs, rhs in
            if lhs.impact != rhs.impact { return lhs.impact > rhs.impact }
            if lhs.node.grossChangedAllocatedSize != rhs.node.grossChangedAllocatedSize {
                return lhs.node.grossChangedAllocatedSize > rhs.node.grossChangedAllocatedSize
            }
            return lhs.node.relativePath.localizedStandardCompare(rhs.node.relativePath) == .orderedAscending
        }

        var selected: [String] = []
        var hidden: [String] = []
        let selectedCapacity = min(selectedIDs.count, ranked.count)
        selected.reserveCapacity(selectedCapacity)
        hidden.reserveCapacity(ranked.count - selectedCapacity)
        var totalImpact: Int64 = 0
        var representedImpact: Int64 = 0
        var totalChangeCount: Int64 = 0
        var representedChangeCount: Int64 = 0
        for entry in ranked {
            let isSelected = selectedIDs.contains(entry.node.id)
            if isSelected {
                selected.append(entry.node.relativePath)
            } else {
                hidden.append(entry.node.relativePath)
            }
            totalImpact += entry.impact
            totalChangeCount += entry.changeCount
            if isSelected {
                representedImpact += entry.impact
                representedChangeCount += entry.changeCount
            }
        }
        if totalImpact == 0 {
            totalImpact = totalChangeCount
            representedImpact = representedChangeCount
        }
        return SignificantSelection(
            selected: selected,
            hidden: hidden,
            representedImpact: representedImpact,
            totalImpact: totalImpact
        )
    }

    private func selectForCoverage(
        _ nodes: [ScanComparisonAggregateChange],
        value: (ScanComparisonAggregateChange) -> Int64,
        coverageTarget: Double,
        maximumCount: Int
    ) -> Set<String> {
        let sorted = nodes.compactMap { node -> (node: ScanComparisonAggregateChange, value: Int64)? in
            let nodeValue = value(node)
            return nodeValue > 0 ? (node, nodeValue) : nil
        }.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.node.relativePath.localizedStandardCompare(rhs.node.relativePath) == .orderedAscending
        }
        let total = sorted.reduce(Double(0)) { $0 + Double($1.value) }
        guard total > 0 else { return [] }
        let target = total * coverageTarget
        var represented = Double(0)
        var selected = Set<String>()
        for entry in sorted {
            guard selected.count < maximumCount, represented < target else { break }
            selected.insert(entry.node.id)
            represented += Double(entry.value)
        }
        return selected
    }

    private struct SignificantSelection {
        let selected: [String]
        let hidden: [String]
        let representedImpact: Int64
        let totalImpact: Int64
    }
}

/// A small recursive projection intended for the Significant UI. Hidden siblings are represented
/// by one synthetic remainder instead of retaining thousands of invisible descendants.
nonisolated struct ScanComparisonChangeTreeNode: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let increasedAllocatedSize: Int64
    let reclaimedAllocatedSize: Int64
    let allocatedDelta: Int64
    let affectedCount: Int
    let movedCount: Int
    let beforeNode: FileNodeRecord?
    let afterNode: FileNodeRecord?
    let directRowID: ScanComparisonRow.ID?
    let isDirectory: Bool
    let isRemainder: Bool
    let groupedAffectedCount: Int
    let children: [ScanComparisonChangeTreeNode]?

    init(
        aggregate: ScanComparisonAggregateChange,
        changeKinds: Set<ScanComparisonChangeKind>,
        children: [ScanComparisonChangeTreeNode]
    ) {
        let increasedAllocatedSize = aggregate.increasedAllocatedSize(for: changeKinds)
        let reclaimedAllocatedSize = aggregate.reclaimedAllocatedSize(for: changeKinds)
        self.id = aggregate.id
        self.relativePath = aggregate.relativePath
        self.name = aggregate.name
        self.increasedAllocatedSize = increasedAllocatedSize
        self.reclaimedAllocatedSize = reclaimedAllocatedSize
        self.allocatedDelta = increasedAllocatedSize - reclaimedAllocatedSize
        self.affectedCount = changeKinds.reduce(0) { $0 + aggregate.changeCount(for: $1) }
        self.movedCount = changeKinds.contains(.moved) ? aggregate.movedCount : 0
        self.beforeNode = aggregate.beforeNode
        self.afterNode = aggregate.afterNode
        self.directRowID = aggregate.directRowID
        self.isDirectory = aggregate.isDirectory
        self.isRemainder = false
        self.groupedAffectedCount = children.reduce(0) { $0 + $1.groupedAffectedCount }
        self.children = children.isEmpty ? nil : children
    }

    private init(
        id: String,
        relativePath: String,
        name: String,
        increasedAllocatedSize: Int64,
        reclaimedAllocatedSize: Int64,
        affectedCount: Int,
        movedCount: Int,
        groupedAffectedCount: Int
    ) {
        self.id = id
        self.relativePath = relativePath
        self.name = name
        self.increasedAllocatedSize = increasedAllocatedSize
        self.reclaimedAllocatedSize = reclaimedAllocatedSize
        self.allocatedDelta = increasedAllocatedSize - reclaimedAllocatedSize
        self.affectedCount = affectedCount
        self.movedCount = movedCount
        self.beforeNode = nil
        self.afterNode = nil
        self.directRowID = nil
        self.isDirectory = false
        self.isRemainder = true
        self.groupedAffectedCount = groupedAffectedCount
        self.children = nil
    }

    static func remainder(
        parentPath: String?,
        changeKinds: Set<ScanComparisonChangeKind>,
        hiddenNodes: [ScanComparisonAggregateChange]
    ) -> ScanComparisonChangeTreeNode {
        let affectedCount = hiddenNodes.reduce(0) { partialResult, node in
            partialResult + changeKinds.reduce(0) { $0 + node.changeCount(for: $1) }
        }
        let filterID = changeKinds.map(\.rawValue).sorted().joined(separator: ",")
        return ScanComparisonChangeTreeNode(
            id: "other:\(parentPath ?? "root"):\(filterID)",
            relativePath: parentPath ?? "",
            name: "Other smaller changes",
            increasedAllocatedSize: hiddenNodes.reduce(0) {
                $0 + $1.increasedAllocatedSize(for: changeKinds)
            },
            reclaimedAllocatedSize: hiddenNodes.reduce(0) {
                $0 + $1.reclaimedAllocatedSize(for: changeKinds)
            },
            affectedCount: affectedCount,
            movedCount: changeKinds.contains(.moved)
                ? hiddenNodes.reduce(0) { $0 + $1.movedCount }
                : 0,
            groupedAffectedCount: affectedCount
        )
    }

    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }

    func node(withID id: String) -> ScanComparisonChangeTreeNode? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let match = child.node(withID: id) { return match }
        }
        return nil
    }
}

nonisolated struct ScanComparisonChangeTreeProjection: Equatable, Sendable {
    let roots: [ScanComparisonChangeTreeNode]
    let changeKinds: Set<ScanComparisonChangeKind>
    let namedRootCount: Int
    let hiddenRootCount: Int
    let representedImpact: Int64
    let totalImpact: Int64
    let groupedAffectedCount: Int

    var representedFraction: Double {
        guard totalImpact > 0 else { return 1 }
        return Double(representedImpact) / Double(totalImpact)
    }

    func node(withID id: String) -> ScanComparisonChangeTreeNode? {
        for root in roots {
            if let match = root.node(withID: id) { return match }
        }
        return nil
    }
}

nonisolated enum ScanComparisonConfidence: String, Equatable, Sendable {
    /// Both scans are complete, target the same root, use matching known options, and report
    /// no scan warnings.
    case high
    /// The comparison is usable, but warning coverage or unknown scan options limit certainty.
    case limited
    /// A fundamental mismatch means the result should be treated as forensic, not a baseline.
    case low
}

nonisolated enum ScanComparisonCoverageIssue: Hashable, Sendable {
    case differentTargets
    case differentScanOptions
    case unknownScanOptions
    case beforeIncomplete
    case afterIncomplete
    case beforeWarnings(Int)
    case afterWarnings(Int)
}

/// Facts about whether two snapshots cover comparable filesystem state.
///
/// This is deliberately descriptive rather than blocking: callers can reserve low-confidence
/// comparisons for an advanced workflow while still explaining why the result is uncertain.
nonisolated struct ScanComparisonCoverage: Equatable, Sendable {
    let confidence: ScanComparisonConfidence
    let issues: [ScanComparisonCoverageIssue]
    let beforeWarningCount: Int
    let afterWarningCount: Int
    let targetsMatch: Bool
    let scanOptionsMatch: Bool?
    let beforeIsComplete: Bool
    let afterIsComplete: Bool

    init(before: ScanSnapshot, after: ScanSnapshot) {
        self.beforeWarningCount = before.scanWarnings.count
        self.afterWarningCount = after.scanWarnings.count
        self.targetsMatch = before.target.id == after.target.id
        self.beforeIsComplete = before.isComplete
        self.afterIsComplete = after.isComplete

        switch (before.scanOptions, after.scanOptions) {
        case let (beforeOptions?, afterOptions?):
            self.scanOptionsMatch = beforeOptions == afterOptions
        default:
            self.scanOptionsMatch = nil
        }

        var issues: [ScanComparisonCoverageIssue] = []
        if !targetsMatch {
            issues.append(.differentTargets)
        }
        if scanOptionsMatch == false {
            issues.append(.differentScanOptions)
        } else if scanOptionsMatch == nil {
            issues.append(.unknownScanOptions)
        }
        if !beforeIsComplete {
            issues.append(.beforeIncomplete)
        }
        if !afterIsComplete {
            issues.append(.afterIncomplete)
        }
        if beforeWarningCount > 0 {
            issues.append(.beforeWarnings(beforeWarningCount))
        }
        if afterWarningCount > 0 {
            issues.append(.afterWarnings(afterWarningCount))
        }
        self.issues = issues

        if !targetsMatch || scanOptionsMatch == false || !beforeIsComplete || !afterIsComplete {
            self.confidence = .low
        } else if !issues.isEmpty {
            self.confidence = .limited
        } else {
            self.confidence = .high
        }
    }
}

nonisolated struct ScanComparison: Identifiable, Equatable, Sendable {
    let id: UUID
    let before: ComparedSnapshotSummary
    let after: ComparedSnapshotSummary
    let summary: ScanComparisonSummary
    let coverage: ScanComparisonCoverage
    let rows: [ScanComparisonRow]
    /// Inclusive path rollups built from the final, non-overlapping evidence rows.
    let changeTree: ScanComparisonChangeTree
    /// Non-overlapping first-level locations derived from `rows`, ordered by impact.
    let topLevelChanges: [ScanComparisonLocationChange]

    init(
        beforeSnapshot: ScanSnapshot,
        afterSnapshot: ScanSnapshot,
        rows: [ScanComparisonRow],
        changeTree: ScanComparisonChangeTree,
        topLevelChanges: [ScanComparisonLocationChange]
    ) {
        self.id = UUID()
        self.before = ComparedSnapshotSummary(snapshot: beforeSnapshot)
        self.after = ComparedSnapshotSummary(snapshot: afterSnapshot)
        self.rows = rows
        self.summary = ScanComparisonSummary(before: beforeSnapshot, after: afterSnapshot, rows: rows)
        self.coverage = ScanComparisonCoverage(before: beforeSnapshot, after: afterSnapshot)
        self.changeTree = changeTree
        self.topLevelChanges = topLevelChanges
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
        let materializationBoundaryPaths = Self.materializationBoundaryPaths(
            sharedPaths: sharedPaths,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes,
            beforeStore: before.treeStore,
            afterStore: after.treeStore
        )
        let allocatedSizes = Self.normalizedAllocatedSizes(
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )
        let visibleAddedPaths = Set(addedPaths.filter { relativePath in
            !Self.hasAncestor(of: relativePath, in: addedPaths)
                && !Self.hasAncestor(of: relativePath, in: materializationBoundaryPaths)
        })
        let visibleRemovedPaths = Set(removedPaths.filter { relativePath in
            !Self.hasAncestor(of: relativePath, in: removedPaths)
                && !Self.hasAncestor(of: relativePath, in: materializationBoundaryPaths)
        })
        let warningBoundaries = Self.warningBoundaryPaths(in: before)
            .union(Self.warningBoundaryPaths(in: after))
        // A warning represents unknown coverage, never proof that a path was created or
        // deleted. Suppress a collapsed ancestor row too when it contains a warning boundary.
        let coveredAddedPaths = Set(visibleAddedPaths.filter { relativePath in
            !Self.overlapsWarningBoundary(relativePath: relativePath, boundaries: warningBoundaries)
        })
        let coveredRemovedPaths = Set(visibleRemovedPaths.filter { relativePath in
            !Self.overlapsWarningBoundary(relativePath: relativePath, boundaries: warningBoundaries)
        })
        let movedPathPairs = Self.movedPathPairs(
            beforeNodes: beforeNodes,
            afterNodes: afterNodes,
            removedPaths: coveredRemovedPaths,
            addedPaths: coveredAddedPaths,
            beforeVolumeToken: Self.darwinResourceIdentityComponents(before.root.fileIdentity)?.volumeToken,
            afterVolumeToken: Self.darwinResourceIdentityComponents(after.root.fileIdentity)?.volumeToken
        )
        let movedRemovedPaths = Set(movedPathPairs.map(\.beforeRelativePath))
        let movedAddedPaths = Set(movedPathPairs.map(\.afterRelativePath))

        rows.reserveCapacity(addedPaths.count + removedPaths.count + sharedPaths.count)

        for movedPathPair in movedPathPairs {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: movedPathPair.afterRelativePath,
                kind: .moved,
                beforeNode: beforeNodes[movedPathPair.beforeRelativePath],
                afterNode: afterNodes[movedPathPair.afterRelativePath],
                beforeAllocatedSize: allocatedSizes.before[movedPathPair.beforeRelativePath],
                afterAllocatedSize: allocatedSizes.after[movedPathPair.afterRelativePath],
                movedFromRelativePath: movedPathPair.beforeRelativePath
            ))
        }

        for relativePath in coveredAddedPaths.subtracting(movedAddedPaths) {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: .added,
                beforeNode: nil,
                afterNode: afterNodes[relativePath],
                afterAllocatedSize: allocatedSizes.after[relativePath]
            ))
        }

        for relativePath in coveredRemovedPaths.subtracting(movedRemovedPaths) {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: .removed,
                beforeNode: beforeNodes[relativePath],
                afterNode: nil,
                beforeAllocatedSize: allocatedSizes.before[relativePath]
            ))
        }

        for relativePath in sharedPaths {
            try Task.checkCancellation()
            guard let beforeNode = beforeNodes[relativePath],
                  let afterNode = afterNodes[relativePath] else {
                continue
            }
            // A normal materialized directory's aggregate is already represented by descendant
            // additions, removals, and size changes. This includes a directory that was empty
            // in one snapshot and gained or lost indexed children in the other; emitting its
            // aggregate too would double-count those child rows. Opaque leaf directories remain
            // direct evidence because their descendants were not indexed.
            let beforeHasIndexedChildren = before.treeStore.containsChildren(id: beforeNode.id)
            let afterHasIndexedChildren = after.treeStore.containsChildren(id: afterNode.id)
            let beforeIsOpaque = Self.isOpaqueDirectory(
                beforeNode,
                hasIndexedChildren: beforeHasIndexedChildren
            )
            let afterIsOpaque = Self.isOpaqueDirectory(
                afterNode,
                hasIndexedChildren: afterHasIndexedChildren
            )
            let isRedundantDirectory = beforeNode.isDirectory && afterNode.isDirectory
                && !beforeIsOpaque
                && !afterIsOpaque
                && (beforeHasIndexedChildren || afterHasIndexedChildren)
            guard !isRedundantDirectory else { continue }
            let beforeAllocatedSize = allocatedSizes.before[relativePath] ?? beforeNode.allocatedSize
            let afterAllocatedSize = allocatedSizes.after[relativePath] ?? afterNode.allocatedSize
            let delta = afterAllocatedSize - beforeAllocatedSize
            guard delta != 0 else { continue }
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: delta > 0 ? .grew : .shrank,
                beforeNode: beforeNode,
                afterNode: afterNode,
                beforeAllocatedSize: beforeAllocatedSize,
                afterAllocatedSize: afterAllocatedSize
            ))
        }

        try Task.checkCancellation()
        let sortedRows = rows.sorted { lhs, rhs in
            ScanComparisonRowComparator.defaultOrder.compare(lhs, rhs) == .orderedAscending
        }
        let changeTree = try Self.changeTree(
            from: sortedRows,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )
        let topLevelChanges = Self.topLevelChanges(
            from: sortedRows,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )
        return ScanComparison(
            beforeSnapshot: before,
            afterSnapshot: after,
            rows: sortedRows,
            changeTree: changeTree,
            topLevelChanges: topLevelChanges
        )
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

    private struct MovedPathPair: Sendable {
        let beforeRelativePath: String
        let afterRelativePath: String
    }

    private enum ComparableMoveIdentity: Hashable {
        case exact(FileIdentity)
        case darwin(volumeToken: UInt64, fileID: UInt64)
    }

    private struct DarwinResourceIdentityComponents {
        let fileID: UInt64
        let volumeToken: UInt64
    }

    /// Matches only a one-to-one regular-file identity that is visible as both a removal and an
    /// addition. Hard links, directories, aliases, and synthetic nodes are intentionally
    /// excluded because a path-level move inference would be ambiguous for them.
    private static func movedPathPairs(
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord],
        removedPaths: Set<String>,
        addedPaths: Set<String>,
        beforeVolumeToken: UInt64?,
        afterVolumeToken: UInt64?
    ) -> [MovedPathPair] {
        let removedCandidates = moveCandidates(
            in: beforeNodes,
            paths: removedPaths,
            volumeToken: beforeVolumeToken
        )
        let addedCandidates = moveCandidates(
            in: afterNodes,
            paths: addedPaths,
            volumeToken: afterVolumeToken
        )
        let removedByIdentity = Dictionary(grouping: removedCandidates, by: \.identity)
        let addedByIdentity = Dictionary(grouping: addedCandidates, by: \.identity)

        return removedByIdentity.compactMap { identity, removedEntries in
            guard removedEntries.count == 1,
                  let addedEntries = addedByIdentity[identity],
                  addedEntries.count == 1,
                  let beforeRelativePath = removedEntries.first?.relativePath,
                  let afterRelativePath = addedEntries.first?.relativePath else {
                return nil
            }
            return MovedPathPair(
                beforeRelativePath: beforeRelativePath,
                afterRelativePath: afterRelativePath
            )
        }
        .sorted { lhs, rhs in
            lhs.afterRelativePath.localizedStandardCompare(rhs.afterRelativePath) == .orderedAscending
        }
    }

    private static func moveCandidates(
        in nodes: [String: FileNodeRecord],
        paths: Set<String>,
        volumeToken: UInt64?
    ) -> [(identity: ComparableMoveIdentity, relativePath: String)] {
        paths.compactMap { relativePath in
            guard let node = nodes[relativePath],
                  let identity = moveIdentity(for: node, volumeToken: volumeToken) else {
                return nil
            }
            return (identity, relativePath)
        }
    }

    private static func moveIdentity(
        for node: FileNodeRecord,
        volumeToken: UInt64?
    ) -> ComparableMoveIdentity? {
        guard !node.isDirectory,
              !node.isSymbolicLink,
              !node.isSynthetic,
              node.linkCount == 1,
              let identity = node.fileIdentity else {
            return nil
        }

        switch identity {
        case .resourceIdentifier:
            guard let components = darwinResourceIdentityComponents(identity) else {
                return .exact(identity)
            }
            return .darwin(
                volumeToken: components.volumeToken,
                fileID: components.fileID
            )
        case .fileSystem(_, let inode):
            guard let volumeToken else { return .exact(identity) }
            return .darwin(volumeToken: volumeToken, fileID: inode)
        }
    }

    /// Darwin's persisted file resource identifier is a 16-byte pair containing
    /// the filesystem file ID followed by a stable volume token. Older Radix
    /// archives store this form, while bulk scans obtain the equivalent file ID
    /// directly from ATTR_CMN_FILEID. Reject unfamiliar encodings rather than
    /// making a speculative cross-version match.
    private static func darwinResourceIdentityComponents(
        _ identity: FileIdentity?
    ) -> DarwinResourceIdentityComponents? {
        guard case .resourceIdentifier(let data) = identity,
              data.count == MemoryLayout<UInt64>.size * 2 else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            let fileID = UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self))
            let volumeToken = UInt64(littleEndian: bytes.loadUnaligned(
                fromByteOffset: MemoryLayout<UInt64>.size,
                as: UInt64.self
            ))
            return DarwinResourceIdentityComponents(
                fileID: fileID,
                volumeToken: volumeToken
            )
        }
    }

    private struct AggregateAccumulator {
        let relativePath: String
        let parentPath: String?
        var childPaths = Set<String>()
        var directRowID: ScanComparisonRow.ID?
        var representativeRowID: ScanComparisonRow.ID?
        var increasedAllocatedSize: Int64 = 0
        var reclaimedAllocatedSize: Int64 = 0
        var addedCount = 0
        var removedCount = 0
        var grewCount = 0
        var shrankCount = 0
        var movedCount = 0
        var increasedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64] = [:]
        var reclaimedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64] = [:]

        mutating func include(_ row: ScanComparisonRow, isDirect: Bool) {
            if representativeRowID == nil {
                representativeRowID = row.id
            }
            if isDirect {
                directRowID = row.id
            }
            if row.allocatedDelta > 0 {
                increasedAllocatedSize += row.allocatedDelta
                increasedAllocatedSizeByKind[row.kind, default: 0] += row.allocatedDelta
            } else if row.allocatedDelta < 0 {
                reclaimedAllocatedSize += -row.allocatedDelta
                reclaimedAllocatedSizeByKind[row.kind, default: 0] += -row.allocatedDelta
            }
            switch row.kind {
            case .added:
                addedCount += 1
            case .removed:
                removedCount += 1
            case .grew:
                grewCount += 1
            case .shrank:
                shrankCount += 1
            case .moved:
                movedCount += 1
            }
        }
    }

    /// Builds inclusive path rollups from the final evidence partition. Using the finalized rows
    /// is essential: raw directory sizes would double-count materialized descendants and bypass
    /// warning-boundary and hard-link normalization.
    private static func changeTree(
        from rows: [ScanComparisonRow],
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) throws -> ScanComparisonChangeTree {
        guard !rows.isEmpty else { return .empty }
        var accumulators: [String: AggregateAccumulator] = [:]
        accumulators.reserveCapacity(rows.count)

        for row in rows {
            try Task.checkCancellation()
            let components = row.relativePath.split(separator: "/", omittingEmptySubsequences: true)
            var parentPath: String?
            var path = ""
            for (index, component) in components.enumerated() {
                path = path.isEmpty ? String(component) : path + "/" + component
                var accumulator = accumulators[path] ?? AggregateAccumulator(
                    relativePath: path,
                    parentPath: parentPath
                )
                accumulator.include(row, isDirect: index == components.count - 1)
                accumulators[path] = accumulator

                if let parentPath {
                    var parent = accumulators[parentPath] ?? AggregateAccumulator(
                        relativePath: parentPath,
                        parentPath: Self.parentPath(of: parentPath)
                    )
                    parent.childPaths.insert(path)
                    accumulators[parentPath] = parent
                }
                parentPath = path
            }
        }

        func nodeSort(_ lhsPath: String, _ rhsPath: String) -> Bool {
            guard let lhs = accumulators[lhsPath], let rhs = accumulators[rhsPath] else {
                return lhsPath.localizedStandardCompare(rhsPath) == .orderedAscending
            }
            let lhsGross = lhs.increasedAllocatedSize + lhs.reclaimedAllocatedSize
            let rhsGross = rhs.increasedAllocatedSize + rhs.reclaimedAllocatedSize
            if lhsGross != rhsGross { return lhsGross > rhsGross }
            return lhsPath.localizedStandardCompare(rhsPath) == .orderedAscending
        }

        var nodesByPath: [String: ScanComparisonAggregateChange] = [:]
        nodesByPath.reserveCapacity(accumulators.count)
        for (path, accumulator) in accumulators {
            try Task.checkCancellation()
            guard let representativeRowID = accumulator.representativeRowID else { continue }
            let displayNode = afterNodes[path] ?? beforeNodes[path]
            nodesByPath[path] = ScanComparisonAggregateChange(
                id: path,
                relativePath: path,
                name: displayNode?.name ?? URL(filePath: path).lastPathComponent,
                parentPath: accumulator.parentPath,
                childPaths: accumulator.childPaths.sorted(by: nodeSort),
                directRowID: accumulator.directRowID,
                representativeRowID: representativeRowID,
                beforeNode: beforeNodes[path],
                afterNode: afterNodes[path],
                increasedAllocatedSize: accumulator.increasedAllocatedSize,
                reclaimedAllocatedSize: accumulator.reclaimedAllocatedSize,
                addedCount: accumulator.addedCount,
                removedCount: accumulator.removedCount,
                grewCount: accumulator.grewCount,
                shrankCount: accumulator.shrankCount,
                movedCount: accumulator.movedCount,
                increasedAllocatedSizeByKind: accumulator.increasedAllocatedSizeByKind,
                reclaimedAllocatedSizeByKind: accumulator.reclaimedAllocatedSizeByKind
            )
        }

        let rootPaths = accumulators.values
            .filter { $0.parentPath == nil }
            .map(\.relativePath)
            .sorted(by: nodeSort)
        return ScanComparisonChangeTree(rootPaths: rootPaths, nodesByPath: nodesByPath)
    }

    private static func parentPath(of relativePath: String) -> String? {
        guard let slashIndex = relativePath.lastIndex(of: "/") else { return nil }
        return String(relativePath[..<slashIndex])
    }

    private static func topLevelChanges(
        from rows: [ScanComparisonRow],
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) -> [ScanComparisonLocationChange] {
        let rowsByLocation = Dictionary(grouping: rows) { row in
            topLevelPath(for: row.relativePath)
        }

        return rowsByLocation.compactMap { relativePath, locationRows in
            guard let representativeRow = locationRows.min(by: {
                ScanComparisonRowComparator.defaultOrder.compare($0, $1) == .orderedAscending
            }) else {
                return nil
            }

            var counts: [ScanComparisonChangeKind: Int] = [:]
            var allocatedDelta: Int64 = 0
            var increasedAllocatedSize: Int64 = 0
            var reclaimedAllocatedSize: Int64 = 0
            for row in locationRows {
                counts[row.kind, default: 0] += 1
                allocatedDelta += row.allocatedDelta
                if row.allocatedDelta > 0 {
                    increasedAllocatedSize += row.allocatedDelta
                } else if row.allocatedDelta < 0 {
                    reclaimedAllocatedSize += -row.allocatedDelta
                }
            }

            let beforeNode = beforeNodes[relativePath]
            let afterNode = afterNodes[relativePath]
            let displayNode = afterNode ?? beforeNode
            return ScanComparisonLocationChange(
                id: relativePath,
                relativePath: relativePath,
                name: displayNode?.name ?? URL(filePath: relativePath).lastPathComponent,
                allocatedDelta: allocatedDelta,
                increasedAllocatedSize: increasedAllocatedSize,
                reclaimedAllocatedSize: reclaimedAllocatedSize,
                addedCount: counts[.added, default: 0],
                removedCount: counts[.removed, default: 0],
                grewCount: counts[.grew, default: 0],
                shrankCount: counts[.shrank, default: 0],
                movedCount: counts[.moved, default: 0],
                representativeRelativePath: representativeRow.relativePath,
                beforeNode: beforeNode,
                afterNode: afterNode
            )
        }
        .sorted { lhs, rhs in
            if lhs.grossChangedAllocatedSize != rhs.grossChangedAllocatedSize {
                return lhs.grossChangedAllocatedSize > rhs.grossChangedAllocatedSize
            }
            if lhs.absoluteAllocatedDelta != rhs.absoluteAllocatedDelta {
                return lhs.absoluteAllocatedDelta > rhs.absoluteAllocatedDelta
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private static func topLevelPath(for relativePath: String) -> String {
        guard let slashIndex = relativePath.firstIndex(of: "/") else {
            return relativePath
        }
        return String(relativePath[..<slashIndex])
    }

    private static func warningBoundaryPaths(in snapshot: ScanSnapshot) -> Set<String> {
        Set(snapshot.scanWarnings.compactMap { warning in
            relativeWarningPath(warning.path, rootID: snapshot.treeStore.rootID)
        })
    }

    private static func relativeWarningPath(_ warningPath: String, rootID: String) -> String? {
        guard warningPath == rootID else {
            return relativePath(for: warningPath, rootID: rootID)
        }
        // An empty relative path represents a warning at the scan root and therefore affects
        // every addition/removal in the snapshot.
        return ""
    }

    private static func overlapsWarningBoundary(
        relativePath: String,
        boundaries: Set<String>
    ) -> Bool {
        boundaries.contains { boundary in
            guard !boundary.isEmpty else { return true }
            return relativePath == boundary
                || relativePath.hasPrefix(boundary + "/")
                || boundary.hasPrefix(relativePath + "/")
        }
    }

    private static func materializationBoundaryPaths(
        sharedPaths: Set<String>,
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord],
        beforeStore: FileTreeStore,
        afterStore: FileTreeStore
    ) -> Set<String> {
        Set(sharedPaths.filter { relativePath in
            guard let beforeNode = beforeNodes[relativePath],
                  let afterNode = afterNodes[relativePath],
                  beforeNode.isDirectory,
                  afterNode.isDirectory else {
                return false
            }

            let beforeHasChildren = beforeStore.containsChildren(id: beforeNode.id)
            let afterHasChildren = afterStore.containsChildren(id: afterNode.id)
            guard beforeHasChildren != afterHasChildren else { return false }

            return Self.isOpaqueDirectory(beforeNode, hasIndexedChildren: beforeHasChildren)
                || Self.isOpaqueDirectory(afterNode, hasIndexedChildren: afterHasChildren)
        })
    }

    private static func isOpaqueDirectory(
        _ node: FileNodeRecord,
        hasIndexedChildren: Bool
    ) -> Bool {
        guard node.isDirectory, !hasIndexedChildren else { return false }
        return node.isAutoSummarized || node.isPackage || !node.isAccessible
    }

    private static func normalizedAllocatedSizes(
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) -> (
        before: [String: Int64],
        after: [String: Int64]
    ) {
        let identities = hardLinkIdentities(in: beforeNodes).union(hardLinkIdentities(in: afterNodes))
        guard !identities.isEmpty else {
            return (
                beforeNodes.mapValues(\.allocatedSize),
                afterNodes.mapValues(\.allocatedSize)
            )
        }

        let beforeGroups = hardLinkPathsByIdentity(in: beforeNodes, identities: identities)
        let afterGroups = hardLinkPathsByIdentity(in: afterNodes, identities: identities)
        var beforeSizes = beforeNodes.mapValues(\.allocatedSize)
        var afterSizes = afterNodes.mapValues(\.allocatedSize)

        for identity in identities {
            let beforePaths = beforeGroups[identity] ?? []
            let afterPaths = afterGroups[identity] ?? []
            let sharedPaths = Set(beforePaths).intersection(afterPaths)

            if !sharedPaths.isEmpty, let ownerPath = sharedPaths.min() {
                normalizeHardLinkGroup(
                    paths: beforePaths,
                    ownerPath: ownerPath,
                    nodes: beforeNodes,
                    sizes: &beforeSizes
                )
                normalizeHardLinkGroup(
                    paths: afterPaths,
                    ownerPath: ownerPath,
                    nodes: afterNodes,
                    sizes: &afterSizes
                )
            } else {
                if let ownerPath = beforePaths.min() {
                    normalizeHardLinkGroup(
                        paths: beforePaths,
                        ownerPath: ownerPath,
                        nodes: beforeNodes,
                        sizes: &beforeSizes
                    )
                }
                if let ownerPath = afterPaths.min() {
                    normalizeHardLinkGroup(
                        paths: afterPaths,
                        ownerPath: ownerPath,
                        nodes: afterNodes,
                        sizes: &afterSizes
                    )
                }
            }
        }

        return (beforeSizes, afterSizes)
    }

    private static func hardLinkIdentities(
        in nodes: [String: FileNodeRecord]
    ) -> Set<FileIdentity> {
        Set(nodes.values.lazy.compactMap { node in
            guard !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic,
                  node.linkCount > 1 else {
                return nil
            }
            return node.fileIdentity
        })
    }

    private static func hardLinkPathsByIdentity(
        in nodes: [String: FileNodeRecord],
        identities: Set<FileIdentity>
    ) -> [FileIdentity: [String]] {
        let entries: [(identity: FileIdentity, relativePath: String)] = nodes.compactMap { relativePath, node in
            guard !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic,
                  let identity = node.fileIdentity,
                  identities.contains(identity) else {
                return nil
            }
            return (identity, relativePath)
        }
        return Dictionary(grouping: entries, by: \.identity)
            .mapValues { groupedEntries in groupedEntries.map(\.relativePath) }
    }

    private static func normalizeHardLinkGroup(
        paths: [String],
        ownerPath: String,
        nodes: [String: FileNodeRecord],
        sizes: inout [String: Int64]
    ) {
        let groupAllocatedSize = paths.compactMap { nodes[$0]?.unduplicatedAllocatedSize }.max() ?? 0

        for path in paths {
            guard let node = nodes[path] else { continue }
            let normalizedSize = path == ownerPath ? groupAllocatedSize : 0
            let adjustment = normalizedSize - node.allocatedSize
            guard adjustment != 0 else { continue }

            sizes[path] = normalizedSize
            var cursor = path
            while let slashIndex = cursor.lastIndex(of: "/") {
                cursor = String(cursor[..<slashIndex])
                guard sizes[cursor] != nil else { continue }
                sizes[cursor, default: 0] += adjustment
            }
        }
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

nonisolated struct ScanComparisonRowQuery: Equatable, Sendable {
    let changeKinds: Set<ScanComparisonChangeKind>
    let searchText: String
    let sortOrder: [ScanComparisonRowComparator]
    /// Limits evidence to one top-level contributor while retaining its full descendant rows.
    let pathPrefix: String?

    init(
        changeKinds: Set<ScanComparisonChangeKind> = Set(ScanComparisonChangeKind.allCases),
        searchText: String,
        sortOrder: [ScanComparisonRowComparator],
        pathPrefix: String? = nil
    ) {
        self.changeKinds = changeKinds
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.pathPrefix = pathPrefix
    }

    func applying(to rows: [ScanComparisonRow]) -> [ScanComparisonRow] {
        let query = SearchNormalizer.normalize(
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let filteredRows = rows.filter { row in
            guard changeKinds.contains(row.kind) else { return false }
            if let pathPrefix, !pathPrefix.isEmpty {
                guard row.relativePath == pathPrefix || row.relativePath.hasPrefix(pathPrefix + "/") else {
                    return false
                }
            }
            guard !query.isEmpty else { return true }
            return SearchNormalizer.normalize(row.name).contains(query)
                || SearchNormalizer.normalize(row.relativePath).contains(query)
        }

        guard !sortOrder.isEmpty else { return filteredRows }
        return filteredRows.sorted { lhs, rhs in
            for comparator in sortOrder {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    continue
                @unknown default:
                    continue
                }
            }
            return false
        }
    }
}

private nonisolated extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
