//
//  HardLinkDeduplicator.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated struct HardLinkDeduplicator {
    nonisolated static func claim(
        for metadata: NodeMetadata,
        ownerNodeID: String,
        path: String
    ) -> HardLinkClaim? {
        guard !metadata.isDirectory,
              !metadata.isSymbolicLink,
              metadata.linkCount > 1,
              let fileIdentity = metadata.fileIdentity else {
            return nil
        }

        return HardLinkClaim(
            identity: fileIdentity,
            ownerNodeID: ownerNodeID,
            path: path,
            allocatedSize: metadata.allocatedSize
        )
    }

    nonisolated static func deduplicatedStore(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        deduplicatedStore(
            rootID: rootID,
            nodesByID: inputNodesByID,
            childIDsByID: inputChildIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: aggregateStats,
            hardLinkAccumulator: HardLinkIdentityOwnerAccumulator(hardLinkClaims),
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
    }

    nonisolated static func deduplicatedStore(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats,
        hardLinkAccumulator: HardLinkIdentityOwnerAccumulator,
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        let duplicateAllocatedSizeByOwner = hardLinkAccumulator.duplicateAllocatedSizeByOwner
        guard !duplicateAllocatedSizeByOwner.isEmpty else {
            return FileTreeStore(
                verifiedRootID: rootID,
                nodesByID: inputNodesByID,
                childIDsByID: inputChildIDsByID,
                parentIDByID: parentIDByID,
                aggregateStats: aggregateStats
            )
        }

        var nodesByID = inputNodesByID
        var childIDsByID = inputChildIDsByID
        var changedNodeIDs: Set<String> = []

        for (nodeID, duplicateAllocatedSize) in duplicateAllocatedSizeByOwner {
            guard let node = nodesByID[nodeID] else { continue }
            let minimumAllocatedSize = minimumAllocatedSizeByNodeID[nodeID] ?? 0
            let allocatedSize = max(minimumAllocatedSize, node.allocatedSize - duplicateAllocatedSize)
            nodesByID[nodeID] = node.replacingAllocatedSize(allocatedSize)
            changedNodeIDs.insert(nodeID)
        }

        rebuildAffectedAncestorDirectories(
            for: changedNodeIDs,
            nodesByID: &nodesByID,
            childIDsByID: &childIDsByID,
            parentIDByID: parentIDByID,
            cancellationCheck: {}
        )

        let root = nodesByID[rootID] ?? inputNodesByID[rootID]
        let deduplicatedStats = ScanAggregateStats(
            totalAllocatedSize: root?.allocatedSize ?? aggregateStats.totalAllocatedSize,
            totalLogicalSize: root?.logicalSize ?? aggregateStats.totalLogicalSize,
            fileCount: aggregateStats.fileCount,
            directoryCount: aggregateStats.directoryCount,
            accessibleItemCount: aggregateStats.accessibleItemCount,
            inaccessibleItemCount: aggregateStats.inaccessibleItemCount
        )

        return FileTreeStore(
            verifiedRootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: deduplicatedStats
        )
    }

    /// Scanner fast path. The scan already owns a verified integer topology, so
    /// hard-link correction stays index-based instead of materializing three
    /// full-path-keyed dictionaries before constructing the compact store.
    nonisolated static func deduplicatedStore(
        rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        childIndicesByIndex: [[FileTreeNodeIndex]],
        parentIndices: [FileTreeNodeIndex?],
        orderedNodeIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        deduplicatedStore(
            rootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: aggregateStats,
            hardLinkAccumulator: HardLinkIdentityOwnerAccumulator(hardLinkClaims),
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
    }

    nonisolated static func deduplicatedStore(
        rootIndex: FileTreeNodeIndex,
        nodes inputNodes: [FileNodeRecord],
        childIndicesByIndex inputChildIndicesByIndex: [[FileTreeNodeIndex]],
        parentIndices: [FileTreeNodeIndex?],
        orderedNodeIndices inputOrderedNodeIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats,
        hardLinkAccumulator: HardLinkIdentityOwnerAccumulator,
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        let duplicateAllocatedSizeByOwner = hardLinkAccumulator.duplicateAllocatedSizeByOwner
        guard !duplicateAllocatedSizeByOwner.isEmpty else {
            return FileTreeStore(
                verifiedRootIndex: rootIndex,
                nodes: inputNodes,
                childIndicesByIndex: inputChildIndicesByIndex,
                parentIndices: parentIndices,
                orderedNodeIndices: inputOrderedNodeIndices,
                aggregateStats: aggregateStats
            )
        }

        var nodes = inputNodes
        var childIndicesByIndex = inputChildIndicesByIndex
        let duplicateOwnerIDs = Set(duplicateAllocatedSizeByOwner.keys)
        var nodeIndexByDuplicateOwnerID: [String: Int] = [:]
        nodeIndexByDuplicateOwnerID.reserveCapacity(duplicateOwnerIDs.count)
        for (index, node) in nodes.enumerated() where duplicateOwnerIDs.contains(node.id) {
            nodeIndexByDuplicateOwnerID[node.id] = index
        }

        var changedNodeIndices = Set<Int>()
        changedNodeIndices.reserveCapacity(duplicateAllocatedSizeByOwner.count)
        for (nodeID, duplicateAllocatedSize) in duplicateAllocatedSizeByOwner {
            guard let nodeIndex = nodeIndexByDuplicateOwnerID[nodeID] else { continue }
            let node = nodes[nodeIndex]
            let minimumAllocatedSize = minimumAllocatedSizeByNodeID[nodeID] ?? 0
            let allocatedSize = max(minimumAllocatedSize, node.allocatedSize - duplicateAllocatedSize)
            nodes[nodeIndex] = node.replacingAllocatedSize(allocatedSize)
            changedNodeIndices.insert(nodeIndex)
        }

        rebuildAffectedAncestorDirectories(
            for: changedNodeIndices,
            nodes: &nodes,
            childIndicesByIndex: &childIndicesByIndex,
            parentIndices: parentIndices
        )

        let orderedNodeIndices = preorderNodeIndices(
            rootIndex: rootIndex,
            childIndicesByIndex: childIndicesByIndex,
            capacity: nodes.count
        )
        let root = nodes[Int(rootIndex.rawValue)]
        let deduplicatedStats = ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: aggregateStats.fileCount,
            directoryCount: aggregateStats.directoryCount,
            accessibleItemCount: aggregateStats.accessibleItemCount,
            inaccessibleItemCount: aggregateStats.inaccessibleItemCount
        )

        return FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: deduplicatedStats
        )
    }

    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        var hardLinkAccumulator = HardLinkIdentityOwnerAccumulator()

        for (offset, nodeID) in store.indexedNodeIDs().enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard let node = store.node(id: nodeID),
                  let claim = claim(for: node) else {
                continue
            }
            hardLinkAccumulator.record(claim)
        }

        guard !hardLinkAccumulator.isEmpty else { return store }

        var nodesByID = store.nodesByID
        var childIDsByID = store.childIDsByID
        var changedNodeIDs: Set<String> = []
        for (offset, nodeID) in store.indexedNodeIDs().enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard let node = nodesByID[nodeID], claim(for: node) != nil else {
                continue
            }
            let duplicateAllocatedSize = hardLinkAccumulator.duplicateAllocatedSizeByOwner[nodeID] ?? 0
            let targetAllocatedSize = max(0, node.unduplicatedAllocatedSize - duplicateAllocatedSize)
            guard node.allocatedSize != targetAllocatedSize else { continue }
            nodesByID[nodeID] = node.replacingAllocatedSize(targetAllocatedSize)
            changedNodeIDs.insert(nodeID)
        }

        try rebuildAffectedAncestorDirectories(
            for: changedNodeIDs,
            nodesByID: &nodesByID,
            childIDsByID: &childIDsByID,
            parentIDByID: store.parentIDByID,
            cancellationCheck: cancellationCheck
        )

        return FileTreeStore(
            rootID: store.rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: store.parentIDByID
        )
    }

    private nonisolated static func rebuildAffectedAncestorDirectories(
        for changedNodeIDs: Set<String>,
        nodesByID: inout [String: FileNodeRecord],
        childIDsByID: inout [String: [String]],
        parentIDByID: [String: String],
        cancellationCheck: () throws -> Void = {}
    ) rethrows {
        let affectedDirectoryIDs = affectedAncestorDirectoryIDs(
            for: changedNodeIDs,
            nodesByID: nodesByID,
            parentIDByID: parentIDByID
        )
        for nodeID in affectedDirectoryIDs {
            try cancellationCheck()
            guard let node = nodesByID[nodeID], node.isDirectory else { continue }
            let children = (childIDsByID[nodeID] ?? []).compactMap { nodesByID[$0] }
            let sortedChildren = FileTreeStore.sortedChildren(children)
            nodesByID[nodeID] = FileNodeRecord.directory(
                id: node.id,
                url: node.url,
                name: node.name,
                children: sortedChildren,
                lastModified: node.lastModified,
                fileIdentity: node.fileIdentity,
                linkCount: node.linkCount,
                isPackage: node.isPackage,
                isAccessible: node.isSelfAccessible,
                childrenAreSorted: true
            )
            childIDsByID[nodeID] = sortedChildren.map(\.id)
        }
    }

    private nonisolated static func rebuildAffectedAncestorDirectories(
        for changedNodeIndices: Set<Int>,
        nodes: inout [FileNodeRecord],
        childIndicesByIndex: inout [[FileTreeNodeIndex]],
        parentIndices: [FileTreeNodeIndex?]
    ) {
        guard !changedNodeIndices.isEmpty else { return }

        var affectedDirectoryIndices = Set<Int>()
        var visitedAncestorIndices = Set<Int>()
        for changedNodeIndex in changedNodeIndices {
            var cursor = parentIndices[changedNodeIndex]
            while let currentIndex = cursor {
                let rawIndex = Int(currentIndex.rawValue)
                guard visitedAncestorIndices.insert(rawIndex).inserted else { break }
                if nodes[rawIndex].isDirectory {
                    affectedDirectoryIndices.insert(rawIndex)
                }
                cursor = parentIndices[rawIndex]
            }
        }

        var depthByDirectoryIndex: [Int: Int] = [:]
        depthByDirectoryIndex.reserveCapacity(affectedDirectoryIndices.count)
        for directoryIndex in affectedDirectoryIndices {
            var depth = 0
            var cursor = parentIndices[directoryIndex]
            while let currentIndex = cursor {
                depth += 1
                cursor = parentIndices[Int(currentIndex.rawValue)]
            }
            depthByDirectoryIndex[directoryIndex] = depth
        }

        let deepestFirst = affectedDirectoryIndices.sorted { lhs, rhs in
            let lhsDepth = depthByDirectoryIndex[lhs] ?? 0
            let rhsDepth = depthByDirectoryIndex[rhs] ?? 0
            if lhsDepth == rhsDepth {
                return lhs < rhs
            }
            return lhsDepth > rhsDepth
        }

        for nodeIndex in deepestFirst {
            let node = nodes[nodeIndex]
            guard node.isDirectory else { continue }
            var childIndices = childIndicesByIndex[nodeIndex]
            childIndices.sort { lhsIndex, rhsIndex in
                let lhs = nodes[Int(lhsIndex.rawValue)]
                let rhs = nodes[Int(rhsIndex.rawValue)]
                if lhs.allocatedSize == rhs.allocatedSize {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.allocatedSize > rhs.allocatedSize
            }
            let children = childIndices.map { nodes[Int($0.rawValue)] }
            nodes[nodeIndex] = FileNodeRecord.directory(
                id: node.id,
                url: node.url,
                name: node.name,
                children: children,
                lastModified: node.lastModified,
                fileIdentity: node.fileIdentity,
                linkCount: node.linkCount,
                isPackage: node.isPackage,
                isAccessible: node.isSelfAccessible,
                childrenAreSorted: true
            )
            childIndicesByIndex[nodeIndex] = childIndices
        }
    }

    private nonisolated static func preorderNodeIndices(
        rootIndex: FileTreeNodeIndex,
        childIndicesByIndex: [[FileTreeNodeIndex]],
        capacity: Int
    ) -> [FileTreeNodeIndex] {
        var result: [FileTreeNodeIndex] = []
        result.reserveCapacity(capacity)
        var stack = [rootIndex]
        while let nodeIndex = stack.popLast() {
            result.append(nodeIndex)
            let children = childIndicesByIndex[Int(nodeIndex.rawValue)]
            stack.append(contentsOf: children.reversed())
        }
        return result
    }

    private nonisolated static func claim(for node: FileNodeRecord) -> HardLinkClaim? {
        guard !node.isDirectory,
              !node.isSymbolicLink,
              !node.isSynthetic,
              node.linkCount > 1,
              let fileIdentity = node.fileIdentity else {
            return nil
        }

        return HardLinkClaim(
            identity: fileIdentity,
            ownerNodeID: node.id,
            path: node.url.path,
            allocatedSize: node.unduplicatedAllocatedSize
        )
    }

    private nonisolated static func affectedAncestorDirectoryIDs(
        for changedNodeIDs: Set<String>,
        nodesByID: [String: FileNodeRecord],
        parentIDByID: [String: String]
    ) -> [String] {
        guard !changedNodeIDs.isEmpty else { return [] }

        var affectedDirectoryIDs = Set<String>()
        var visitedAncestorIDs = Set<String>()
        for changedNodeID in changedNodeIDs {
            var cursor = parentIDByID[changedNodeID]
            while let currentID = cursor {
                guard visitedAncestorIDs.insert(currentID).inserted else { break }
                if nodesByID[currentID]?.isDirectory == true {
                    affectedDirectoryIDs.insert(currentID)
                }
                cursor = parentIDByID[currentID]
            }
        }

        var depthByDirectoryID: [String: Int] = [:]
        depthByDirectoryID.reserveCapacity(affectedDirectoryIDs.count)
        for directoryID in affectedDirectoryIDs {
            depthByDirectoryID[directoryID] = treeDepth(of: directoryID, parentIDByID: parentIDByID)
        }

        return affectedDirectoryIDs.sorted { lhs, rhs in
            let lhsDepth = depthByDirectoryID[lhs] ?? 0
            let rhsDepth = depthByDirectoryID[rhs] ?? 0
            if lhsDepth == rhsDepth {
                return lhs < rhs
            }
            return lhsDepth > rhsDepth
        }
    }

    private nonisolated static func treeDepth(
        of nodeID: String,
        parentIDByID: [String: String]
    ) -> Int {
        var depth = 0
        var cursor = nodeID

        while let parentID = parentIDByID[cursor] {
            depth += 1
            cursor = parentID
        }

        return depth
    }
}

nonisolated struct HardLinkClaim: Sendable {
    let identity: FileIdentity
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
}

private extension FileNodeRecord {
    nonisolated func replacingAllocatedSize(_ allocatedSize: Int64) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }
}
