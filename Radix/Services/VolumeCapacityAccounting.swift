//
//  VolumeCapacityAccounting.swift
//  Radix
//

import Foundation

nonisolated enum VolumeCapacityAccounting {
    private static let unattributedSuffix = "#system-unattributed"
    private static let minimumNewRemainder: Int64 = 64 * 1_024 * 1_024

    static func reconciledStore(
        _ treeStore: FileTreeStore,
        target: ScanTarget,
        capacity: VolumeCapacitySnapshot?,
        hasActiveExclusions: Bool
    ) -> FileTreeStore {
        guard target.kind == .volume, let capacity else { return treeStore }

        let root = treeStore.root
        let existingRemainder = treeStore.children(of: root.id).first {
            isUnattributedNodeID($0.id)
        }
        let ordinaryChildren = treeStore.children(of: root.id).filter {
            !isUnattributedNodeID($0.id)
        }
        let scannedRoot = rebuiltRoot(root, children: ordinaryChildren)
        let missingBytes = max(capacity.usedCapacity - scannedRoot.allocatedSize, 0)
        let shouldIncludeRemainder = missingBytes >= minimumNewRemainder || existingRemainder != nil

        var nodesByID = treeStore.nodesByID
        var childIDsByID = treeStore.childIDsByID
        var parentIDByID = treeStore.parentIDByID
        if let existingRemainder {
            nodesByID.removeValue(forKey: existingRemainder.id)
            childIDsByID.removeValue(forKey: existingRemainder.id)
            parentIDByID.removeValue(forKey: existingRemainder.id)
        }

        guard shouldIncludeRemainder, missingBytes > 0 else {
            nodesByID[scannedRoot.id] = scannedRoot
            childIDsByID[scannedRoot.id] = ordinaryChildren.map(\.id)
            return FileTreeStore(
                rootID: treeStore.rootID,
                nodesByID: nodesByID,
                childIDsByID: childIDsByID,
                parentIDByID: parentIDByID
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
        nodesByID[reconciledRoot.id] = reconciledRoot
        nodesByID[unattributedNode.id] = unattributedNode
        childIDsByID[reconciledRoot.id] = rootChildren.map(\.id)
        parentIDByID[unattributedNode.id] = reconciledRoot.id

        return FileTreeStore(
            rootID: treeStore.rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )
    }

    static func hasActiveExclusions(in treeStore: FileTreeStore) -> Bool {
        treeStore.children(of: treeStore.rootID).contains {
            isUnattributedNodeID($0.id) && $0.name == "Excluded & Unattributed"
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
