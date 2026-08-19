import XCTest
@testable import RadixCore

final class SharedAllocationDeduplicatorTests: XCTestCase {
    func testIndexBasedStoreConstructionPreservesCancellation() {
        let root = makeDirectory(id: "/root", allocatedSize: 0, descendantFileCount: 0)
        let rootIndex = FileTreeNodeIndex(rawValue: 0)

        XCTAssertThrowsError(try SharedAllocationDeduplicator.deduplicatedStore(
            rootIndex: rootIndex,
            nodes: [root],
            indexByNodeID: [root.id: rootIndex],
            parentRawIndices: [UInt32.max],
            childSpans: [FileTreeChildSpan()],
            childIndices: [],
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: 0,
                totalLogicalSize: 0,
                fileCount: 0,
                directoryCount: 1,
                accessibleItemCount: 1,
                inaccessibleItemCount: 0
            ),
            sharedAllocationAccumulator: SharedAllocationOwnerAccumulator(),
            minimumAllocatedSizeByNodeID: [:],
            cancellationCheck: { throw CancellationError() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testIndexBasedHardLinkDedupRebuildsAncestorsWithoutStringTopologyInput() {
        let rootID = "/root"
        let parentID = "/root/Parent"
        let firstLinkID = "/root/Parent/a.bin"
        let duplicateLinkID = "/root/Parent/z.bin"
        let siblingID = "/root/sibling.bin"
        let identity = FileIdentity(device: 1, inode: 46)
        let nodes = [
            makeDirectory(id: rootID, allocatedSize: 250, descendantFileCount: 3),
            makeDirectory(id: parentID, allocatedSize: 200, descendantFileCount: 2),
            makeFile(id: firstLinkID, allocatedSize: 100),
            makeFile(id: duplicateLinkID, allocatedSize: 100),
            makeFile(id: siblingID, allocatedSize: 50, linkCount: 1)
        ]
        let indices = nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) }

        let store = SharedAllocationDeduplicator.deduplicatedStore(
            rootIndex: indices[0],
            nodes: nodes,
            indexByNodeID: Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), indices)),
            parentRawIndices: [UInt32.max, 0, 1, 1, 0],
            childSpans: [
                FileTreeChildSpan(start: 0, count: 2),
                FileTreeChildSpan(start: 2, count: 2),
                FileTreeChildSpan(),
                FileTreeChildSpan(),
                FileTreeChildSpan(),
            ],
            childIndices: [indices[1], indices[4], indices[2], indices[3]],
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: 250,
                totalLogicalSize: 250,
                fileCount: 3,
                directoryCount: 2,
                accessibleItemCount: 5,
                inaccessibleItemCount: 0
            ),
            sharedAllocationClaims: [
                SharedAllocationClaim(identity: identity, ownerNodeID: firstLinkID, path: firstLinkID, allocatedSize: 100),
                SharedAllocationClaim(identity: identity, ownerNodeID: duplicateLinkID, path: duplicateLinkID, allocatedSize: 100)
            ],
            minimumAllocatedSizeByNodeID: [:]
        )

        XCTAssertEqual(store.node(id: duplicateLinkID)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: parentID)?.allocatedSize, 100)
        XCTAssertEqual(store.root.allocatedSize, 150)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, 150)
        XCTAssertEqual(store.children(of: rootID).map(\.id), [rootID + "/Parent", siblingID])
        XCTAssertEqual(store.parent(of: duplicateLinkID)?.id, parentID)
    }

    func testOnlineOwnershipAcrossPackageAndVisibleFileKeepsLexicographicWinner() {
        let rootID = "/root"
        let packageID = "/root/z.app"
        let packageLinkPath = "/root/z.app/Contents/shared.bin"
        let visibleFileID = "/root/a-shared.bin"
        let identity = FileIdentity(device: 1, inode: 47)
        let nodes = [
            makeDirectory(id: rootID, allocatedSize: 220, descendantFileCount: 2),
            makeDirectory(id: packageID, allocatedSize: 120, descendantFileCount: 1),
            makeFile(id: visibleFileID, allocatedSize: 100)
        ]
        let indices = nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) }
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        // Package work may finish first even though its nested path sorts later.
        sharedAllocationAccumulator.record(SharedAllocationClaim(
            identity: identity,
            ownerNodeID: packageID,
            path: packageLinkPath,
            allocatedSize: 100
        ))
        sharedAllocationAccumulator.record(SharedAllocationClaim(
            identity: identity,
            ownerNodeID: visibleFileID,
            path: visibleFileID,
            allocatedSize: 100
        ))

        let store = SharedAllocationDeduplicator.deduplicatedStore(
            rootIndex: indices[0],
            nodes: nodes,
            indexByNodeID: Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), indices)),
            parentRawIndices: [UInt32.max, 0, 0],
            childSpans: [
                FileTreeChildSpan(start: 0, count: 2),
                FileTreeChildSpan(),
                FileTreeChildSpan(),
            ],
            childIndices: [indices[1], indices[2]],
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: 220,
                totalLogicalSize: 220,
                fileCount: 2,
                directoryCount: 2,
                accessibleItemCount: 3,
                inaccessibleItemCount: 0
            ),
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            minimumAllocatedSizeByNodeID: [packageID: 20]
        )

        XCTAssertEqual(sharedAllocationAccumulator.identityCount, 1)
        XCTAssertEqual(sharedAllocationAccumulator.winner(for: identity)?.ownerNodeID, visibleFileID)
        XCTAssertEqual(sharedAllocationAccumulator.duplicateAllocatedSizeByOwner, [packageID: 100])
        XCTAssertEqual(store.node(id: visibleFileID)?.allocatedSize, 100)
        XCTAssertEqual(store.node(id: packageID)?.allocatedSize, 20)
        XCTAssertEqual(store.root.allocatedSize, 120)
        XCTAssertEqual(store.children(of: rootID).map(\.id), [visibleFileID, packageID])
    }

    func testHardLinkDedupRebuildsOnlyAffectedAncestorChains() {
        let rootID = "/root"
        let affectedID = "/root/Affected"
        let firstLinkID = "/root/Affected/a.bin"
        let duplicateLinkID = "/root/Affected/z.bin"
        let unrelatedCount = 64

        var nodesByID: [String: FileNodeRecord] = [
            affectedID: makeDirectory(id: affectedID, allocatedSize: 200, descendantFileCount: 2),
            firstLinkID: makeFile(id: firstLinkID, allocatedSize: 100),
            duplicateLinkID: makeFile(id: duplicateLinkID, allocatedSize: 100)
        ]
        var childIDsByID: [String: [String]] = [
            affectedID: [firstLinkID, duplicateLinkID]
        ]
        var parentIDByID: [String: String] = [
            affectedID: rootID,
            firstLinkID: affectedID,
            duplicateLinkID: affectedID
        ]
        var rootChildIDs = [affectedID]

        for index in 0..<unrelatedCount {
            let directoryID = "/root/Unrelated\(index)"
            let smallID = "\(directoryID)/a-small.bin"
            let largeID = "\(directoryID)/z-large.bin"

            nodesByID[directoryID] = makeDirectory(id: directoryID, allocatedSize: 21, descendantFileCount: 2)
            nodesByID[smallID] = makeFile(id: smallID, allocatedSize: 1)
            nodesByID[largeID] = makeFile(id: largeID, allocatedSize: 20)
            childIDsByID[directoryID] = [smallID, largeID]
            parentIDByID[directoryID] = rootID
            parentIDByID[smallID] = directoryID
            parentIDByID[largeID] = directoryID
            rootChildIDs.append(directoryID)
        }

        let rootAllocatedSize = Int64(200 + unrelatedCount * 21)
        nodesByID[rootID] = makeDirectory(
            id: rootID,
            allocatedSize: rootAllocatedSize,
            descendantFileCount: 2 + unrelatedCount * 2
        )
        childIDsByID[rootID] = rootChildIDs

        let identity = FileIdentity(device: 1, inode: 42)
        let store = SharedAllocationDeduplicator.deduplicatedStore(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: rootAllocatedSize,
                totalLogicalSize: rootAllocatedSize,
                fileCount: 2 + unrelatedCount * 2,
                directoryCount: 2 + unrelatedCount,
                accessibleItemCount: nodesByID.count,
                inaccessibleItemCount: 0
            ),
            sharedAllocationClaims: [
                SharedAllocationClaim(identity: identity, ownerNodeID: firstLinkID, path: firstLinkID, allocatedSize: 100),
                SharedAllocationClaim(identity: identity, ownerNodeID: duplicateLinkID, path: duplicateLinkID, allocatedSize: 100)
            ],
            minimumAllocatedSizeByNodeID: [:]
        )

        XCTAssertEqual(store.node(id: duplicateLinkID)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: affectedID)?.allocatedSize, 100)
        XCTAssertEqual(store.root.allocatedSize, rootAllocatedSize - 100)

        for index in 0..<unrelatedCount {
            let directoryID = "/root/Unrelated\(index)"
            XCTAssertEqual(
                store.childIDsByID[directoryID],
                ["\(directoryID)/a-small.bin", "\(directoryID)/z-large.bin"]
            )
        }
    }

    func testHardLinkDedupRebuildsDeepAncestorsBottomUp() {
        let rootID = "/root"
        let parentID = "/root/Parent"
        let nestedID = "/root/Parent/Nested"
        let firstLinkID = "/root/Parent/Nested/a.bin"
        let duplicateLinkID = "/root/Parent/Nested/z.bin"
        let siblingID = "/root/sibling.bin"
        let identity = FileIdentity(device: 1, inode: 45)
        let totalAllocatedSize: Int64 = 250

        let store = SharedAllocationDeduplicator.deduplicatedStore(
            rootID: rootID,
            nodesByID: [
                rootID: makeDirectory(id: rootID, allocatedSize: totalAllocatedSize, descendantFileCount: 3),
                parentID: makeDirectory(id: parentID, allocatedSize: 200, descendantFileCount: 2),
                nestedID: makeDirectory(id: nestedID, allocatedSize: 200, descendantFileCount: 2),
                firstLinkID: makeFile(id: firstLinkID, allocatedSize: 100),
                duplicateLinkID: makeFile(id: duplicateLinkID, allocatedSize: 100),
                siblingID: makeFile(id: siblingID, allocatedSize: 50, linkCount: 1)
            ],
            childIDsByID: [
                rootID: [parentID, siblingID],
                parentID: [nestedID],
                nestedID: [firstLinkID, duplicateLinkID]
            ],
            parentIDByID: [
                parentID: rootID,
                nestedID: parentID,
                firstLinkID: nestedID,
                duplicateLinkID: nestedID,
                siblingID: rootID
            ],
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: totalAllocatedSize,
                totalLogicalSize: totalAllocatedSize,
                fileCount: 3,
                directoryCount: 3,
                accessibleItemCount: 6,
                inaccessibleItemCount: 0
            ),
            sharedAllocationClaims: [
                SharedAllocationClaim(identity: identity, ownerNodeID: firstLinkID, path: firstLinkID, allocatedSize: 100),
                SharedAllocationClaim(identity: identity, ownerNodeID: duplicateLinkID, path: duplicateLinkID, allocatedSize: 100)
            ],
            minimumAllocatedSizeByNodeID: [:]
        )

        XCTAssertEqual(store.node(id: duplicateLinkID)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: nestedID)?.allocatedSize, 100)
        XCTAssertEqual(store.node(id: parentID)?.allocatedSize, 100)
        XCTAssertEqual(store.root.allocatedSize, 150)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, 150)
    }

    func testRemovingWinningOwnerRestoresRemainingHardLinkSize() throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let winner = makeFile(id: "/root/a.bin", allocatedSize: 100, identity: identity)
        let remaining = makeFile(id: "/root/z.bin", allocatedSize: 0, unduplicatedAllocatedSize: 100, identity: identity)
        let root = makeDirectory(id: "/root", children: [winner, remaining])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [winner, remaining]])

        let updatedStore = try XCTUnwrap(store.removingSubtree(id: winner.id))

        XCTAssertNil(updatedStore.node(id: winner.id))
        XCTAssertEqual(updatedStore.node(id: remaining.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.root.allocatedSize, 100)
        XCTAssertEqual(updatedStore.aggregateStats.totalAllocatedSize, 100)
    }

    func testRemovingWinningOwnerRepairsAndResortsPromotedOwnerAncestors() throws {
        let identity = FileIdentity(device: 1, inode: 43)
        let winner = makeFile(id: "/root/A/a.bin", allocatedSize: 100, identity: identity)
        let promoted = makeFile(
            id: "/root/B/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let sibling = makeFile(id: "/root/B/m.bin", allocatedSize: 50, linkCount: 1)
        let firstDirectory = makeDirectory(id: "/root/A", children: [winner])
        let secondDirectory = makeDirectory(id: "/root/B", children: [sibling, promoted])
        let root = makeDirectory(id: "/root", children: [firstDirectory, secondDirectory])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [firstDirectory, secondDirectory],
            firstDirectory.id: [winner],
            secondDirectory.id: [sibling, promoted],
        ])

        let updatedStore = try XCTUnwrap(store.removingSubtree(id: firstDirectory.id))

        XCTAssertEqual(updatedStore.node(id: promoted.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.node(id: secondDirectory.id)?.allocatedSize, 150)
        XCTAssertEqual(updatedStore.childIDs(of: secondDirectory.id), [promoted.id, sibling.id])
        XCTAssertEqual(updatedStore.root.allocatedSize, 150)
        XCTAssertEqual(updatedStore.aggregateStats.totalAllocatedSize, 150)
    }

    func testBatchRemovalPromotesRemainingHardLinkOwnerOnce() {
        let identity = FileIdentity(device: 1, inode: 142)
        let winner = makeFile(id: "/root/A/a.bin", allocatedSize: 100, identity: identity)
        let loser = makeFile(
            id: "/root/B/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let unrelated = makeFile(id: "/root/unrelated.bin", allocatedSize: 25, linkCount: 1)
        let firstDirectory = makeDirectory(id: "/root/A", children: [winner])
        let secondDirectory = makeDirectory(id: "/root/B", children: [loser])
        let root = makeDirectory(id: "/root", children: [firstDirectory, secondDirectory, unrelated])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [firstDirectory, secondDirectory, unrelated],
            firstDirectory.id: [winner],
            secondDirectory.id: [loser],
        ])

        let updatedStore = store.removingSubtrees(rootedAt: [firstDirectory.id, unrelated.id])

        XCTAssertNil(updatedStore.node(id: firstDirectory.id))
        XCTAssertNil(updatedStore.node(id: unrelated.id))
        XCTAssertEqual(updatedStore.node(id: loser.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.node(id: secondDirectory.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.root.allocatedSize, 100)
        XCTAssertEqual(updatedStore.aggregateStats.totalAllocatedSize, 100)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 1)
    }

    func testRebalancingAlreadyCorrectOwnersReturnsOriginalStore() throws {
        let identity = FileIdentity(device: 1, inode: 99)
        let winner = makeFile(id: "/root/a.bin", allocatedSize: 100, identity: identity)
        let loser = makeFile(
            id: "/root/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let root = makeDirectory(id: "/root", children: [winner, loser])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [winner, loser]])

        let rebalancedStore = try SharedAllocationDeduplicator.rebalancedStore(store)

        XCTAssertEqual(rebalancedStore.contentID, store.contentID)
        XCTAssertEqual(rebalancedStore.root, store.root)
    }

    func testScopingToHardLinkLoserRestoresVisibleClaimSize() throws {
        let identity = FileIdentity(device: 1, inode: 43)
        let winner = makeFile(id: "/root/A/a.bin", allocatedSize: 100, identity: identity)
        let loser = makeFile(id: "/root/Z/z.bin", allocatedSize: 0, unduplicatedAllocatedSize: 100, identity: identity)
        let winnerDirectory = makeDirectory(id: "/root/A", children: [winner])
        let loserDirectory = makeDirectory(id: "/root/Z", children: [loser])
        let root = makeDirectory(id: "/root", children: [winnerDirectory, loserDirectory])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [winnerDirectory, loserDirectory],
            winnerDirectory.id: [winner],
            loserDirectory.id: [loser]
        ])

        let scopedStore = try XCTUnwrap(store.subtree(rootedAt: loserDirectory.id))

        XCTAssertEqual(scopedStore.root.allocatedSize, 100)
        XCTAssertEqual(scopedStore.node(id: loser.id)?.allocatedSize, 100)
        XCTAssertNil(scopedStore.node(id: winner.id))
    }

    func testReplacingSummarizedParentRebalancesVisibleHardLinks() throws {
        let identity = FileIdentity(device: 1, inode: 44)
        let siblingFile = makeFile(id: "/root/sibling/a.bin", allocatedSize: 100, identity: identity)
        let sibling = makeDirectory(id: "/root/sibling", children: [siblingFile])
        let summarized = makeDirectory(id: "/root/folder", allocatedSize: 0, descendantFileCount: 1)
        let root = makeDirectory(id: "/root", children: [sibling, summarized])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [sibling, summarized],
            sibling.id: [siblingFile]
        ])

        let replacementFile = makeFile(
            id: "/root/folder/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let replacementRoot = makeDirectory(id: summarized.id, children: [replacementFile])
        let replacementStore = FileTreeStore(root: replacementRoot, childrenByID: [
            replacementRoot.id: [replacementFile]
        ])

        let updatedStore = try XCTUnwrap(store.replacingSubtree(id: summarized.id, with: replacementStore))

        XCTAssertEqual(updatedStore.node(id: replacementFile.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.node(id: siblingFile.id)?.allocatedSize, 0)
        XCTAssertEqual(updatedStore.root.allocatedSize, 100)
        XCTAssertEqual(updatedStore.aggregateStats.totalAllocatedSize, 100)
    }

    private func makeDirectory(
        id: String,
        allocatedSize: Int64,
        descendantFileCount: Int
    ) -> FileNodeRecord {
        makeNode(
            id: id,
            isDirectory: true,
            allocatedSize: allocatedSize,
            descendantFileCount: descendantFileCount
        )
    }

    private func makeDirectory(id: String, children: [FileNodeRecord]) -> FileNodeRecord {
        FileNodeRecord.directory(
            id: id,
            url: URL(filePath: id, directoryHint: .isDirectory),
            name: URL(filePath: id).lastPathComponent,
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
    }

    private func makeFile(
        id: String,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        identity: FileIdentity? = nil,
        linkCount: UInt64 = 2
    ) -> FileNodeRecord {
        makeNode(
            id: id,
            isDirectory: false,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            descendantFileCount: 1,
            identity: identity,
            linkCount: linkCount
        )
    }

    private func makeNode(
        id: String,
        isDirectory: Bool,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        descendantFileCount: Int,
        identity: FileIdentity? = nil,
        linkCount: UInt64 = 1
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            name: URL(filePath: id).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: descendantFileCount,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: linkCount,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}
