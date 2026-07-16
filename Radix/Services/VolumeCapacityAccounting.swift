//
//  VolumeCapacityAccounting.swift
//  Radix
//

import Foundation

nonisolated enum VolumeCapacityAccounting {
    private static let unattributedSuffix = "#system-unattributed"
    private static let minimumNewRemainder: Int64 = 64 * 1_024 * 1_024

    static func overlappingAllocatedBytes(
        in treeStore: FileTreeStore,
        capacity: VolumeCapacitySnapshot?
    ) -> Int64? {
        guard let capacity else { return nil }
        let overlap = treeStore.root.allocatedSize - capacity.usedCapacity
        return overlap >= minimumNewRemainder ? overlap : nil
    }

    static func reconciledStore(
        _ treeStore: FileTreeStore,
        target: ScanTarget,
        capacity: VolumeCapacitySnapshot?,
        hasActiveExclusions: Bool
    ) -> FileTreeStore {
        guard target.kind == .volume, let capacity else { return treeStore }

        let root = treeStore.root
        let currentRootChildren = treeStore.children(of: root.id)
        let existingRemainder = currentRootChildren.first {
            isUnattributedNodeID($0.id)
        }
        let ordinaryChildren = currentRootChildren.filter {
            !isUnattributedNodeID($0.id)
        }
        let scannedRoot = rebuiltRoot(root, children: ordinaryChildren)
        let missingBytes = max(capacity.usedCapacity - scannedRoot.allocatedSize, 0)
        let shouldIncludeRemainder = missingBytes >= minimumNewRemainder || existingRemainder != nil

        guard shouldIncludeRemainder, missingBytes > 0 else {
            var nodesByID = treeStore.nodesByID
            var childIDsByID = treeStore.childIDsByID
            if let existingRemainder {
                nodesByID.removeValue(forKey: existingRemainder.id)
                childIDsByID.removeValue(forKey: existingRemainder.id)
            }
            nodesByID[scannedRoot.id] = scannedRoot
            childIDsByID[scannedRoot.id] = ordinaryChildren.map(\.id)
            return FileTreeStore(
                rootID: treeStore.rootID,
                nodesByID: nodesByID,
                childIDsByID: childIDsByID
            )
        }

        let unattributedNode = FileNodeRecord(
            id: root.id + unattributedSuffix,
            url: target.url,
            name: hasActiveExclusions ? "Excluded & Unattributed" : "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: missingBytes,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let rootChildren = FileTreeStore.sortedChildren(ordinaryChildren + [unattributedNode])
        let reconciledRoot = rebuiltRoot(root, children: rootChildren)
        if existingRemainder != nil {
            let existingStats = treeStore.aggregateStats
            let reconciledStats = ScanAggregateStats(
                totalAllocatedSize: reconciledRoot.allocatedSize,
                totalLogicalSize: reconciledRoot.logicalSize,
                fileCount: existingStats.fileCount,
                directoryCount: existingStats.directoryCount,
                accessibleItemCount: existingStats.accessibleItemCount,
                inaccessibleItemCount: existingStats.inaccessibleItemCount
            )
            if let updatedStore = treeStore.replacingRecordsPreservingTopology(
                [reconciledRoot, unattributedNode],
                orderedChildIDs: rootChildren.map(\.id),
                of: root.id,
                aggregateStats: reconciledStats
            ) {
                return updatedStore
            }
        }

        var nodesByID = treeStore.nodesByID
        var childIDsByID = treeStore.childIDsByID
        if let existingRemainder {
            nodesByID.removeValue(forKey: existingRemainder.id)
            childIDsByID.removeValue(forKey: existingRemainder.id)
        }
        nodesByID[reconciledRoot.id] = reconciledRoot
        nodesByID[unattributedNode.id] = unattributedNode
        childIDsByID[reconciledRoot.id] = rootChildren.map(\.id)

        return FileTreeStore(
            rootID: treeStore.rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
    }

    static func hasActiveExclusions(in treeStore: FileTreeStore) -> Bool {
        treeStore.children(of: treeStore.rootID).contains {
            isUnattributedNodeID($0.id) && $0.name == "Excluded & Unattributed"
        }
    }

    static func hasUnattributedRemainder(in treeStore: FileTreeStore) -> Bool {
        treeStore.children(of: treeStore.rootID).contains {
            isUnattributedNodeID($0.id)
        }
    }

    private static func isUnattributedNodeID(_ nodeID: String) -> Bool {
        nodeID.hasSuffix(unattributedSuffix)
    }

    private static func rebuiltRoot(
        _ root: FileNodeRecord,
        children: [FileNodeRecord]
    ) -> FileNodeRecord {
        FileNodeRecord.directory(
            id: root.id,
            url: root.url,
            name: root.name,
            children: children,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible,
            childrenAreSorted: false
        )
    }
}
