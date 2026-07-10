//
//  FileTreeStore.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

struct FileTreeStore: Sendable {
    let contentID: UUID
    let rootID: String
    let nodesByID: [String: FileNodeRecord]
    let childIDsByID: [String: [String]]
    let parentIDByID: [String: String]
    private let orderedNodeIDs: [String]
    private let precomputedAggregateStats: ScanAggregateStats?

    private struct SanitizedTopology {
        let nodesByID: [String: FileNodeRecord]
        let childIDsByID: [String: [String]]
        let parentIDByID: [String: String]
        let orderedNodeIDs: [String]
        let materializedDirectoryIDs: Set<String>
        let didDropReferences: Bool
    }

    private struct SubtreeReplacementPlan {
        let targetID: String
        let oldParentID: String?
        let oldSubtreeIDs: Set<String>
        let replacement: FileTreeStore
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
        guard let root = nodesByID[rootID] else {
            preconditionFailure("FileTreeStore rootID does not exist in nodesByID.")
        }
        return root
    }

    nonisolated var nodeCount: Int {
        nodesByID.count
    }

    nonisolated var aggregateStats: ScanAggregateStats {
        if let precomputedAggregateStats {
            return precomputedAggregateStats
        }

        return computedAggregateStats()
    }

    private nonisolated func computedAggregateStats() -> ScanAggregateStats {
        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0

        for nodeID in orderedNodeIDs {
            guard let node = nodesByID[nodeID] else { continue }

            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && !containsChildren(id: node.id) {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
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
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        let topology = Self.sanitizedTopology(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        self.contentID = UUID()
        self.rootID = rootID
        self.nodesByID = topology.didDropReferences || aggregateStats == nil
            ? Self.repairMaterializedDirectoryTotals(
                nodesByID: topology.nodesByID,
                childIDsByID: topology.childIDsByID,
                orderedNodeIDs: topology.orderedNodeIDs,
                materializedDirectoryIDs: topology.materializedDirectoryIDs
            )
            : topology.nodesByID
        self.childIDsByID = topology.childIDsByID
        self.parentIDByID = topology.parentIDByID
        self.precomputedAggregateStats = topology.didDropReferences ? nil : aggregateStats
        self.orderedNodeIDs = topology.orderedNodeIDs
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
        self.nodesByID = nodesByID
        self.childIDsByID = childIDsByID
        self.parentIDByID = parentIDByID
        self.precomputedAggregateStats = aggregateStats
        self.orderedNodeIDs = Self.orderedNodeIDsAssumingValidTopology(
            rootID: rootID,
            childIDsByID: childIDsByID,
            nodeCount: nodesByID.count
        )
        assert(self.orderedNodeIDs.count == nodesByID.count)
    }

    nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        var sortedChildren = children
        sortChildren(&sortedChildren)
        return sortedChildren
    }

    nonisolated static func sortChildren(_ children: inout [FileNodeRecord]) {
        guard children.count > 1 else { return }

        children.sort { lhs, rhs in
            if lhs.allocatedSize == rhs.allocatedSize {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedSize > rhs.allocatedSize
        }
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
        guard let id else { return nil }
        return nodesByID[id]
    }

    nonisolated func parent(of id: String?) -> FileNodeRecord? {
        guard let id, let parentID = parentIDByID[id] else { return nil }
        return nodesByID[parentID]
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
        guard let childIDs = childIDsByID[resolvedID] else { return [] }

        var children: [FileNodeRecord] = []
        children.reserveCapacity(childIDs.count)
        for childID in childIDs {
            try cancellationCheck()
            if let node = nodesByID[childID] {
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
        guard let childIDs = childIDsByID[resolvedID] else { return [] }

        var children: [FileNodeRecord] = []
        children.reserveCapacity(min(maxCount, childIDs.count))
        for childID in childIDs {
            try cancellationCheck()
            if let node = nodesByID[childID] {
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
        return childIDsByID[resolvedID]?.isEmpty == false
    }

    nonisolated func indexedNodeIDs(excludingRoot: Bool = false) -> [String] {
        guard excludingRoot else {
            return orderedNodeIDs
        }
        return orderedNodeIDs.filter { $0 != rootID }
    }

    nonisolated func forEachIndexedNodeID(
        excludingRoot: Bool = false,
        _ body: (String) throws -> Void
    ) rethrows {
        for nodeID in orderedNodeIDs {
            if excludingRoot && nodeID == rootID {
                continue
            }
            try body(nodeID)
        }
    }

    nonisolated func path(to id: String?) -> [FileNodeRecord] {
        guard let id, let node = nodesByID[id] else {
            return [root]
        }

        var result: [FileNodeRecord] = [node]
        var cursor = id
        while let parentID = parentIDByID[cursor], let parent = nodesByID[parentID] {
            result.append(parent)
            cursor = parentID
        }
        return result.reversed()
    }

    nonisolated func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let descendantID else { return false }
        if ancestorID == descendantID {
            return true
        }

        var cursor = descendantID
        while let parentID = parentIDByID[cursor] {
            if parentID == ancestorID {
                return true
            }
            cursor = parentID
        }
        return false
    }

    nonisolated func hasAncestor(in ancestorIDs: Set<String>, of nodeID: String) -> Bool {
        var cursor = nodeID
        while let parentID = parentIDByID[cursor] {
            if ancestorIDs.contains(parentID) {
                return true
            }
            cursor = parentID
        }
        return false
    }

    nonisolated func isNodeOrDescendant(_ nodeID: String, of ancestorIDs: Set<String>) -> Bool {
        ancestorIDs.contains(nodeID) || hasAncestor(in: ancestorIDs, of: nodeID)
    }

    nonisolated func topLevelNodeIDs(from nodeIDs: [String]) -> [String] {
        let candidateIDs = Set(nodeIDs.filter { nodesByID[$0] != nil })
        var emittedIDs = Set<String>()
        var result: [String] = []
        result.reserveCapacity(nodeIDs.count)

        for nodeID in nodeIDs where candidateIDs.contains(nodeID) && !emittedIDs.contains(nodeID) {
            guard !hasAncestor(in: candidateIDs, of: nodeID) else {
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

        var removedIDs = Set<String>()
        for removalID in removalIDs {
            try cancellationCheck()
            guard nodesByID[removalID] != nil else { continue }
            removedIDs.formUnion(try subtreeNodeIDs(
                rootedAt: removalID,
                cancellationCheck: cancellationCheck
            ))
        }
        guard !removedIDs.isEmpty else { return self }

        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        for (offset, entry) in childIDsByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard !removedIDs.contains(entry.key) else { continue }
            updatedChildIDs[entry.key] = entry.value.filter { !removedIDs.contains($0) }
        }

        let updatedStore = FileTreeStore(
            rootID: rootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    nonisolated func removingSubtree(id targetID: String) -> FileTreeStore? {
        try? removingSubtree(id: targetID, cancellationCheck: {})
    }

    nonisolated func removingSubtree(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard nodesByID[targetID] != nil,
              let parentID = parentIDByID[targetID] else {
            return nil
        }

        let removedIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        let remainingParentChildIDs = (updatedChildIDs[parentID] ?? []).filter { !removedIDs.contains($0) }
        if remainingParentChildIDs.isEmpty {
            updatedChildIDs.removeValue(forKey: parentID)
        } else {
            updatedChildIDs[parentID] = remainingParentChildIDs
        }

        var cursor: String? = parentID
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
            if sortedChildRecords.isEmpty {
                updatedChildIDs.removeValue(forKey: currentID)
            } else {
                updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            }
            cursor = updatedParentIDs[currentID]
        }

        let updatedStore = FileTreeStore(
            rootID: rootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
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
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
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
        guard nodesByID[targetID] != nil else { return nil }

        let oldParentID = parentIDByID[targetID]
        let oldSubtreeIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        try preflightReplacement(
            replacement,
            removing: oldSubtreeIDs,
            cancellationCheck: cancellationCheck
        )
        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, oldID) in oldSubtreeIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: oldID)
            updatedChildIDs.removeValue(forKey: oldID)
            updatedParentIDs.removeValue(forKey: oldID)
        }

        for (offset, entry) in replacement.nodesByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes[entry.key] = entry.value
        }
        for (offset, entry) in replacement.childIDsByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedChildIDs[entry.key] = entry.value
        }
        for (offset, entry) in replacement.parentIDByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedParentIDs[entry.key] = entry.value
        }

        let updatedRootID: String
        if let oldParentID {
            let previousChildIDs = childIDsByID[oldParentID] ?? []
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

        let targetIDs = Array(replacements.keys)
        for targetID in targetIDs {
            guard nodesByID[targetID] != nil else { return nil }
        }

        let targetIDSet = Set(targetIDs)
        for targetID in targetIDs {
            var cursor = parentIDByID[targetID]
            while let ancestorID = cursor {
                try cancellationCheck()
                if targetIDSet.contains(ancestorID) {
                    throw StoreError.overlappingReplacementTargets(ancestorID, targetID)
                }
                cursor = parentIDByID[ancestorID]
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
                oldParentID: parentIDByID[targetID],
                oldSubtreeIDs: Set(try subtreeNodeIDs(
                    rootedAt: targetID,
                    cancellationCheck: cancellationCheck
                )),
                replacement: replacement
            ))
        }

        var replacementOwnerByNodeID: [String: String] = [:]
        replacementOwnerByNodeID.reserveCapacity(plans.reduce(0) { $0 + $1.replacement.nodeCount })
        for plan in plans {
            try preflightReplacement(
                plan.replacement,
                removing: plan.oldSubtreeIDs,
                cancellationCheck: cancellationCheck
            )
            for (offset, replacementID) in plan.replacement.nodesByID.keys.enumerated() {
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
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        for plan in plans {
            for (offset, entry) in plan.replacement.nodesByID.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedNodes[entry.key] = entry.value
            }
            for (offset, entry) in plan.replacement.childIDsByID.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedChildIDs[entry.key] = entry.value
            }
            for (offset, entry) in plan.replacement.parentIDByID.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedParentIDs[entry.key] = entry.value
            }
        }

        let replacementRootIDByTargetID = Dictionary(uniqueKeysWithValues: plans.map {
            ($0.targetID, $0.replacement.rootID)
        })
        let affectedParentIDs = Set(plans.compactMap(\.oldParentID))
        for parentID in affectedParentIDs {
            try cancellationCheck()
            let previousChildIDs = childIDsByID[parentID] ?? []
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
                updatedParentIDs[plan.replacement.rootID] = oldParentID
            } else {
                updatedParentIDs.removeValue(forKey: plan.replacement.rootID)
            }
        }

        let updatedRootID: String
        if let rootPlan = plans.first(where: { $0.oldParentID == nil }) {
            updatedRootID = rootPlan.replacement.rootID
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
        _ replacement: FileTreeStore,
        removing oldSubtreeIDs: Set<String>,
        cancellationCheck: () throws -> Void
    ) throws {
        for (offset, replacementID) in replacement.nodesByID.keys.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if nodesByID[replacementID] != nil && !oldSubtreeIDs.contains(replacementID) {
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

        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0
        for (offset, node) in nodesByID.values.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && childIDsByID[node.id]?.isEmpty != false {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
    }

    nonisolated func subtree(rootedAt targetID: String) -> FileTreeStore? {
        try? subtree(rootedAt: targetID, cancellationCheck: {})
    }

    nonisolated func subtree(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard nodesByID[targetID] != nil else { return nil }

        var scopedNodes: [String: FileNodeRecord] = [:]
        var scopedChildIDs: [String: [String]] = [:]
        var scopedParentIDs: [String: String] = [:]
        var stack = [targetID]

        while let currentID = stack.popLast() {
            try cancellationCheck()
            guard let node = nodesByID[currentID] else { continue }
            scopedNodes[currentID] = node

            let childIDs = childIDsByID[currentID] ?? []
            guard !childIDs.isEmpty else { continue }

            var scopedChildren: [String] = []
            scopedChildren.reserveCapacity(childIDs.count)
            for (offset, childID) in childIDs.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                guard nodesByID[childID] != nil else { continue }
                scopedChildren.append(childID)
                scopedParentIDs[childID] = currentID
                stack.append(childID)
            }

            if !scopedChildren.isEmpty {
                scopedChildIDs[currentID] = scopedChildren
            }
        }

        let scopedStore = FileTreeStore(
            rootID: targetID,
            nodesByID: scopedNodes,
            childIDsByID: scopedChildIDs,
            parentIDByID: scopedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(scopedStore, cancellationCheck: cancellationCheck)
    }

    private nonisolated func subtreeNodeIDs(rootedAt id: String) -> [String] {
        (try? subtreeNodeIDs(rootedAt: id, cancellationCheck: {})) ?? []
    }

    private nonisolated func subtreeNodeIDs(
        rootedAt id: String,
        cancellationCheck: () throws -> Void
    ) throws -> [String] {
        var result: [String] = []
        var stack = [id]

        while let currentID = stack.popLast() {
            try cancellationCheck()
            result.append(currentID)
            let childIDs = childIDsByID[currentID] ?? []
            stack.append(contentsOf: childIDs)
        }

        return result
    }

    private nonisolated static func makeOrderedNodeIDs(
        rootID: String,
        childIDsByID: [String: [String]],
        nodesByID: [String: FileNodeRecord]
    ) -> [String] {
        guard nodesByID[rootID] != nil else { return [] }
        var result: [String] = []
        var stack: [String] = [rootID]
        var visited: Set<String> = []

        while let nodeID = stack.popLast() {
            guard nodesByID[nodeID] != nil, visited.insert(nodeID).inserted else { continue }
            result.append(nodeID)
            stack.append(contentsOf: (childIDsByID[nodeID] ?? []).reversed())
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
                parentIDByID: [:],
                orderedNodeIDs: [],
                materializedDirectoryIDs: [],
                didDropReferences: true
            )
        }

        var nodesByID = [rootID: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
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
                parentIDByID[childID] = parentID
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
            parentIDByID: parentIDByID,
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

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        children: [FileNodeRecord]
    ) -> FileNodeRecord {
        let allocatedSize = children.reduce(into: Int64(0)) { result, child in
            result += child.allocatedSize
        }
        let logicalSize = children.reduce(into: Int64(0)) { result, child in
            result += child.logicalSize
        }
        let descendantFileCount = children.reduce(into: 0) { result, child in
            if child.isDirectory {
                result += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                result += 1
            }
        }

        return FileNodeRecord(
            id: node.id,
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: node.lastModified,
            fileIdentity: node.fileIdentity,
            linkCount: node.linkCount,
            isPackage: node.isPackage,
            isAccessible: node.isSelfAccessible && children.allSatisfy(\.isAccessible),
            isSelfAccessible: node.isSelfAccessible,
            isSynthetic: node.isSynthetic,
            isAutoSummarized: node.isAutoSummarized
        )
    }
}
