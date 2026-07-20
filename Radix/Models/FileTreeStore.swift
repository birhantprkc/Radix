//
//  FileTreeStore.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated struct FileTreeNodeIndex: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt32
}

nonisolated struct PreparedFileTreeNodeSet: Sendable {
    fileprivate let indices: Set<FileTreeNodeIndex>
}

nonisolated struct FileTreeSubtreeContents: Sendable {
    let root: FileNodeRecord
    let nodesByID: [String: FileNodeRecord]
    let childIDsByID: [String: [String]]
}

nonisolated struct FileTreeChildSpan: Sendable {
    var start: UInt32 = 0
    var count: UInt32 = 0
}

nonisolated private struct FileTreeTopologyArena: Sendable {
    private static let noParent = UInt32.max

    let rootIndex: FileTreeNodeIndex
    let indexByNodeID: [String: FileTreeNodeIndex]
    let parentRawIndices: [UInt32]
    let childSpans: [FileTreeChildSpan]
    let childIndices: [FileTreeNodeIndex]
    let orderedNodeIndices: [FileTreeNodeIndex]

    init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        orderedNodeIDs: [String]
    ) {
        precondition(orderedNodeIDs.count <= Int(UInt32.max), "FileTreeStore exceeds its node-index capacity.")
        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(orderedNodeIDs.count)
        for (offset, nodeID) in orderedNodeIDs.enumerated() {
            precondition(nodesByID[nodeID] != nil, "FileTreeStore order references a missing node.")
            indexByNodeID[nodeID] = FileTreeNodeIndex(rawValue: UInt32(offset))
        }
        guard let rootIndex = indexByNodeID[rootID] else {
            preconditionFailure("FileTreeStore root is missing from its node order.")
        }

        var parentRawIndices = Array(repeating: Self.noParent, count: orderedNodeIDs.count)
        var childSpans = Array(repeating: FileTreeChildSpan(), count: orderedNodeIDs.count)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(max(orderedNodeIDs.count - 1, 0))
        for parentID in orderedNodeIDs {
            guard let parentIndex = indexByNodeID[parentID],
                  let childIDs = childIDsByID[parentID],
                  !childIDs.isEmpty else {
                continue
            }
            let start = childIndices.count
            for childID in childIDs {
                guard let childIndex = indexByNodeID[childID] else { continue }
                childIndices.append(childIndex)
                parentRawIndices[Int(childIndex.rawValue)] = parentIndex.rawValue
            }
            childSpans[Int(parentIndex.rawValue)] = FileTreeChildSpan(
                start: UInt32(start),
                count: UInt32(childIndices.count - start)
            )
        }

        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIDs.compactMap { indexByNodeID[$0] }
    }

    init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        childIndicesByIndex: [[FileTreeNodeIndex]],
        parentIndices: [FileTreeNodeIndex?],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        precondition(nodes.count <= Int(UInt32.max), "FileTreeStore exceeds its node-index capacity.")
        precondition(childIndicesByIndex.count == nodes.count, "Verified child topology count does not match nodes.")
        precondition(parentIndices.count == nodes.count, "Verified parent topology count does not match nodes.")
        precondition(Int(rootIndex.rawValue) < nodes.count, "Verified root index is out of range.")

        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(nodes.count)
        for (offset, node) in nodes.enumerated() {
            let previous = indexByNodeID.updateValue(
                FileTreeNodeIndex(rawValue: UInt32(offset)),
                forKey: node.id
            )
            precondition(previous == nil, "Verified FileTreeStore contains duplicate node IDs.")
        }

        var parentRawIndices = Array(repeating: Self.noParent, count: nodes.count)
        for (offset, parentIndex) in parentIndices.enumerated() {
            guard let parentIndex else { continue }
            precondition(Int(parentIndex.rawValue) < nodes.count, "Verified parent index is out of range.")
            parentRawIndices[offset] = parentIndex.rawValue
        }

        var childSpans = Array(repeating: FileTreeChildSpan(), count: nodes.count)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(max(nodes.count - 1, 0))
        for (offset, children) in childIndicesByIndex.enumerated() {
            let start = childIndices.count
            for childIndex in children {
                precondition(Int(childIndex.rawValue) < nodes.count, "Verified child index is out of range.")
                childIndices.append(childIndex)
            }
            childSpans[offset] = FileTreeChildSpan(
                start: UInt32(start),
                count: UInt32(childIndices.count - start)
            )
        }
        for index in orderedNodeIndices {
            precondition(Int(index.rawValue) < nodes.count, "Verified node order index is out of range.")
        }

        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIndices
    }

    init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        indexByNodeID verifiedIndexByNodeID: [String: FileTreeNodeIndex]? = nil,
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        precondition(nodes.count <= Int(UInt32.max), "FileTreeStore exceeds its node-index capacity.")
        precondition(parentRawIndices.count == nodes.count, "Verified parent topology count does not match nodes.")
        precondition(childSpans.count == nodes.count, "Verified child topology count does not match nodes.")
        precondition(Int(rootIndex.rawValue) < nodes.count, "Verified root index is out of range.")
        assert(orderedNodeIndices.count == nodes.count)
        assert(childIndices.count == max(nodes.count - 1, 0))

        let indexByNodeID: [String: FileTreeNodeIndex]
        if let verifiedIndexByNodeID {
            precondition(verifiedIndexByNodeID.count == nodes.count, "Verified node index count does not match nodes.")
            indexByNodeID = verifiedIndexByNodeID
        } else {
            var rebuiltIndexByNodeID: [String: FileTreeNodeIndex] = [:]
            rebuiltIndexByNodeID.reserveCapacity(nodes.count)
            for (offset, node) in nodes.enumerated() {
                let previous = rebuiltIndexByNodeID.updateValue(
                    FileTreeNodeIndex(rawValue: UInt32(offset)),
                    forKey: node.id
                )
                precondition(previous == nil, "Verified FileTreeStore contains duplicate node IDs.")
            }
            indexByNodeID = rebuiltIndexByNodeID
        }

        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIndices
    }

    private init(
        rootIndex: FileTreeNodeIndex,
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIndices
    }

    func parentIndex(of index: FileTreeNodeIndex) -> FileTreeNodeIndex? {
        guard Int(index.rawValue) < parentRawIndices.count else { return nil }
        let rawValue = parentRawIndices[Int(index.rawValue)]
        return rawValue == Self.noParent ? nil : FileTreeNodeIndex(rawValue: rawValue)
    }

    func children(of index: FileTreeNodeIndex) -> ArraySlice<FileTreeNodeIndex> {
        guard Int(index.rawValue) < childSpans.count else { return [] }
        let span = childSpans[Int(index.rawValue)]
        let start = Int(span.start)
        return childIndices[start..<(start + Int(span.count))]
    }

    func reorderingChildren(
        of parentIndex: FileTreeNodeIndex,
        to reorderedChildren: [FileTreeNodeIndex]
    ) -> FileTreeTopologyArena? {
        let existingChildren = children(of: parentIndex)
        guard existingChildren.count == reorderedChildren.count,
              Set(existingChildren).count == existingChildren.count,
              Set(existingChildren) == Set(reorderedChildren) else {
            return nil
        }
        guard !existingChildren.elementsEqual(reorderedChildren) else { return self }

        let span = childSpans[Int(parentIndex.rawValue)]
        let start = Int(span.start)
        let end = start + Int(span.count)
        var updatedChildIndices = childIndices
        updatedChildIndices.replaceSubrange(start..<end, with: reorderedChildren)
        let updatedOrder = Self.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            capacity: orderedNodeIndices.count,
            cancellationCheck: {}
        )
        guard updatedOrder.count == orderedNodeIndices.count else { return nil }

        return FileTreeTopologyArena(
            rootIndex: rootIndex,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            orderedNodeIndices: updatedOrder
        )
    }

    func replacingChildIndices(
        _ updatedChildIndices: [FileTreeNodeIndex],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeTopologyArena {
        precondition(updatedChildIndices.count == childIndices.count)
        let updatedOrder = try Self.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            capacity: orderedNodeIndices.count,
            cancellationCheck: cancellationCheck
        )
        precondition(updatedOrder.count == orderedNodeIndices.count)
        return FileTreeTopologyArena(
            rootIndex: rootIndex,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            orderedNodeIndices: updatedOrder
        )
    }

    static func preorderNodeIndices(
        rootIndex: FileTreeNodeIndex,
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        capacity: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [FileTreeNodeIndex] {
        var result: [FileTreeNodeIndex] = []
        result.reserveCapacity(capacity)
        var stack = [rootIndex]
        while let nodeIndex = stack.popLast() {
            if result.count.isMultiple(of: 256) {
                try cancellationCheck()
            }
            result.append(nodeIndex)
            let span = childSpans[Int(nodeIndex.rawValue)]
            let start = Int(span.start)
            let end = start + Int(span.count)
            stack.append(contentsOf: childIndices[start..<end].reversed())
        }
        return result
    }
}

