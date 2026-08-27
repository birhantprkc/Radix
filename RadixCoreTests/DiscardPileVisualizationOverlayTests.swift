import XCTest
@testable import RadixCore

final class DiscardPileVisualizationOverlayTests: XCTestCase {
    func testQueuedRootAndRenderedDescendantsAreMarkedWithoutChangingTree() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.folder.id],
            treeStore: fixture.store
        )

        XCTAssertEqual(overlay.queuedNodeIDs, [fixture.folder.id, fixture.child.id])
        XCTAssertEqual(overlay.queuedRootNodeIDs, [fixture.folder.id])
        XCTAssertTrue(overlay.containingQueuedNodeIDs.isEmpty)
        XCTAssertEqual(overlay.role(for: fixture.folder.id), .queuedRoot)
        XCTAssertEqual(overlay.role(for: fixture.child.id), .queuedDescendant)
        XCTAssertNil(overlay.role(for: fixture.sibling.id))
        XCTAssertFalse(overlay.allowsChartNodeAction(for: fixture.folder.id))
        XCTAssertFalse(overlay.allowsChartNodeAction(for: fixture.child.id))
        XCTAssertTrue(overlay.allowsChartNodeAction(for: fixture.sibling.id))
        XCTAssertNotNil(fixture.store.node(id: fixture.folder.id))
        XCTAssertNotNil(fixture.store.node(id: fixture.child.id))
    }

    func testUnrenderedQueuedItemMarksOnlyItsNearestRenderedAncestor() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.root.id, fixture.folder.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.child.id],
            treeStore: fixture.store
        )

        XCTAssertTrue(overlay.queuedNodeIDs.isEmpty)
        XCTAssertEqual(overlay.containingQueuedNodeIDs, [fixture.folder.id])
        XCTAssertEqual(overlay.role(for: fixture.folder.id), .containsQueuedItem)
        XCTAssertNil(overlay.role(for: fixture.root.id))
    }

    func testTopmostRenderedDescendantsBecomeVisualRootsWhenQueuedRootIsNotRendered() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.root.id],
            treeStore: fixture.store
        )

        XCTAssertEqual(
            overlay.queuedRootNodeIDs,
            [fixture.folder.id, fixture.sibling.id]
        )
        XCTAssertEqual(overlay.role(for: fixture.folder.id), .queuedRoot)
        XCTAssertEqual(overlay.role(for: fixture.child.id), .queuedDescendant)
        XCTAssertEqual(overlay.role(for: fixture.sibling.id), .queuedRoot)
    }

    func testRootLevelSunburstAggregateMarksQueuedGroupedItem() throws {
        let fixture = makeAggregateFixture()
        let segments = SunburstLayout.segments(
            in: fixture.store,
            rootID: fixture.root.id,
            depthLimit: 1
        )
        let aggregate = try XCTUnwrap(segments.first(where: \.isAggregate))
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: Set(segments.compactMap(\.nodeID)),
            renderedAggregateContainerNodeIDs: Set(
                segments.lazy.filter(\.isAggregate).map(\.containerNodeID)
            ),
            queuedRootNodeIDs: [fixture.tiny.id],
            treeStore: fixture.store
        )

        XCTAssertNil(aggregate.nodeID)
        XCTAssertEqual(aggregate.containerNodeID, fixture.root.id)
        XCTAssertEqual(
            overlay.role(
                for: aggregate.nodeID,
                aggregateContainerNodeID: aggregate.containerNodeID
            ),
            .containsQueuedItem
        )
    }

    func testRootLevelTreemapAggregateMarksQueuedGroupedItem() throws {
        let fixture = makeAggregateFixture()
        let segments = TreemapLayout.segments(
            in: fixture.store,
            rootID: fixture.root.id,
            depthLimit: 1,
            size: CGSize(width: 500, height: 300)
        )
        let aggregate = try XCTUnwrap(segments.first(where: \.isAggregate))
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: Set(segments.compactMap(\.nodeID)),
            renderedAggregateContainerNodeIDs: Set(
                segments.lazy.filter(\.isAggregate).map(\.containerNodeID)
            ),
            queuedRootNodeIDs: [fixture.tiny.id],
            treeStore: fixture.store
        )

        XCTAssertNil(aggregate.nodeID)
        XCTAssertEqual(aggregate.containerNodeID, fixture.root.id)
        XCTAssertEqual(
            overlay.role(
                for: aggregate.nodeID,
                aggregateContainerNodeID: aggregate.containerNodeID
            ),
            .containsQueuedItem
        )
    }

    func testQueuedItemsOutsideRenderedSubtreeProduceNoMarks() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.sibling.id],
            queuedRootNodeIDs: [fixture.child.id],
            treeStore: fixture.store
        )

        XCTAssertEqual(overlay, .empty)
    }

    func testQueuedAncestorTakesPrecedenceOverContainedIndicator() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id],
            queuedRootNodeIDs: [fixture.folder.id, fixture.child.id],
            treeStore: fixture.store
        )

        XCTAssertEqual(overlay.role(for: fixture.folder.id), .queuedRoot)
        XCTAssertTrue(overlay.containingQueuedNodeIDs.isEmpty)
    }

    func testMovingToTrashStateRemainsDistinctFromDiscardPileState() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.sibling.id],
            movingToTrashRootNodeIDs: [fixture.folder.id],
            treeStore: fixture.store
        )

        XCTAssertEqual(overlay.role(for: fixture.folder.id), .movingToTrashRoot)
        XCTAssertEqual(overlay.role(for: fixture.child.id), .movingToTrashDescendant)
        XCTAssertEqual(overlay.role(for: fixture.sibling.id), .queuedRoot)
        XCTAssertEqual(overlay.role(for: fixture.folder.id)?.statusText, "Moving to Trash")
        XCTAssertEqual(overlay.role(for: fixture.sibling.id)?.statusText, "In Discard Pile")
        XCTAssertTrue(overlay.isMovingToTrash(fixture.child.id))
        XCTAssertFalse(overlay.isQueued(fixture.child.id))
        XCTAssertFalse(overlay.allowsChartNodeAction(for: fixture.child.id))
    }

    func testUnrenderedMovingItemMarksNearestRenderedContainer() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.root.id, fixture.folder.id, fixture.sibling.id],
            movingToTrashRootNodeIDs: [fixture.child.id],
            treeStore: fixture.store
        )

        XCTAssertTrue(overlay.movingToTrashNodeIDs.isEmpty)
        XCTAssertEqual(overlay.containingMovingToTrashNodeIDs, [fixture.folder.id])
        XCTAssertEqual(overlay.role(for: fixture.folder.id), .containsMovingToTrashItem)
    }

    func testCacheAvoidsRebuildingOverlayUntilLayoutOrQueueChanges() {
        let fixture = makeFixture()
        let treeStore = DiskMapTreeStore(fixture.store)
        var cache = DiscardPileVisualizationOverlayCache()
        var renderedNodeIDBuildCount = 0
        let renderedNodeIDs = {
            renderedNodeIDBuildCount += 1
            return Set([fixture.folder.id, fixture.child.id, fixture.sibling.id])
        }

        let first = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [fixture.folder.id],
            movingToTrashRootNodeIDs: [],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )
        let cached = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [fixture.folder.id],
            movingToTrashRootNodeIDs: [],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )
        let updated = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [fixture.child.id],
            movingToTrashRootNodeIDs: [],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )

        XCTAssertEqual(first, cached)
        XCTAssertNotEqual(updated, first)
        XCTAssertEqual(renderedNodeIDBuildCount, 2)
    }

    func testCacheRebuildsWhenMovingToTrashRootsChange() {
        let fixture = makeFixture()
        let treeStore = DiskMapTreeStore(fixture.store)
        var cache = DiscardPileVisualizationOverlayCache()
        var renderedNodeIDBuildCount = 0
        let renderedNodeIDs = {
            renderedNodeIDBuildCount += 1
            return Set([fixture.folder.id, fixture.child.id, fixture.sibling.id])
        }

        _ = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [],
            movingToTrashRootNodeIDs: [fixture.folder.id],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )
        _ = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [],
            movingToTrashRootNodeIDs: [fixture.sibling.id],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )

        XCTAssertEqual(renderedNodeIDBuildCount, 2)
    }

    @MainActor
    func testConsecutiveQueueChangesPreserveLayoutIdentity() {
        let fixture = makeFixture()
        let snapshot = makeTestSnapshot(
            root: fixture.root,
            store: fixture.store
        )
        let queuedNodeIDSets: [Set<FileNodeRecord.ID>] = [
            [],
            [fixture.folder.id],
            [fixture.folder.id, fixture.sibling.id],
            [fixture.child.id, fixture.sibling.id],
        ]
        let presentations = queuedNodeIDSets.map { queuedNodeIDs in
            DiscardPileVisualizationPresentation(
                snapshot: snapshot,
                focusNode: fixture.root,
                showFreeSpace: false,
                availableCapacity: nil,
                maxRenderedDepth: 6,
                discardPileRootNodeIDs: queuedNodeIDs
            )
        }
        let changedDepthPresentation = DiscardPileVisualizationPresentation(
            snapshot: snapshot,
            focusNode: fixture.root,
            showFreeSpace: false,
            availableCapacity: nil,
            maxRenderedDepth: 7,
            discardPileRootNodeIDs: queuedNodeIDSets.last ?? []
        )
        let movingPresentation = DiscardPileVisualizationPresentation(
            snapshot: snapshot,
            focusNode: fixture.root,
            showFreeSpace: false,
            availableCapacity: nil,
            maxRenderedDepth: 6,
            discardPileRootNodeIDs: queuedNodeIDSets.last ?? [],
            movingToTrashRootNodeIDs: [fixture.folder.id]
        )

        var lastRequestedLayoutID: String?
        var layoutRequestCount = 0
        for presentation in presentations {
            if presentation.layoutID != lastRequestedLayoutID {
                lastRequestedLayoutID = presentation.layoutID
                layoutRequestCount += 1
            }
        }

        XCTAssertEqual(layoutRequestCount, 1)
        XCTAssertEqual(presentations.map(\.discardPileRootNodeIDs), queuedNodeIDSets)
        XCTAssertTrue(presentations.allSatisfy {
            $0.visualizationInput.treeContentID == fixture.store.contentID
        })
        XCTAssertNotEqual(changedDepthPresentation.layoutID, presentations.last?.layoutID)
        XCTAssertEqual(movingPresentation.layoutID, presentations.last?.layoutID)
        XCTAssertEqual(movingPresentation.movingToTrashRootNodeIDs, [fixture.folder.id])
    }

    private func makeFixture() -> (
        root: FileNodeRecord,
        folder: FileNodeRecord,
        child: FileNodeRecord,
        sibling: FileNodeRecord,
        store: FileTreeStore
    ) {
        let child = makeTestFileNode(
            id: "/root/folder/child.bin",
            name: "child.bin",
            size: 20
        )
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [child]
        )
        let sibling = makeTestFileNode(
            id: "/root/sibling.bin",
            name: "sibling.bin",
            size: 30
        )
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [folder, sibling]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [child],
            ]
        )
        return (root, folder, child, sibling, store)
    }

    private func makeAggregateFixture() -> (
        root: FileNodeRecord,
        tiny: FileNodeRecord,
        store: FileTreeStore
    ) {
        let large = makeTestFileNode(
            id: "/root/large.bin",
            name: "large.bin",
            size: 10_000
        )
        let tiny = makeTestFileNode(
            id: "/root/tiny-1.bin",
            name: "tiny-1.bin",
            size: 1
        )
        let otherTinyItems = (2...4).map { index in
            makeTestFileNode(
                id: "/root/tiny-\(index).bin",
                name: "tiny-\(index).bin",
                size: 1
            )
        }
        let children = [large, tiny] + otherTinyItems
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: children
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: children]
        )
        return (root, tiny, store)
    }
}
