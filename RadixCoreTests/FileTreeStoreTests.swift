import XCTest
@testable import RadixCore

final class FileTreeStoreTests: XCTestCase {
    func testPathAndAncestorLookup() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [leaf],
        ])

        XCTAssertEqual(store.path(to: leaf.id).map(\.name), ["root", "folder", "file.txt"])
        XCTAssertTrue(store.isAncestor(root.id, of: leaf.id))
        XCTAssertTrue(store.isAncestor(folder.id, of: leaf.id))
        XCTAssertFalse(store.isAncestor(leaf.id, of: folder.id))
        XCTAssertEqual(store.parent(of: leaf.id)?.id, folder.id)
    }

    func testTopLevelNodeIDsDropsDescendantsOfQueuedParents() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [leaf],
        ])

        XCTAssertEqual(
            store.topLevelNodeIDs(from: [leaf.id, folder.id, sibling.id, folder.id]),
            [folder.id, sibling.id]
        )
        XCTAssertTrue(store.isNodeOrDescendant(leaf.id, of: [folder.id]))
        XCTAssertFalse(store.isNodeOrDescendant(sibling.id, of: [folder.id]))
    }

    func testRemovingSubtreesRemovesQueuedParentsAndRepairsTotals() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [leaf],
        ])

        let updatedStore = store.removingSubtrees(rootedAt: [leaf.id, folder.id])

        XCTAssertNil(updatedStore.node(id: folder.id))
        XCTAssertNil(updatedStore.node(id: leaf.id))
        XCTAssertEqual(updatedStore.children(of: root.id).map(\.id), [sibling.id])
        XCTAssertEqual(updatedStore.root.allocatedSize, sibling.allocatedSize)
        XCTAssertEqual(updatedStore.root.descendantFileCount, 1)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 1)
        XCTAssertEqual(updatedStore.aggregateStats.directoryCount, 1)
    }

    func testRemovingSubtreesRootReturnsEmptyRootStore() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        let updatedStore = store.removingSubtrees(rootedAt: [root.id])

        XCTAssertEqual(updatedStore.root.id, root.id)
        XCTAssertEqual(updatedStore.root.allocatedSize, 0)
        XCTAssertEqual(updatedStore.root.descendantFileCount, 0)
        XCTAssertTrue(updatedStore.children(of: root.id).isEmpty)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 0)
    }

    func testIndexedNodeIDsPreserveTraversalOrderAndCanExcludeRoot() {
        let first = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 12)
        let nested = makeFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [first, folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [first, folder],
            folder.id: [nested],
        ])

        XCTAssertEqual(store.indexedNodeIDs(), ["/root", "/root/a.txt", "/root/folder", "/root/folder/b.txt"])
        XCTAssertEqual(store.indexedNodeIDs(excludingRoot: true), ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])

        var iteratedIDs: [String] = []
        store.forEachIndexedNodeID(excludingRoot: true) { id in
            iteratedIDs.append(id)
        }
        XCTAssertEqual(iteratedIDs, ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])
    }

    func testCompactIndexInitializerPreservesTopologyAndCompatibilityViews() throws {
        let nested = makeFileNode(id: "/root/folder/nested.txt", name: "nested.txt", size: 4)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 8)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [sibling, folder])
        let nodes = [root, folder, nested, sibling]
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let folderIndex = FileTreeNodeIndex(rawValue: 1)
        let nestedIndex = FileTreeNodeIndex(rawValue: 2)
        let siblingIndex = FileTreeNodeIndex(rawValue: 3)
        let stats = ScanAggregateStats(
            totalAllocatedSize: 12,
            totalLogicalSize: 12,
            fileCount: 2,
            directoryCount: 2,
            accessibleItemCount: 4,
            inaccessibleItemCount: 0
        )

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: [
                [siblingIndex, folderIndex],
                [nestedIndex],
                [],
                [],
            ],
            parentIndices: [nil, rootIndex, folderIndex, rootIndex],
            orderedNodeIndices: [rootIndex, siblingIndex, folderIndex, nestedIndex],
            aggregateStats: stats
        )

        XCTAssertEqual(store.nodeIndex(id: folder.id), folderIndex)
        XCTAssertEqual(store.node(at: nestedIndex)?.id, nested.id)
        XCTAssertEqual(store.parentIndex(of: nestedIndex), folderIndex)
        XCTAssertEqual(store.childIndices(of: rootIndex), [siblingIndex, folderIndex])
        XCTAssertEqual(store.parentID(of: nested.id), folder.id)
        XCTAssertEqual(store.childIDs(of: root.id), [sibling.id, folder.id])
        XCTAssertEqual(store.indexedNodeIDs(), [root.id, sibling.id, folder.id, nested.id])
        XCTAssertEqual(store.path(to: nested.id).map(\.id), [root.id, folder.id, nested.id])

        XCTAssertEqual(store.nodesByID, Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }))
        XCTAssertEqual(store.childIDsByID, [
            root.id: [sibling.id, folder.id],
            folder.id: [nested.id],
        ])
        XCTAssertEqual(store.parentIDByID, [
            folder.id: root.id,
            nested.id: folder.id,
            sibling.id: root.id,
        ])
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, stats.totalAllocatedSize)
        XCTAssertEqual(store.aggregateStats.totalLogicalSize, stats.totalLogicalSize)
        XCTAssertEqual(store.aggregateStats.fileCount, stats.fileCount)
        XCTAssertEqual(store.aggregateStats.directoryCount, stats.directoryCount)
    }

    func testEmptyStoreFallsBackToRootPath() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let store = FileTreeStore(root: root)

        XCTAssertEqual(store.path(to: nil).map(\.id), [root.id])
        XCTAssertEqual(store.children(of: nil).count, 0)
    }

    func testUnknownNodeFallsBackToRootPath() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        XCTAssertEqual(store.path(to: "/root/missing").map(\.id), [root.id])
        XCTAssertNil(store.node(id: "/root/missing"))
        XCTAssertNil(store.parent(of: "/root/missing"))
    }

    func testChildrenPrefixPreservesOrderAndLimit() {
        let children = (0..<6).map { index in
            makeFileNode(id: "/root/item-\(index).txt", name: "item-\(index).txt", size: Int64(10 - index))
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])

        XCTAssertEqual(
            store.childrenPrefix(of: root.id, maxCount: 3).map(\.id),
            children.prefix(3).map(\.id)
        )
        XCTAssertEqual(store.childrenPrefix(of: root.id, maxCount: 99).count, children.count)
        XCTAssertTrue(store.childrenPrefix(of: root.id, maxCount: 0).isEmpty)
    }

    func testChildrenByIDInitializerDropsLaterDuplicateNodeIDs() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        XCTAssertEqual(store.children(of: root.id).map(\.name), ["kept.txt"])
        XCTAssertEqual(store.node(id: kept.id)?.name, "kept.txt")
        XCTAssertEqual(store.parent(of: kept.id)?.id, root.id)
        XCTAssertEqual(store.indexedNodeIDs(), [root.id, kept.id])
        XCTAssertEqual(store.root.allocatedSize, kept.allocatedSize)
        XCTAssertEqual(store.root.logicalSize, kept.logicalSize)
        XCTAssertEqual(store.root.descendantFileCount, 1)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, kept.allocatedSize)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }

    func testChildrenByIDInitializerRepairsNestedDuplicateTotals() {
        let shared = makeFileNode(id: "/root/shared.txt", name: "shared.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [shared])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [shared, folder])

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [shared, folder],
            folder.id: [shared],
        ])

        XCTAssertEqual(Set(store.children(of: root.id).map(\.id)), Set([shared.id, folder.id]))
        XCTAssertTrue(store.children(of: folder.id).isEmpty)
        XCTAssertEqual(store.node(id: folder.id)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.logicalSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.descendantFileCount, 0)
        XCTAssertEqual(store.root.allocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.root.logicalSize, shared.logicalSize)
        XCTAssertEqual(store.root.descendantFileCount, 1)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }

    func testChildrenByIDInitializerRepairsAccessibilityAfterDroppingDuplicates() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50, isAccessible: false)
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [kept, dropped],
            isAccessible: false,
            isSelfAccessible: true
        )

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        XCTAssertTrue(store.root.isAccessible)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, 2)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, 0)
    }

    func testChildrenByIDInitializerPreservesSelfInaccessibleDirectoryAfterDroppingDuplicates() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50, isAccessible: false)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped], isAccessible: false)

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        XCTAssertFalse(store.root.isAccessible)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, 1)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, 1)
    }

    func testChildrenByIDInitializerOrdersByKeptChildrenWhenDuplicateIsLarger() {
        let kept = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 1)
        let sibling = makeFileNode(id: "/root/b.txt", name: "b.txt", size: 50)
        let dropped = makeFileNode(id: kept.id, name: "dropped-a.txt", size: 100)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, sibling, dropped])

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, sibling, dropped],
        ])

        XCTAssertEqual(store.children(of: root.id).map(\.id), [sibling.id, kept.id])
        XCTAssertEqual(store.root.allocatedSize, sibling.allocatedSize + kept.allocatedSize)
    }

    func testFlatInitializerDropsDuplicateChildReferences() {
        let shared = makeFileNode(id: "/root/shared.txt", name: "shared.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [shared])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [shared, folder])
        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [
                root.id: root,
                shared.id: shared,
                folder.id: folder,
            ],
            childIDsByID: [
                root.id: [shared.id, folder.id, shared.id],
                folder.id: [shared.id],
            ],
            parentIDByID: [
                shared.id: folder.id,
                folder.id: root.id,
            ]
        )

        XCTAssertEqual(store.children(of: root.id).map(\.id), [shared.id, folder.id])
        XCTAssertTrue(store.children(of: folder.id).isEmpty)
        XCTAssertEqual(store.parent(of: shared.id)?.id, root.id)
        XCTAssertEqual(store.indexedNodeIDs(), [root.id, shared.id, folder.id])
        XCTAssertEqual(store.node(id: folder.id)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.logicalSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.descendantFileCount, 0)
        XCTAssertEqual(store.root.allocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.root.logicalSize, shared.logicalSize)
        XCTAssertEqual(store.root.descendantFileCount, 1)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }

    func testFlatInitializerPreservesPrecomputedStatsForEmptyChildArrays() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let precomputedStats = ScanAggregateStats(
            totalAllocatedSize: 99,
            totalLogicalSize: 101,
            fileCount: 42,
            directoryCount: 7,
            accessibleItemCount: 6,
            inaccessibleItemCount: 1
        )

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [root.id: []],
            parentIDByID: [:],
            aggregateStats: precomputedStats
        )

        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, precomputedStats.totalAllocatedSize)
        XCTAssertEqual(store.aggregateStats.totalLogicalSize, precomputedStats.totalLogicalSize)
        XCTAssertEqual(store.aggregateStats.fileCount, precomputedStats.fileCount)
        XCTAssertEqual(store.aggregateStats.directoryCount, precomputedStats.directoryCount)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, precomputedStats.accessibleItemCount)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, precomputedStats.inaccessibleItemCount)
    }

    func testFlatInitializerPreservesInaccessibleEmptyMaterializedDirectory() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [], isAccessible: false)

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [root.id: []],
            parentIDByID: [:]
        )

        XCTAssertFalse(store.root.isAccessible)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, 0)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, 1)
    }

    func testReplacingSubtreeRejectsReplacementIDsOutsideOldSubtree() throws {
        let targetChild = makeFileNode(id: "/root/target/old.txt", name: "old.txt", size: 4)
        let target = makeDirectoryNode(id: "/root/target", name: "target", children: [targetChild])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 8)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [target, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [target, sibling],
            target.id: [targetChild],
        ])
        let collidingReplacementChild = makeFileNode(id: sibling.id, name: "collision.txt", size: 99)
        let replacementRoot = makeDirectoryNode(
            id: target.id,
            name: "target",
            children: [collidingReplacementChild]
        )
        let replacementStore = FileTreeStore(root: replacementRoot, childrenByID: [
            replacementRoot.id: [collidingReplacementChild],
        ])

        XCTAssertThrowsError(
            try store.replacingSubtree(
                id: target.id,
                with: replacementStore,
                cancellationCheck: {}
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("reuses an existing node ID"))
            XCTAssertTrue(error.localizedDescription.contains(sibling.id))
        }
        XCTAssertNil(store.replacingSubtree(id: target.id, with: replacementStore))
        XCTAssertEqual(store.node(id: sibling.id)?.name, sibling.name)
    }

    func testReplacingRootCanChangeRootID() throws {
        let oldChild = makeFileNode(id: "/root/old.txt", name: "old.txt", size: 4)
        let oldRoot = makeDirectoryNode(id: "/root", name: "root", children: [oldChild])
        let store = FileTreeStore(root: oldRoot, childrenByID: [
            oldRoot.id: [oldChild],
        ])
        let newChild = makeFileNode(id: "/replacement/new.txt", name: "new.txt", size: 12)
        let newRoot = makeDirectoryNode(id: "/replacement", name: "replacement", children: [newChild])
        let replacementStore = FileTreeStore(root: newRoot, childrenByID: [
            newRoot.id: [newChild],
        ])

        let updated = try XCTUnwrap(
            try store.replacingSubtree(
                id: oldRoot.id,
                with: replacementStore,
                cancellationCheck: {}
            )
        )

        XCTAssertEqual(updated.root.id, newRoot.id)
        XCTAssertEqual(updated.children(of: newRoot.id).map(\.id), [newChild.id])
        XCTAssertNil(updated.node(id: oldRoot.id))
        XCTAssertNil(updated.node(id: oldChild.id))
    }

    func testReplacingDisjointSubtreesRebuildsSharedAncestors() throws {
        let oldAFile = makeFileNode(id: "/root/A/old.txt", name: "old.txt", size: 5)
        let oldBFile = makeFileNode(id: "/root/B/old.txt", name: "old.txt", size: 7)
        let oldA = makeDirectoryNode(id: "/root/A", name: "A", children: [oldAFile])
        let oldB = makeDirectoryNode(id: "/root/B", name: "B", children: [oldBFile])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 3)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [oldA, oldB, sibling],
            oldA.id: [oldAFile],
            oldB.id: [oldBFile],
        ])

        let newAFile = makeFileNode(id: "/root/A/new.txt", name: "new.txt", size: 20)
        let newA = makeDirectoryNode(id: oldA.id, name: "A", children: [newAFile])
        let newBFile = makeFileNode(id: "/root/B/new.txt", name: "new.txt", size: 10)
        let newBExtra = makeFileNode(id: "/root/B/extra.txt", name: "extra.txt", size: 2)
        let newB = makeDirectoryNode(id: oldB.id, name: "B", children: [newBFile, newBExtra])

        let updated = try XCTUnwrap(try store.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: newA, childrenByID: [newA.id: [newAFile]]),
                oldB.id: FileTreeStore(root: newB, childrenByID: [newB.id: [newBFile, newBExtra]]),
            ],
            cancellationCheck: {}
        ))

        XCTAssertNil(updated.node(id: oldAFile.id))
        XCTAssertNil(updated.node(id: oldBFile.id))
        XCTAssertEqual(updated.children(of: root.id).map(\.id), [newA.id, newB.id, sibling.id])
        XCTAssertEqual(updated.children(of: newA.id).map(\.id), [newAFile.id])
        XCTAssertEqual(updated.children(of: newB.id).map(\.id), [newBFile.id, newBExtra.id])
        XCTAssertEqual(updated.root.allocatedSize, 35)
        XCTAssertEqual(updated.root.logicalSize, 35)
        XCTAssertEqual(updated.root.descendantFileCount, 4)
        XCTAssertEqual(updated.aggregateStats.fileCount, 4)
        XCTAssertEqual(updated.aggregateStats.directoryCount, 3)
    }

    func testReplacingSubtreesRejectsOverlappingTargets() throws {
        let leaf = makeFileNode(id: "/root/folder/leaf.txt", name: "leaf.txt", size: 4)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [leaf],
        ])

        XCTAssertThrowsError(try store.replacingSubtrees(
            [
                folder.id: FileTreeStore(root: folder, childrenByID: [folder.id: [leaf]]),
                leaf.id: FileTreeStore(root: leaf),
            ],
            cancellationCheck: {}
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("must be disjoint"))
        }
    }

    func testReplacingSubtreesRejectsIDsSharedByReplacementTrees() throws {
        let oldA = makeFileNode(id: "/root/A", name: "A", size: 1)
        let oldB = makeFileNode(id: "/root/B", name: "B", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let sharedID = "/root/shared.txt"
        let firstShared = makeFileNode(id: sharedID, name: "shared.txt", size: 2)
        let secondShared = makeFileNode(id: sharedID, name: "shared.txt", size: 3)

        XCTAssertThrowsError(try store.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: firstShared),
                oldB.id: FileTreeStore(root: secondShared),
            ],
            cancellationCheck: {}
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains(sharedID))
        }
        XCTAssertEqual(store.root.allocatedSize, 2)
    }

    func testReplacingSubtreesRebalancesHardLinksAcrossReplacementBoundaries() throws {
        let oldA = makeFileNode(id: "/root/A", name: "A", size: 1)
        let oldB = makeFileNode(id: "/root/B", name: "B", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let identity = FileIdentity(device: 9, inode: 42)
        let firstLink = FileNodeRecord(
            id: "/root/A/link.bin",
            url: URL(filePath: "/root/A/link.bin"),
            name: "link.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 4_096,
            logicalSize: 4_096,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: 2,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let secondLink = FileNodeRecord(
            id: "/root/B/link.bin",
            url: URL(filePath: "/root/B/link.bin"),
            name: "link.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 4_096,
            logicalSize: 4_096,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: 2,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )

        let updated = try XCTUnwrap(try store.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: firstLink),
                oldB.id: FileTreeStore(root: secondLink),
            ],
            cancellationCheck: {}
        ))

        XCTAssertEqual(updated.root.allocatedSize, 4_096)
        XCTAssertEqual(updated.root.logicalSize, 8_192)
        XCTAssertEqual(updated.node(id: firstLink.id)?.allocatedSize, 4_096)
        XCTAssertEqual(updated.node(id: secondLink.id)?.allocatedSize, 0)
    }

    func testDeepTreeIndexingAndAggregateStatsAvoidRecursiveTraversal() {
        let depth = 5_000
        let leafID = "/root/file.txt"
        let leaf = makeFileNode(id: leafID, name: "file.txt", size: 12)
        var nodesByID = [leaf.id: leaf]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var childID = leaf.id

        for level in stride(from: depth, through: 1, by: -1) {
            let nodeID = "/root/level-\(level)"
            let directory = makeDirectoryNode(
                id: nodeID,
                name: "level-\(level)",
                children: [nodesByID[childID]!]
            )
            nodesByID[nodeID] = directory
            childIDsByID[nodeID] = [childID]
            parentIDByID[childID] = nodeID
            childID = nodeID
        }

        let root = makeDirectoryNode(id: "/root", name: "root", children: [nodesByID[childID]!])
        nodesByID[root.id] = root
        childIDsByID[root.id] = [childID]
        parentIDByID[childID] = root.id

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )

        XCTAssertEqual(store.path(to: leafID).count, depth + 2)
        XCTAssertEqual(store.aggregateStats.directoryCount, depth + 1)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }
}

private func makeFileNode(
    id: String,
    name: String,
    size: Int64,
    isAccessible: Bool = true
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: isAccessible,
        isSelfAccessible: isAccessible,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isAccessible: Bool = true,
    isSelfAccessible: Bool? = nil
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
        logicalSize: children.reduce(0) { $0 + $1.logicalSize },
        descendantFileCount: children.reduce(0) { $0 + ($1.isDirectory ? $1.descendantFileCount : 1) },
        lastModified: nil,
        isPackage: false,
        isAccessible: isAccessible,
        isSelfAccessible: isSelfAccessible ?? isAccessible,
        isSynthetic: false,
        isAutoSummarized: false
    )
}