nonisolated struct FileTreeStore: Sendable {
    let contentID: UUID
    let rootID: String
    private let nodeRecords: [FileNodeRecord]
    private let topologyArena: FileTreeTopologyArena
    private let precomputedAggregateStats: ScanAggregateStats?

    nonisolated var nodesByID: [String: FileNodeRecord] {
        Dictionary(uniqueKeysWithValues: nodeRecords.map { ($0.id, $0) })
    }

    nonisolated var childIDsByID: [String: [String]] {
        var result: [String: [String]] = [:]
        for parentIndex in topologyArena.orderedNodeIndices {
            let children = topologyArena.children(of: parentIndex)
            guard !children.isEmpty,
                  let parent = self.node(at: parentIndex) else {
                continue
            }
            result[parent.id] = children.compactMap { node(at: $0)?.id }
        }
        return result
    }

    nonisolated var parentIDByID: [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(max(nodeCount - 1, 0))
        for nodeIndex in topologyArena.orderedNodeIndices {
            guard let parentIndex = topologyArena.parentIndex(of: nodeIndex),
                  let record = node(at: nodeIndex),
                  let parent = node(at: parentIndex) else {
                continue
            }
            result[record.id] = parent.id
        }
        return result
    }

    private struct SanitizedTopology {
        let nodesByID: [String: FileNodeRecord]
        let childIDsByID: [String: [String]]
        let orderedNodeIDs: [String]
        let materializedDirectoryIDs: Set<String>
        let didDropReferences: Bool
    }

    private struct SubtreeReplacementPlan {
        let targetID: String
        let oldParentID: String?
        let oldSubtreeIDs: Set<String>
        let replacementRootID: String
        let replacementNodesByID: [String: FileNodeRecord]
        let replacementChildIDsByID: [String: [String]]
        let replacementParentIDByID: [String: String]
    }

    private struct AggregateStatsAccumulator {
        private var fileCount = 0
        private var directoryCount = 0
        private var accessibleItemCount = 0
        private var inaccessibleItemCount = 0

        @inline(__always)
        mutating func include(_ node: FileNodeRecord, hasMaterializedChildren: Bool) {
            if node.isDirectory {
                directoryCount += 1
                if !hasMaterializedChildren && (node.isPackage || node.isAutoSummarized) {
                    fileCount = FileTreeStore.saturatingAdd(fileCount, node.descendantFileCount)
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount = FileTreeStore.saturatingAdd(fileCount, 1)
            }

            if node.isAccessible {
                accessibleItemCount = FileTreeStore.saturatingAdd(accessibleItemCount, 1)
            } else {
                inaccessibleItemCount = FileTreeStore.saturatingAdd(inaccessibleItemCount, 1)
            }
        }

        func stats(root: FileNodeRecord) -> ScanAggregateStats {
            ScanAggregateStats(
                totalAllocatedSize: root.allocatedSize,
                totalLogicalSize: root.logicalSize,
                fileCount: fileCount,
                directoryCount: directoryCount,
                accessibleItemCount: accessibleItemCount,
                inaccessibleItemCount: inaccessibleItemCount
            )
        }
    }

    private struct MaterializedDirectoryTotals {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var childrenAreAccessible = true

        mutating func include(_ child: FileNodeRecord) {
            allocatedSize = FileTreeStore.saturatingAdd(allocatedSize, child.allocatedSize)
            logicalSize = FileTreeStore.saturatingAdd(logicalSize, child.logicalSize)
            childrenAreAccessible = childrenAreAccessible && child.isAccessible
            if child.isDirectory {
                descendantFileCount = FileTreeStore.saturatingAdd(
                    descendantFileCount,
                    child.descendantFileCount
                )
            } else if !child.isSymbolicLink && !child.isSynthetic {
                descendantFileCount = FileTreeStore.saturatingAdd(descendantFileCount, 1)
            }
        }
    }

    private enum StoreError: LocalizedError {
        case replacementIDCollision(String)
        case overlappingReplacementTargets(String, String)

        var errorDescription: String? {
            switch self {
            case .replacementIDCollision(let id):
                return "The replacement tree reuses an existing node ID outside the replaced subtree: \(id)."
            case .overlappingReplacementTargets(let ancestorID, let descendantID):
                return "Batch replacements must be disjoint, but \(ancestorID) contains \(descendantID)."
            }
        }
    }

    nonisolated var root: FileNodeRecord {
        guard let root = node(at: topologyArena.rootIndex) else {
            preconditionFailure("FileTreeStore rootID does not exist in nodesByID.")
        }
        return root
    }

    nonisolated var nodeCount: Int {
        nodeRecords.count
    }

    nonisolated var aggregateStats: ScanAggregateStats {
        if let precomputedAggregateStats {
            return precomputedAggregateStats
        }

        return computedAggregateStats()
    }

    private nonisolated func computedAggregateStats() -> ScanAggregateStats {
        var accumulator = AggregateStatsAccumulator()

        for nodeIndex in topologyArena.orderedNodeIndices {
            guard let node = node(at: nodeIndex) else { continue }
            accumulator.include(
                node,
                hasMaterializedChildren: !topologyArena.children(of: nodeIndex).isEmpty
            )
        }

        return accumulator.stats(root: root)
    }

    nonisolated init(root: FileNodeRecord) {
        self.init(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [:],
            parentIDByID: [:]
        )
    }

    nonisolated init(root: FileNodeRecord, childrenByID inputChildrenByID: [String: [FileNodeRecord]]) {
        var nodesByID = [root.id: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var seenNodeIDs: Set<String> = [root.id]
        var stack = [root]

        while let parent = stack.popLast() {
            guard let inputChildren = inputChildrenByID[parent.id] else { continue }
            let (uniqueChildren, droppedChildIDs) = Self.uniqueChildrenAndDroppedIDs(
                inputChildren,
                seenNodeIDs: &seenNodeIDs
            )
            let children = Self.sortedChildren(uniqueChildren)
            childIDsByID[parent.id] = children.map(\.id) + droppedChildIDs
            guard !children.isEmpty else { continue }

            for child in children {
                nodesByID[child.id] = child
                parentIDByID[child.id] = parent.id
                stack.append(child)
            }
        }

        self.init(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )
    }

    nonisolated init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        let topology = Self.sanitizedTopology(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        self.contentID = UUID()
        self.rootID = rootID
        let storedNodes = topology.didDropReferences || aggregateStats == nil
            ? Self.repairMaterializedDirectoryTotals(
                nodesByID: topology.nodesByID,
                childIDsByID: topology.childIDsByID,
                orderedNodeIDs: topology.orderedNodeIDs,
                materializedDirectoryIDs: topology.materializedDirectoryIDs
            )
            : topology.nodesByID
        self.nodeRecords = topology.orderedNodeIDs.compactMap { storedNodes[$0] }
        self.topologyArena = FileTreeTopologyArena(
            rootID: rootID,
            nodesByID: storedNodes,
            childIDsByID: topology.childIDsByID,
            orderedNodeIDs: topology.orderedNodeIDs
        )
        self.precomputedAggregateStats = topology.didDropReferences ? nil : aggregateStats
    }

    nonisolated init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        parentIDByID _: [String: String],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        self.init(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            aggregateStats: aggregateStats
        )
    }

    /// Fast construction for scanner output whose topology has already been
    /// validated while it was assembled. This avoids copying every node and
    /// edge through the general-purpose topology sanitizer a second time.
    nonisolated init(
        verifiedRootID rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats
    ) {
        precondition(nodesByID[rootID] != nil, "Verified FileTreeStore root is missing.")
        self.contentID = UUID()
        self.rootID = rootID
        let orderedNodeIDs = Self.orderedNodeIDsAssumingValidTopology(
            rootID: rootID,
            childIDsByID: childIDsByID,
            nodeCount: nodesByID.count
        )
        self.topologyArena = FileTreeTopologyArena(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            orderedNodeIDs: orderedNodeIDs
        )
        self.nodeRecords = orderedNodeIDs.compactMap { nodesByID[$0] }
        self.precomputedAggregateStats = aggregateStats
        assert(orderedNodeIDs.count == nodesByID.count)
        assert(parentIDByID == self.parentIDByID)
    }

    /// Fast construction for scanner output already represented by compact node indices.
    /// Node indices are stable array offsets and child lists must already be display-sorted.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        childIndicesByIndex: [[FileTreeNodeIndex]],
        parentIndices: [FileTreeNodeIndex?],
        orderedNodeIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats
    ) {
        let topologyArena = FileTreeTopologyArena(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices
        )
        let rootOffset = Int(rootIndex.rawValue)
        precondition(nodes.indices.contains(rootOffset), "Verified FileTreeStore root is missing.")
        self.init(
            rootID: nodes[rootOffset].id,
            nodeRecords: nodes,
            topologyArena: topologyArena,
            aggregateStats: aggregateStats
        )
    }

    /// Fast construction for scanner output already assembled into the store's
    /// compact topology representation.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats,
        cancellationCheck: () throws -> Void
    ) rethrows {
        let orderedNodeIndices = try FileTreeTopologyArena.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: childIndices,
            capacity: nodes.count,
            cancellationCheck: cancellationCheck
        )
        self.init(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: aggregateStats
        )
    }

    /// Fast construction for scanner output with a precomputed traversal order.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats
    ) {
        let topologyArena = FileTreeTopologyArena(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices
        )
        let rootOffset = Int(rootIndex.rawValue)
        precondition(nodes.indices.contains(rootOffset), "Verified FileTreeStore root is missing.")
        self.init(
            rootID: nodes[rootOffset].id,
            nodeRecords: nodes,
            topologyArena: topologyArena,
            aggregateStats: aggregateStats
        )
    }

    /// Fast construction for imported compact archives whose ordinal topology
    /// and node index were validated while the records were materialized.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: inout [FileNodeRecord],
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        let topologyArena = FileTreeTopologyArena(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices
        )
        let rootOffset = Int(rootIndex.rawValue)
        precondition(nodes.indices.contains(rootOffset), "Verified FileTreeStore root is missing.")

        var statsAccumulator = AggregateStatsAccumulator()
        for nodeIndex in orderedNodeIndices.reversed() {
            let offset = Int(nodeIndex.rawValue)
            let span = childSpans[offset]
            if span.count > 0, nodes[offset].isDirectory {
                let start = Int(span.start)
                let end = start + Int(span.count)
                nodes[offset] = Self.repairingDirectoryRecord(
                    nodes[offset],
                    childIndices: childIndices[start..<end],
                    nodes: nodes
                )
            }
            statsAccumulator.include(
                nodes[offset],
                hasMaterializedChildren: span.count > 0
            )
        }

        self.contentID = UUID()
        self.rootID = nodes[rootOffset].id
        self.nodeRecords = nodes
        self.topologyArena = topologyArena
        self.precomputedAggregateStats = statsAccumulator.stats(root: nodes[rootOffset])
    }

    private nonisolated init(
        rootID: String,
        nodeRecords: [FileNodeRecord],
        topologyArena: FileTreeTopologyArena,
        aggregateStats: ScanAggregateStats
    ) {
        self.contentID = UUID()
        self.rootID = rootID
        self.nodeRecords = nodeRecords
        self.topologyArena = topologyArena
        self.precomputedAggregateStats = aggregateStats
    }

    nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        var sortedChildren = children
        sortChildren(&sortedChildren)
        return sortedChildren
    }

    nonisolated static func sortChildren(_ children: inout [FileNodeRecord]) {
        guard children.count > 1 else { return }
        children.sort(by: areInDisplayOrder)
    }

    nonisolated static func areInDisplayOrder(
        _ lhs: FileNodeRecord,
        _ rhs: FileNodeRecord
    ) -> Bool {
        if lhs.allocatedSize == rhs.allocatedSize {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.allocatedSize > rhs.allocatedSize
    }

    private nonisolated static func uniqueChildrenAndDroppedIDs(
        _ children: [FileNodeRecord],
        seenNodeIDs: inout Set<String>
    ) -> (uniqueChildren: [FileNodeRecord], droppedChildIDs: [String]) {
        var uniqueChildren: [FileNodeRecord] = []
        var droppedChildIDs: [String] = []
        uniqueChildren.reserveCapacity(children.count)

        for child in children {
            if seenNodeIDs.insert(child.id).inserted {
                uniqueChildren.append(child)
            } else {
                droppedChildIDs.append(child.id)
            }
        }

        return (uniqueChildren, droppedChildIDs)
    }

    nonisolated func node(id: String?) -> FileNodeRecord? {
        guard let index = nodeIndex(id: id) else { return nil }
        return node(at: index)
    }

    nonisolated func nodeIndex(id: String?) -> FileTreeNodeIndex? {
        guard let id else { return nil }
        return topologyArena.indexByNodeID[id]
    }

    nonisolated func node(at index: FileTreeNodeIndex) -> FileNodeRecord? {
        let offset = Int(index.rawValue)
        guard nodeRecords.indices.contains(offset) else { return nil }
        return nodeRecords[offset]
    }

    /// Replaces existing records while preserving node membership and parent links.
    /// The supplied child order must contain exactly the parent's current children.
    nonisolated func replacingRecordsPreservingTopology(
        _ replacements: [FileNodeRecord],
        orderedChildIDs: [String],
        of parentID: String,
        aggregateStats: ScanAggregateStats
    ) -> FileTreeStore? {
        guard !replacements.isEmpty,
              let parentIndex = nodeIndex(id: parentID) else {
            return nil
        }

        var indexedReplacements: [(Int, FileNodeRecord)] = []
        indexedReplacements.reserveCapacity(replacements.count)
        var replacementIDs = Set<String>()
        for replacement in replacements {
            guard replacementIDs.insert(replacement.id).inserted,
                  let index = nodeIndex(id: replacement.id) else {
                return nil
            }
            indexedReplacements.append((Int(index.rawValue), replacement))
        }

        let reorderedChildIndices = orderedChildIDs.compactMap { nodeIndex(id: $0) }
        guard reorderedChildIndices.count == orderedChildIDs.count,
              let updatedTopology = topologyArena.reorderingChildren(
                  of: parentIndex,
                  to: reorderedChildIndices
              ) else {
            return nil
        }

        var updatedRecords = nodeRecords
        for (offset, replacement) in indexedReplacements {
            updatedRecords[offset] = replacement
        }

        return FileTreeStore(
            rootID: rootID,
            nodeRecords: updatedRecords,
            topologyArena: updatedTopology,
            aggregateStats: aggregateStats
        )
    }

    /// Adds or removes one root-level leaf while preserving every unaffected
    /// subtree in the compact arena. This avoids dictionary projections for
    /// synthetic capacity nodes without exposing general topology mutation.
    nonisolated func replacingRootLeaf(
        removing removedLeafID: String?,
        adding addedLeaf: FileNodeRecord?,
        root replacementRoot: FileNodeRecord,
        orderedChildIDs: [String],
        aggregateStats: ScanAggregateStats
    ) -> FileTreeStore? {
        guard replacementRoot.id == rootID,
              let oldRootIndex = nodeIndex(id: rootID) else {
            return nil
        }

        let oldRootChildren = topologyArena.children(of: oldRootIndex)
        var expectedChildIDs = oldRootChildren.compactMap { node(at: $0)?.id }
        var removedIndex: FileTreeNodeIndex?
        if let removedLeafID {
            guard let index = nodeIndex(id: removedLeafID),
                  topologyArena.parentIndex(of: index) == oldRootIndex,
                  topologyArena.children(of: index).isEmpty else {
                return nil
            }
            removedIndex = index
            expectedChildIDs.removeAll { $0 == removedLeafID }
        }
        if let addedLeaf {
            guard !addedLeaf.isDirectory,
                  addedLeaf.id != removedLeafID,
                  nodeIndex(id: addedLeaf.id) == nil else {
                return nil
            }
            expectedChildIDs.append(addedLeaf.id)
        }
        guard orderedChildIDs.count == expectedChildIDs.count,
              Set(orderedChildIDs).count == orderedChildIDs.count,
              Set(orderedChildIDs) == Set(expectedChildIDs) else {
            return nil
        }

        var remappedIndices = Array<FileTreeNodeIndex?>(repeating: nil, count: nodeRecords.count)
        var updatedRecords: [FileNodeRecord] = []
        updatedRecords.reserveCapacity(
            nodeRecords.count
                - (removedIndex == nil ? 0 : 1)
                + (addedLeaf == nil ? 0 : 1)
        )
        for (offset, record) in nodeRecords.enumerated() {
            let oldIndex = FileTreeNodeIndex(rawValue: UInt32(offset))
            guard oldIndex != removedIndex else { continue }
            let newIndex = FileTreeNodeIndex(rawValue: UInt32(updatedRecords.count))
            remappedIndices[offset] = newIndex
            updatedRecords.append(oldIndex == oldRootIndex ? replacementRoot : record)
        }
        let addedLeafIndex: FileTreeNodeIndex?
        if let addedLeaf {
            addedLeafIndex = FileTreeNodeIndex(rawValue: UInt32(updatedRecords.count))
            updatedRecords.append(addedLeaf)
        } else {
            addedLeafIndex = nil
        }

        guard let updatedRootIndex = remappedIndices[Int(oldRootIndex.rawValue)] else {
            return nil
        }
        var parentIndices = Array<FileTreeNodeIndex?>(repeating: nil, count: updatedRecords.count)
        var childIndicesByIndex = Array(repeating: [FileTreeNodeIndex](), count: updatedRecords.count)
        for oldOffset in nodeRecords.indices {
            guard let newIndex = remappedIndices[oldOffset] else { continue }
            let oldIndex = FileTreeNodeIndex(rawValue: UInt32(oldOffset))
            if let oldParent = topologyArena.parentIndex(of: oldIndex) {
                guard let newParent = remappedIndices[Int(oldParent.rawValue)] else { return nil }
                parentIndices[Int(newIndex.rawValue)] = newParent
            }
            childIndicesByIndex[Int(newIndex.rawValue)] = topologyArena.children(of: oldIndex).compactMap {
                remappedIndices[Int($0.rawValue)]
            }
        }

        let updatedRootChildren = orderedChildIDs.compactMap { childID -> FileTreeNodeIndex? in
            if childID == addedLeaf?.id {
                return addedLeafIndex
            }
            guard let oldIndex = nodeIndex(id: childID) else { return nil }
            return remappedIndices[Int(oldIndex.rawValue)]
        }
        guard updatedRootChildren.count == orderedChildIDs.count else { return nil }
        childIndicesByIndex[Int(updatedRootIndex.rawValue)] = updatedRootChildren
        for childIndex in updatedRootChildren {
            parentIndices[Int(childIndex.rawValue)] = updatedRootIndex
        }

        var orderedNodeIndices: [FileTreeNodeIndex] = []
        orderedNodeIndices.reserveCapacity(updatedRecords.count)
        var stack = [updatedRootIndex]
        while let index = stack.popLast() {
            orderedNodeIndices.append(index)
            stack.append(contentsOf: childIndicesByIndex[Int(index.rawValue)].reversed())
        }
        guard orderedNodeIndices.count == updatedRecords.count else { return nil }

        return FileTreeStore(
            verifiedRootIndex: updatedRootIndex,
            nodes: updatedRecords,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: aggregateStats
        )
    }

    nonisolated func replacingAllocatedSizes(
        _ allocatedSizeByNodeID: [String: Int64],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        guard !allocatedSizeByNodeID.isEmpty else { return self }

        var updatedRecords = nodeRecords
        var changedOffsets = Set<Int>()
        changedOffsets.reserveCapacity(allocatedSizeByNodeID.count)
        for (nodeID, allocatedSize) in allocatedSizeByNodeID {
            try cancellationCheck()
            guard let nodeIndex = nodeIndex(id: nodeID) else { continue }
            let offset = Int(nodeIndex.rawValue)
            guard updatedRecords[offset].allocatedSize != allocatedSize else { continue }
            updatedRecords[offset] = updatedRecords[offset].replacingAllocatedSize(allocatedSize)
            changedOffsets.insert(offset)
        }
        guard !changedOffsets.isEmpty else { return self }

        var affectedAncestors = Array(repeating: false, count: nodeRecords.count)
        for changedOffset in changedOffsets {
            var cursor = topologyArena.parentIndex(
                of: FileTreeNodeIndex(rawValue: UInt32(changedOffset))
            )
            while let ancestorIndex = cursor {
                try cancellationCheck()
                let ancestorOffset = Int(ancestorIndex.rawValue)
                guard !affectedAncestors[ancestorOffset] else { break }
                affectedAncestors[ancestorOffset] = true
                cursor = topologyArena.parentIndex(of: ancestorIndex)
            }
        }

        var updatedChildIndices = topologyArena.childIndices
        for nodeIndex in topologyArena.orderedNodeIndices.reversed() {
            let nodeOffset = Int(nodeIndex.rawValue)
            guard affectedAncestors[nodeOffset], updatedRecords[nodeOffset].isDirectory else {
                continue
            }
            try cancellationCheck()

            let span = topologyArena.childSpans[nodeOffset]
            let start = Int(span.start)
            let end = start + Int(span.count)
            var children = Array(updatedChildIndices[start..<end])
            children.sort { lhsIndex, rhsIndex in
                Self.areInDisplayOrder(
                    updatedRecords[Int(lhsIndex.rawValue)],
                    updatedRecords[Int(rhsIndex.rawValue)]
                )
            }
            updatedRecords[nodeOffset] = Self.repairingDirectoryRecord(
                updatedRecords[nodeOffset],
                children: children.map { updatedRecords[Int($0.rawValue)] }
            )
            updatedChildIndices.replaceSubrange(start..<end, with: children)
        }

        let existingStats = aggregateStats
        let updatedRoot = updatedRecords[Int(topologyArena.rootIndex.rawValue)]
        let updatedStats = ScanAggregateStats(
            totalAllocatedSize: updatedRoot.allocatedSize,
            totalLogicalSize: updatedRoot.logicalSize,
            fileCount: existingStats.fileCount,
            directoryCount: existingStats.directoryCount,
            accessibleItemCount: existingStats.accessibleItemCount,
            inaccessibleItemCount: existingStats.inaccessibleItemCount
        )
        return FileTreeStore(
            rootID: rootID,
            nodeRecords: updatedRecords,
            topologyArena: try topologyArena.replacingChildIndices(
                updatedChildIndices,
                cancellationCheck: cancellationCheck
            ),
            aggregateStats: updatedStats
        )
    }

    nonisolated func parentIndex(of index: FileTreeNodeIndex) -> FileTreeNodeIndex? {
        topologyArena.parentIndex(of: index)
    }

    nonisolated func childIndices(of index: FileTreeNodeIndex) -> [FileTreeNodeIndex] {
        Array(topologyArena.children(of: index))
    }

    nonisolated func parentID(of id: String?) -> String? {
        guard let index = nodeIndex(id: id),
              let parentIndex = topologyArena.parentIndex(of: index) else {
            return nil
        }
        return node(at: parentIndex)?.id
    }

    nonisolated func childIDs(of id: String?) -> [String] {
        let resolvedID = id ?? rootID
        guard let parentIndex = nodeIndex(id: resolvedID) else { return [] }
        return topologyArena.children(of: parentIndex).compactMap { node(at: $0)?.id }
    }

    nonisolated func parent(of id: String?) -> FileNodeRecord? {
        guard let index = nodeIndex(id: id),
              let parentIndex = topologyArena.parentIndex(of: index) else {
            return nil
        }
        return node(at: parentIndex)
    }

    nonisolated func children(of id: String?) -> [FileNodeRecord] {
        (try? children(of: id, cancellationCheck: {})) ?? []
    }

    nonisolated func childrenPrefix(of id: String?, maxCount: Int) -> [FileNodeRecord] {
        (try? childrenPrefix(of: id, maxCount: maxCount, cancellationCheck: {})) ?? []
    }

    nonisolated func children(
        of id: String?,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        let resolvedID = id ?? rootID
        guard let parentIndex = nodeIndex(id: resolvedID) else { return [] }
        let childIndices = topologyArena.children(of: parentIndex)

        var children: [FileNodeRecord] = []
        children.reserveCapacity(childIndices.count)
        for childIndex in childIndices {
            try cancellationCheck()
            if let node = node(at: childIndex) {
                children.append(node)
            }
        }
        return children
    }

    nonisolated func childrenPrefix(
        of id: String?,
        maxCount: Int,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        guard maxCount > 0 else { return [] }

        let resolvedID = id ?? rootID
        guard let parentIndex = nodeIndex(id: resolvedID) else { return [] }
        let childIndices = topologyArena.children(of: parentIndex)

        var children: [FileNodeRecord] = []
        children.reserveCapacity(min(maxCount, childIndices.count))
        for childIndex in childIndices {
            try cancellationCheck()
            if let node = node(at: childIndex) {
                children.append(node)
                if children.count == maxCount {
                    break
                }
            }
        }
        return children
    }

    nonisolated func containsChildren(id: String?) -> Bool {
        let resolvedID = id ?? rootID
        guard let index = nodeIndex(id: resolvedID) else { return false }
        return !topologyArena.children(of: index).isEmpty
    }

    nonisolated func childCount(of id: String?) -> Int {
        let resolvedID = id ?? rootID
        guard let index = nodeIndex(id: resolvedID) else { return 0 }
        return topologyArena.children(of: index).count
    }

    nonisolated func subtreeNodeCount(rootedAt nodeID: String) -> Int {
        guard let rootIndex = nodeIndex(id: nodeID) else { return 0 }
        var count = 0
        var stack = [rootIndex]
        while let nodeIndex = stack.popLast() {
            count += 1
            stack.append(contentsOf: topologyArena.children(of: nodeIndex))
        }
        return count
    }

    nonisolated func indexedNodeIDs(excludingRoot: Bool = false) -> [String] {
        topologyArena.orderedNodeIndices.compactMap { nodeIndex in
            guard !excludingRoot || nodeIndex != topologyArena.rootIndex else { return nil }
            return node(at: nodeIndex)?.id
        }
    }

    nonisolated func indexedNodeIndices() -> [FileTreeNodeIndex] {
        topologyArena.orderedNodeIndices
    }

    nonisolated func forEachIndexedNodeID(
        excludingRoot: Bool = false,
        _ body: (String) throws -> Void
    ) rethrows {
        for nodeIndex in topologyArena.orderedNodeIndices {
            if excludingRoot && nodeIndex == topologyArena.rootIndex {
                continue
            }
            if let nodeID = node(at: nodeIndex)?.id {
                try body(nodeID)
            }
        }
    }

    nonisolated func path(to id: String?) -> [FileNodeRecord] {
        guard let index = nodeIndex(id: id), let record = node(at: index) else {
            return [root]
        }

        var result: [FileNodeRecord] = [record]
        var cursor = index
        while let parentIndex = topologyArena.parentIndex(of: cursor),
              let parent = self.node(at: parentIndex) {
            result.append(parent)
            cursor = parentIndex
        }
        return result.reversed()
    }

    nonisolated func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let ancestorIndex = nodeIndex(id: ancestorID),
              let descendantIndex = nodeIndex(id: descendantID) else {
            return false
        }
        var cursor = descendantIndex
        while true {
            if cursor == ancestorIndex {
                return true
            }
            guard let parentIndex = topologyArena.parentIndex(of: cursor) else { return false }
            cursor = parentIndex
        }
    }

    nonisolated func hasAncestor(in ancestorIDs: Set<String>, of nodeID: String) -> Bool {
        hasAncestor(in: preparedNodeSet(for: ancestorIDs), of: nodeID)
    }

    nonisolated func preparedNodeSet(for nodeIDs: Set<String>) -> PreparedFileTreeNodeSet {
        PreparedFileTreeNodeSet(
            indices: Set(nodeIDs.compactMap { topologyArena.indexByNodeID[$0] })
        )
    }

    nonisolated func hasAncestor(
        in ancestorNodes: PreparedFileTreeNodeSet,
        of nodeID: String
    ) -> Bool {
        guard let nodeIndex = nodeIndex(id: nodeID) else { return false }
        return hasAncestor(in: ancestorNodes.indices, of: nodeIndex)
    }

    nonisolated func hasAncestor(
        in ancestorIndices: Set<FileTreeNodeIndex>,
        of nodeIndex: FileTreeNodeIndex
    ) -> Bool {
        var cursor = nodeIndex
        while let parentIndex = topologyArena.parentIndex(of: cursor) {
            if ancestorIndices.contains(parentIndex) {
                return true
            }
            cursor = parentIndex
        }
        return false
    }

    nonisolated func isNodeOrDescendant(_ nodeID: String, of ancestorIDs: Set<String>) -> Bool {
        isNodeOrDescendant(nodeID, of: preparedNodeSet(for: ancestorIDs))
    }

    nonisolated func isNodeOrDescendant(
        _ nodeID: String,
        of ancestorNodes: PreparedFileTreeNodeSet
    ) -> Bool {
        guard let nodeIndex = nodeIndex(id: nodeID) else { return false }
        return ancestorNodes.indices.contains(nodeIndex)
            || hasAncestor(in: ancestorNodes.indices, of: nodeIndex)
    }

    nonisolated func topLevelNodeIDs(from nodeIDs: [String]) -> [String] {
        let candidateIDs = Set(nodeIDs.filter { nodeIndex(id: $0) != nil })
        let candidateNodes = preparedNodeSet(for: candidateIDs)
        var emittedIDs = Set<String>()
        var result: [String] = []
        result.reserveCapacity(nodeIDs.count)

        for nodeID in nodeIDs where candidateIDs.contains(nodeID) && !emittedIDs.contains(nodeID) {
            guard !hasAncestor(in: candidateNodes, of: nodeID) else {
                continue
            }
            emittedIDs.insert(nodeID)
            result.append(nodeID)
        }

        return result
    }

    nonisolated func removingSubtrees(rootedAt nodeIDs: [String]) -> FileTreeStore {
        (try? removingSubtrees(rootedAt: nodeIDs, cancellationCheck: {})) ?? self
    }

    nonisolated func removingSubtrees(
        rootedAt nodeIDs: [String],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        try cancellationCheck()
        let removalIDs = topLevelNodeIDs(from: nodeIDs)
        guard !removalIDs.isEmpty else { return self }
        if removalIDs.contains(rootID) {
            return FileTreeStore(root: emptyRootNode())
        }
        let removalRootIndices = removalIDs.compactMap { nodeIndex(id: $0) }
        return try compactedStore(
            removingSubtreesAt: removalRootIndices,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated func removingSubtree(id targetID: String) -> FileTreeStore? {
        try? removingSubtree(id: targetID, cancellationCheck: {})
    }

    nonisolated func removingSubtree(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard let targetIndex = nodeIndex(id: targetID),
              parentIndex(of: targetIndex) != nil else {
            return nil
        }
        return try compactedStore(
            removingSubtreesAt: [targetIndex],
            cancellationCheck: cancellationCheck
        )
    }

    private nonisolated func compactedStore(
        removingSubtreesAt removalRootIndices: [FileTreeNodeIndex],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        var removed = Array(repeating: false, count: nodeRecords.count)
        var removedCount = 0
        for removalRootIndex in removalRootIndices {
            var stack = [removalRootIndex]
            while let currentIndex = stack.popLast() {
                try cancellationCheck()
                let currentOffset = Int(currentIndex.rawValue)
                guard !removed[currentOffset] else { continue }
                removed[currentOffset] = true
                removedCount += 1
                stack.append(contentsOf: topologyArena.children(of: currentIndex))
            }
        }
        guard removedCount > 0 else { return self }

        var affectedAncestors = Array(repeating: false, count: nodeRecords.count)
        var affectedAncestorCount = 0
        for removalRootIndex in removalRootIndices {
            var cursor = topologyArena.parentIndex(of: removalRootIndex)
            while let ancestorIndex = cursor {
                try cancellationCheck()
                let ancestorOffset = Int(ancestorIndex.rawValue)
                guard !affectedAncestors[ancestorOffset] else { break }
                affectedAncestors[ancestorOffset] = true
                affectedAncestorCount += 1
                cursor = topologyArena.parentIndex(of: ancestorIndex)
            }
        }

        var repairedRecordsByOffset: [Int: FileNodeRecord] = [:]
        repairedRecordsByOffset.reserveCapacity(affectedAncestorCount)
        var reorderedChildrenByOffset: [Int: [FileTreeNodeIndex]] = [:]
        reorderedChildrenByOffset.reserveCapacity(affectedAncestorCount)

        for oldIndex in topologyArena.orderedNodeIndices.reversed() {
            let oldOffset = Int(oldIndex.rawValue)
            guard affectedAncestors[oldOffset],
                  !removed[oldOffset],
                  nodeRecords[oldOffset].isDirectory else {
                continue
            }
            try cancellationCheck()

            var survivingChildren = topologyArena.children(of: oldIndex).filter {
                !removed[Int($0.rawValue)]
            }
            survivingChildren.sort { lhsIndex, rhsIndex in
                let lhsOffset = Int(lhsIndex.rawValue)
                let rhsOffset = Int(rhsIndex.rawValue)
                let lhs = repairedRecordsByOffset[lhsOffset] ?? nodeRecords[lhsOffset]
                let rhs = repairedRecordsByOffset[rhsOffset] ?? nodeRecords[rhsOffset]
                return Self.areInDisplayOrder(lhs, rhs)
            }
            let children = survivingChildren.map { childIndex in
                let childOffset = Int(childIndex.rawValue)
                return repairedRecordsByOffset[childOffset] ?? nodeRecords[childOffset]
            }
            repairedRecordsByOffset[oldOffset] = Self.repairingDirectoryRecord(
                nodeRecords[oldOffset],
                children: children
            )
            reorderedChildrenByOffset[oldOffset] = Array(survivingChildren)
        }

        let retainedCount = nodeRecords.count - removedCount
        var oldToNewRawIndex = Array(repeating: UInt32.max, count: nodeRecords.count)
        var compactedNodes: [FileNodeRecord] = []
        compactedNodes.reserveCapacity(retainedCount)

        for oldOffset in nodeRecords.indices where !removed[oldOffset] {
            if oldOffset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            oldToNewRawIndex[oldOffset] = UInt32(compactedNodes.count)
            compactedNodes.append(repairedRecordsByOffset[oldOffset] ?? nodeRecords[oldOffset])
        }

        let compactedRootRawIndex = oldToNewRawIndex[Int(topologyArena.rootIndex.rawValue)]
        precondition(compactedRootRawIndex != UInt32.max, "Subtree compaction removed the store root.")
        let compactedRootIndex = FileTreeNodeIndex(rawValue: compactedRootRawIndex)
        var compactedParentRawIndices = Array(repeating: UInt32.max, count: retainedCount)
        var compactedChildSpans = Array(repeating: FileTreeChildSpan(), count: retainedCount)
        var compactedChildIndices: [FileTreeNodeIndex] = []
        compactedChildIndices.reserveCapacity(max(retainedCount - 1, 0))
        var statsAccumulator = AggregateStatsAccumulator()

        for oldOffset in nodeRecords.indices where !removed[oldOffset] {
            let newOffset = Int(oldToNewRawIndex[oldOffset])
            if newOffset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let oldIndex = FileTreeNodeIndex(rawValue: UInt32(oldOffset))
            if let oldParentIndex = topologyArena.parentIndex(of: oldIndex) {
                compactedParentRawIndices[newOffset] = oldToNewRawIndex[Int(oldParentIndex.rawValue)]
            }

            let childStart = compactedChildIndices.count
            if let reorderedChildren = reorderedChildrenByOffset[oldOffset] {
                for childIndex in reorderedChildren {
                    let compactedRawIndex = oldToNewRawIndex[Int(childIndex.rawValue)]
                    guard compactedRawIndex != UInt32.max else { continue }
                    compactedChildIndices.append(FileTreeNodeIndex(rawValue: compactedRawIndex))
                }
            } else {
                for childIndex in topologyArena.children(of: oldIndex) {
                    let compactedRawIndex = oldToNewRawIndex[Int(childIndex.rawValue)]
                    guard compactedRawIndex != UInt32.max else { continue }
                    compactedChildIndices.append(FileTreeNodeIndex(rawValue: compactedRawIndex))
                }
            }
            let childCount = UInt32(compactedChildIndices.count - childStart)
            compactedChildSpans[newOffset] = FileTreeChildSpan(
                start: UInt32(childStart),
                count: childCount
            )
            statsAccumulator.include(
                compactedNodes[newOffset],
                hasMaterializedChildren: childCount > 0
            )
        }

        let compactedOrder = try FileTreeTopologyArena.preorderNodeIndices(
            rootIndex: compactedRootIndex,
            childSpans: compactedChildSpans,
            childIndices: compactedChildIndices,
            capacity: retainedCount,
            cancellationCheck: cancellationCheck
        )
        precondition(compactedOrder.count == retainedCount, "Subtree compaction produced disconnected nodes.")

        let compactedStats = statsAccumulator.stats(
            root: compactedNodes[Int(compactedRootIndex.rawValue)]
        )
        let compactedTopology = FileTreeTopologyArena(
            verifiedRootIndex: compactedRootIndex,
            nodes: compactedNodes,
            parentRawIndices: compactedParentRawIndices,
            childSpans: compactedChildSpans,
            childIndices: compactedChildIndices,
            orderedNodeIndices: compactedOrder
        )
        let compactedStore = FileTreeStore(
            rootID: rootID,
            nodeRecords: compactedNodes,
            topologyArena: compactedTopology,
            aggregateStats: compactedStats
        )
        return try HardLinkDeduplicator.rebalancedStore(
            compactedStore,
            cancellationCheck: cancellationCheck
        )
    }

    private nonisolated func emptyRootNode() -> FileNodeRecord {
        let root = root
        return FileNodeRecord(
            id: root.id,
            url: root.url,
            name: root.name,
            isDirectory: root.isDirectory,
            isSymbolicLink: root.isSymbolicLink,
            allocatedSize: 0,
            unduplicatedAllocatedSize: 0,
            dataAllocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
            cloneIdentity: root.cloneIdentity,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible,
            isSelfAccessible: root.isSelfAccessible,
            isSynthetic: root.isSynthetic,
            isAutoSummarized: root.isAutoSummarized
        )
    }

    nonisolated func replacingSubtree(id targetID: String, with replacement: FileTreeStore) -> FileTreeStore? {
        try? replacingSubtree(id: targetID, with: replacement, cancellationCheck: {})
    }

    nonisolated func replacingSubtree(
        id targetID: String,
        with replacement: FileTreeStore,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard nodeIndex(id: targetID) != nil else { return nil }

        let replacementNodesByID = replacement.nodesByID
        let replacementChildIDsByID = replacement.childIDsByID
        let replacementParentIDByID = replacement.parentIDByID
        let existingParentIDs = parentIDByID
        let existingChildIDs = childIDsByID
        let oldParentID = existingParentIDs[targetID]
        let oldSubtreeIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        try preflightReplacement(
            nodesByID: replacementNodesByID,
            removing: oldSubtreeIDs,
            cancellationCheck: cancellationCheck
        )
        var updatedNodes = nodesByID
        var updatedChildIDs = existingChildIDs
        var updatedParentIDs = existingParentIDs

        for (offset, oldID) in oldSubtreeIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: oldID)
            updatedChildIDs.removeValue(forKey: oldID)
            updatedParentIDs.removeValue(forKey: oldID)
        }

        for (offset, entry) in replacementNodesByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes[entry.key] = entry.value
        }
        for (offset, entry) in replacementChildIDsByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedChildIDs[entry.key] = entry.value
        }
        for (offset, entry) in replacementParentIDByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedParentIDs[entry.key] = entry.value
        }

        let updatedRootID: String
        if let oldParentID {
            let previousChildIDs = existingChildIDs[oldParentID] ?? []
            updatedChildIDs[oldParentID] = previousChildIDs.map { childID in
                childID == targetID ? replacement.rootID : childID
            }
            updatedParentIDs[replacement.rootID] = oldParentID
            updatedRootID = rootID
        } else {
            updatedParentIDs.removeValue(forKey: replacement.rootID)
            updatedRootID = replacement.rootID
        }

        var cursor = oldParentID
        while let currentID = cursor {
            try cancellationCheck()
            guard let current = updatedNodes[currentID] else { break }
            let childRecords = (updatedChildIDs[currentID] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[currentID] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            cursor = updatedParentIDs[currentID]
        }

        let updatedStore = FileTreeStore(
            rootID: updatedRootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    /// Replaces multiple disjoint subtrees as one topology transaction.
    ///
    /// All replacements are validated before the store is changed. Their shared
    /// ancestor chain is then rebuilt once, followed by one scan-wide hard-link
    /// rebalance so links crossing replacement boundaries remain correct.
    nonisolated func replacingSubtrees(
        _ replacements: [String: FileTreeStore]
    ) -> FileTreeStore? {
        try? replacingSubtrees(replacements, cancellationCheck: {})
    }

    nonisolated func replacingSubtrees(
        _ replacements: [String: FileTreeStore],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard !replacements.isEmpty else { return self }
        if replacements.count == 1,
           let replacement = replacements[rootID],
           replacement.rootID == rootID {
            return try HardLinkDeduplicator.rebalancedStore(
                replacement,
                cancellationCheck: cancellationCheck
            )
        }

        let existingParentIDs = parentIDByID
        let existingChildIDs = childIDsByID
        let targetIDs = Array(replacements.keys)
        for targetID in targetIDs {
            guard nodeIndex(id: targetID) != nil else { return nil }
        }

        let targetIDSet = Set(targetIDs)
        for targetID in targetIDs {
            var cursor = existingParentIDs[targetID]
            while let ancestorID = cursor {
                try cancellationCheck()
                if targetIDSet.contains(ancestorID) {
                    throw StoreError.overlappingReplacementTargets(ancestorID, targetID)
                }
                cursor = existingParentIDs[ancestorID]
            }
        }

        var plans: [SubtreeReplacementPlan] = []
        plans.reserveCapacity(replacements.count)
        for (offset, targetID) in targetIDs.enumerated() {
            if offset.isMultiple(of: 64) {
                try cancellationCheck()
            }
            guard let replacement = replacements[targetID] else { continue }
            plans.append(SubtreeReplacementPlan(
                targetID: targetID,
                oldParentID: existingParentIDs[targetID],
                oldSubtreeIDs: Set(try subtreeNodeIDs(
                    rootedAt: targetID,
                    cancellationCheck: cancellationCheck
                )),
                replacementRootID: replacement.rootID,
                replacementNodesByID: replacement.nodesByID,
                replacementChildIDsByID: replacement.childIDsByID,
                replacementParentIDByID: replacement.parentIDByID
            ))
        }

        var replacementOwnerByNodeID: [String: String] = [:]
        replacementOwnerByNodeID.reserveCapacity(plans.reduce(0) { $0 + $1.replacementNodesByID.count })
        for plan in plans {
            try preflightReplacement(
                nodesByID: plan.replacementNodesByID,
                removing: plan.oldSubtreeIDs,
                cancellationCheck: cancellationCheck
            )
            for (offset, replacementID) in plan.replacementNodesByID.keys.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                if replacementOwnerByNodeID.updateValue(plan.targetID, forKey: replacementID) != nil {
                    throw StoreError.replacementIDCollision(replacementID)
                }
            }
        }

        let removedIDs = plans.reduce(into: Set<String>()) { result, plan in
            result.formUnion(plan.oldSubtreeIDs)
        }
        var updatedNodes = nodesByID
        var updatedChildIDs = existingChildIDs
        var updatedParentIDs = existingParentIDs

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        for plan in plans {
            for (offset, entry) in plan.replacementNodesByID.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedNodes[entry.key] = entry.value
            }
            for (offset, entry) in plan.replacementChildIDsByID.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedChildIDs[entry.key] = entry.value
            }
            for (offset, entry) in plan.replacementParentIDByID.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedParentIDs[entry.key] = entry.value
            }
        }

        let replacementRootIDByTargetID = Dictionary(uniqueKeysWithValues: plans.map {
            ($0.targetID, $0.replacementRootID)
        })
        let affectedParentIDs = Set(plans.compactMap(\.oldParentID))
        for parentID in affectedParentIDs {
            try cancellationCheck()
            let previousChildIDs = existingChildIDs[parentID] ?? []
            let replacementChildIDs = previousChildIDs.compactMap { childID -> String? in
                if let replacementRootID = replacementRootIDByTargetID[childID] {
                    return replacementRootID
                }
                return removedIDs.contains(childID) ? nil : childID
            }
            if replacementChildIDs.isEmpty {
                updatedChildIDs.removeValue(forKey: parentID)
            } else {
                updatedChildIDs[parentID] = replacementChildIDs
            }
        }

        for plan in plans {
            if let oldParentID = plan.oldParentID {
                updatedParentIDs[plan.replacementRootID] = oldParentID
            } else {
                updatedParentIDs.removeValue(forKey: plan.replacementRootID)
            }
        }

        let updatedRootID: String
        if let rootPlan = plans.first(where: { $0.oldParentID == nil }) {
            updatedRootID = rootPlan.replacementRootID
        } else {
            updatedRootID = rootID
        }

        var affectedAncestorIDs = Set<String>()
        for parentID in affectedParentIDs {
            var cursor: String? = parentID
            while let currentID = cursor {
                try cancellationCheck()
                affectedAncestorIDs.insert(currentID)
                cursor = updatedParentIDs[currentID]
            }
        }

        let orderedNodeIDs = topologyArena.orderedNodeIndices.compactMap { node(at: $0)?.id }
        for currentID in orderedNodeIDs.reversed() where affectedAncestorIDs.contains(currentID) {
            try cancellationCheck()
            guard let current = updatedNodes[currentID] else { continue }
            let childRecords = (updatedChildIDs[currentID] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[currentID] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            if sortedChildRecords.isEmpty {
                updatedChildIDs.removeValue(forKey: currentID)
            } else {
                updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            }
        }

        let aggregateStats = try Self.aggregateStats(
            rootID: updatedRootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            cancellationCheck: cancellationCheck
        )
        let updatedStore = FileTreeStore(
            verifiedRootID: updatedRootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs,
            aggregateStats: aggregateStats
        )
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    private nonisolated func preflightReplacement(
        nodesByID replacementNodesByID: [String: FileNodeRecord],
        removing oldSubtreeIDs: Set<String>,
        cancellationCheck: () throws -> Void
    ) throws {
        for (offset, replacementID) in replacementNodesByID.keys.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if nodeIndex(id: replacementID) != nil && !oldSubtreeIDs.contains(replacementID) {
                throw StoreError.replacementIDCollision(replacementID)
            }
        }
    }

    private nonisolated static func aggregateStats(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        cancellationCheck: () throws -> Void
    ) throws -> ScanAggregateStats {
        guard let root = nodesByID[rootID] else {
            preconditionFailure("Verified FileTreeStore root is missing.")
        }

        var accumulator = AggregateStatsAccumulator()
        for (offset, node) in nodesByID.values.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            accumulator.include(
                node,
                hasMaterializedChildren: childIDsByID[node.id]?.isEmpty == false
            )
        }

        return accumulator.stats(root: root)
    }

    nonisolated func subtree(rootedAt targetID: String) -> FileTreeStore? {
        try? subtree(rootedAt: targetID, cancellationCheck: {})
    }

    nonisolated func subtree(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        guard let contents = try subtreeContents(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        var parentIDsByID: [String: String] = [:]
        parentIDsByID.reserveCapacity(max(contents.nodesByID.count - 1, 0))
        var visitedChildCount = 0
        for (parentID, childIDs) in contents.childIDsByID {
            for childID in childIDs {
                if visitedChildCount.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                parentIDsByID[childID] = parentID
                visitedChildCount += 1
            }
        }
        let scopedStore = FileTreeStore(
            rootID: targetID,
            nodesByID: contents.nodesByID,
            childIDsByID: contents.childIDsByID,
            parentIDByID: parentIDsByID
        )
        return try HardLinkDeduplicator.rebalancedStore(scopedStore, cancellationCheck: cancellationCheck)
    }

    nonisolated func subtreeContents(rootedAt targetID: String) -> FileTreeSubtreeContents? {
        try? subtreeContents(rootedAt: targetID, cancellationCheck: {})
    }

    nonisolated func subtreeContents(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeSubtreeContents? {
        try cancellationCheck()
        guard let targetIndex = nodeIndex(id: targetID) else { return nil }

        var scopedNodes: [String: FileNodeRecord] = [:]
        var scopedChildIDs: [String: [String]] = [:]
        var stack = [targetIndex]

        while let currentIndex = stack.popLast() {
            try cancellationCheck()
            guard let record = node(at: currentIndex) else { continue }
            let currentID = record.id
            scopedNodes[currentID] = record

            let childIndices = topologyArena.children(of: currentIndex)
            guard !childIndices.isEmpty else { continue }

            var scopedChildren: [String] = []
            scopedChildren.reserveCapacity(childIndices.count)
            for (offset, childIndex) in childIndices.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                guard let childID = self.node(at: childIndex)?.id else { continue }
                scopedChildren.append(childID)
                stack.append(childIndex)
            }

            if !scopedChildren.isEmpty {
                scopedChildIDs[currentID] = scopedChildren
            }
        }

        guard let root = scopedNodes[targetID] else { return nil }
        return FileTreeSubtreeContents(
            root: root,
            nodesByID: scopedNodes,
            childIDsByID: scopedChildIDs
        )
    }

    nonisolated func subtreeNodeIDs(rootedAt id: String) -> [String] {
        (try? subtreeNodeIDs(rootedAt: id, cancellationCheck: {})) ?? []
    }

    private nonisolated func subtreeNodeIDs(
        rootedAt id: String,
        cancellationCheck: () throws -> Void
    ) throws -> [String] {
        guard let rootIndex = nodeIndex(id: id) else { return [] }
        var result: [String] = []
        var stack = [rootIndex]

        while let currentIndex = stack.popLast() {
            try cancellationCheck()
            guard let currentID = node(at: currentIndex)?.id else { continue }
            result.append(currentID)
            stack.append(contentsOf: topologyArena.children(of: currentIndex))
        }

        return result
    }

    private nonisolated static func sanitizedTopology(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]]
    ) -> SanitizedTopology {
        guard let root = inputNodesByID[rootID] else {
            return SanitizedTopology(
                nodesByID: inputNodesByID,
                childIDsByID: inputChildIDsByID,
                orderedNodeIDs: [],
                materializedDirectoryIDs: [],
                didDropReferences: true
            )
        }

        var nodesByID = [rootID: root]
        var childIDsByID: [String: [String]] = [:]
        var orderedNodeIDs: [String] = []
        var materializedDirectoryIDs = Set<String>()
        var visited: Set<String> = [rootID]
        var stack = [rootID]

        while let parentID = stack.popLast() {
            orderedNodeIDs.append(parentID)
            guard let childIDs = inputChildIDsByID[parentID] else { continue }
            if inputNodesByID[parentID]?.isDirectory == true {
                materializedDirectoryIDs.insert(parentID)
            }
            guard !childIDs.isEmpty else { continue }

            var sanitizedChildIDs: [String] = []
            sanitizedChildIDs.reserveCapacity(childIDs.count)
            for childID in childIDs {
                guard let child = inputNodesByID[childID] else { continue }
                guard visited.insert(childID).inserted else { continue }
                nodesByID[childID] = child
                sanitizedChildIDs.append(childID)
            }

            if !sanitizedChildIDs.isEmpty {
                childIDsByID[parentID] = sanitizedChildIDs
                stack.append(contentsOf: sanitizedChildIDs.reversed())
            }
        }

        let materializedInputChildIDsByID = inputChildIDsByID.filter { !$0.value.isEmpty }
        let didDropReferences =
            nodesByID.count != inputNodesByID.count ||
            childIDsByID != materializedInputChildIDsByID

        return SanitizedTopology(
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            orderedNodeIDs: orderedNodeIDs,
            materializedDirectoryIDs: materializedDirectoryIDs,
            didDropReferences: didDropReferences
        )
    }

    private nonisolated static func orderedNodeIDsAssumingValidTopology(
        rootID: String,
        childIDsByID: [String: [String]],
        nodeCount: Int
    ) -> [String] {
        var orderedNodeIDs: [String] = []
        orderedNodeIDs.reserveCapacity(nodeCount)
        var stack = [rootID]

        while let nodeID = stack.popLast() {
            orderedNodeIDs.append(nodeID)
            if let childIDs = childIDsByID[nodeID] {
                stack.append(contentsOf: childIDs.reversed())
            }
        }
        return orderedNodeIDs
    }

    private nonisolated static func repairMaterializedDirectoryTotals(
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        orderedNodeIDs: [String],
        materializedDirectoryIDs: Set<String>
    ) -> [String: FileNodeRecord] {
        guard !materializedDirectoryIDs.isEmpty else { return nodesByID }

        var repairedNodes = nodesByID
        for nodeID in orderedNodeIDs.reversed() where materializedDirectoryIDs.contains(nodeID) {
            guard let node = repairedNodes[nodeID], node.isDirectory else { continue }
            let childIDs = childIDsByID[nodeID] ?? []
            let children = childIDs.compactMap { repairedNodes[$0] }
            repairedNodes[nodeID] = repairingDirectoryRecord(node, children: children)
        }
        return repairedNodes
    }

    private nonisolated static func repairingDirectoryRecord<Children: Sequence>(
        _ node: FileNodeRecord,
        children: Children
    ) -> FileNodeRecord where Children.Element == FileNodeRecord {
        var totals = MaterializedDirectoryTotals()
        for child in children {
            totals.include(child)
        }
        return repairingDirectoryRecord(node, totals: totals)
    }

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        childIndices: ArraySlice<FileTreeNodeIndex>,
        nodes: [FileNodeRecord]
    ) -> FileNodeRecord {
        var totals = MaterializedDirectoryTotals()
        for childIndex in childIndices {
            totals.include(nodes[Int(childIndex.rawValue)])
        }
        return repairingDirectoryRecord(node, totals: totals)
    }

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        totals: MaterializedDirectoryTotals
    ) -> FileNodeRecord {
        return FileNodeRecord(
            id: node.id,
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            allocatedSize: totals.allocatedSize,
            logicalSize: totals.logicalSize,
            descendantFileCount: totals.descendantFileCount,
            lastModified: node.lastModified,
            fileIdentity: node.fileIdentity,
            linkCount: node.linkCount,
            isPackage: node.isPackage,
            isAccessible: node.isSelfAccessible && totals.childrenAreAccessible,
            isSelfAccessible: node.isSelfAccessible,
            isSynthetic: node.isSynthetic,
            isAutoSummarized: node.isAutoSummarized
        )
    }

    /// Tree totals originate from filesystem metadata and imported archives. A
    /// malformed archive can contain individually valid nonnegative values whose
    /// sum exceeds the integer representation; clamp instead of trapping while
    /// rebuilding a safe in-memory tree.
    private nonisolated static func saturatingAdd<Value: FixedWidthInteger>(
        _ lhs: Value,
        _ rhs: Value
    ) -> Value {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= .zero ? .max : .min
    }
}
