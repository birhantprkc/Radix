import Foundation

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

