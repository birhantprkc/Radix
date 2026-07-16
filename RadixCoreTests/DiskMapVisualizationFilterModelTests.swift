import XCTest
@testable import RadixCore

@MainActor
final class DiskMapVisualizationFilterModelTests: XCTestCase {
    func testDiscardPileFilterReturnsBaseInputUntilCachedFilterCompletes() async throws {
        let hidden = makeTestFileNode(id: "/root/hidden.bin", name: "hidden.bin", size: 20)
        let visible = makeTestFileNode(id: "/root/visible.bin", name: "visible.bin", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [hidden, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [hidden, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = DiskMapVisualizationFilterModel()
        let baseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        let immediateInput = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )

        XCTAssertNotNil(immediateInput.treeStore.node(id: hidden.id))
        XCTAssertTrue(model.isInputPending(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        ))
        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )
        XCTAssertTrue(model.isFiltering)

        let filteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id],
            removedNodeID: hidden.id
        )

        XCTAssertNil(filteredInput.treeStore.node(id: hidden.id))
        XCTAssertNotNil(filteredInput.treeStore.node(id: visible.id))
        XCTAssertEqual(filteredInput.rootNode.allocatedSize, visible.allocatedSize)
        XCTAssertEqual(
            filteredInput.layoutIDComponent,
            "free-space:0|discard-pile:1:\(hidden.id.count):\(hidden.id)"
        )
        XCTAssertFalse(model.isFiltering)
        XCTAssertFalse(model.isInputPending(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        ))
    }

    func testDiscardPileFilterRetainsCompatibleCachedInputWhileNextFilterRuns() async throws {
        let firstHidden = makeTestFileNode(id: "/root/first-hidden.bin", name: "first-hidden.bin", size: 20)
        let secondHidden = makeTestFileNode(id: "/root/second-hidden.bin", name: "second-hidden.bin", size: 30)
        let visible = makeTestFileNode(id: "/root/visible.bin", name: "visible.bin", size: 40)
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [firstHidden, secondHidden, visible]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [firstHidden, secondHidden, visible]]
        )
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = DiskMapVisualizationFilterModel()
        let baseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        _ = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        let firstFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id],
            removedNodeID: firstHidden.id
        )
        XCTAssertNil(firstFilteredInput.treeStore.node(id: firstHidden.id))

        let immediateInput = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        )

        XCTAssertNil(immediateInput.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(immediateInput.treeStore.node(id: secondHidden.id))
        XCTAssertTrue(model.isInputPending(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        ))
        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        )

        let secondFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id],
            removedNodeID: secondHidden.id
        )

        XCTAssertNotNil(secondFilteredInput.treeStore.node(id: firstHidden.id))
        XCTAssertNil(secondFilteredInput.treeStore.node(id: secondHidden.id))
    }

    func testReturningToExactCacheCancelsObsoletePendingFilter() async throws {
        let firstHidden = makeTestFileNode(id: "/root/first-hidden.bin", name: "first-hidden.bin", size: 20)
        let secondHidden = makeTestFileNode(id: "/root/second-hidden.bin", name: "second-hidden.bin", size: 30)
        let visible = makeTestFileNode(id: "/root/visible.bin", name: "visible.bin", size: 40)
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [firstHidden, secondHidden, visible]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [firstHidden, secondHidden, visible]]
        )
        let snapshot = makeTestSnapshot(root: root, store: store)
        let operation = ControlledVisualizationFilterOperation(pausedHiddenNodeIDs: [secondHidden.id])
        let model = DiskMapVisualizationFilterModel { baseInput, hiddenNodeIDs, layoutIDComponent in
            try await operation.pauseIfNeeded(hiddenNodeIDs: hiddenNodeIDs)
            return try await filteredVisualizationInput(
                baseInput: baseInput,
                hiddenNodeIDs: hiddenNodeIDs,
                layoutIDComponent: layoutIDComponent
            )
        }
        let baseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        _ = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id],
            removedNodeID: firstHidden.id
        )

        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        )
        await operation.waitUntilPaused()
        XCTAssertTrue(model.isFiltering)

        let exactCachedInput = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        XCTAssertNil(exactCachedInput.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(exactCachedInput.treeStore.node(id: secondHidden.id))

        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        XCTAssertFalse(model.isFiltering)
        await operation.resume()
        try await Task.sleep(nanoseconds: 10_000_000)

        let retainedCachedInput = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        XCTAssertNil(retainedCachedInput.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(retainedCachedInput.treeStore.node(id: secondHidden.id))
        let hiddenNodeIDCalls = await operation.recordedHiddenNodeIDs()
        XCTAssertEqual(hiddenNodeIDCalls, [[firstHidden.id], [secondHidden.id]])
    }

    func testDiscardPileFilterInvalidatesWhenBaseTreeContentChanges() async throws {
        let hidden = makeTestFileNode(id: "/root/hidden.bin", name: "hidden.bin", size: 20)
        let visible = makeTestFileNode(id: "/root/visible.bin", name: "visible.bin", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [hidden, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [hidden, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = DiskMapVisualizationFilterModel()
        let baseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )
        let firstFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id],
            removedNodeID: hidden.id
        )
        XCTAssertEqual(firstFilteredInput.rootNode.allocatedSize, visible.allocatedSize)

        let resizedVisible = makeTestFileNode(id: visible.id, name: visible.name, size: 70)
        let updatedRoot = makeTestDirectoryNode(id: root.id, name: root.name, children: [hidden, resizedVisible])
        let updatedStore = FileTreeStore(
            root: updatedRoot,
            childrenByID: [updatedRoot.id: [hidden, resizedVisible]]
        )
        let updatedSnapshot = ScanSnapshot(
            id: snapshot.id,
            target: snapshot.target,
            treeStore: updatedStore,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            scanWarnings: snapshot.scanWarnings,
            aggregateStats: updatedStore.aggregateStats,
            isComplete: snapshot.isComplete,
            scanOptions: snapshot.scanOptions,
            source: snapshot.source
        )
        let updatedBaseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: updatedSnapshot,
            focusNode: updatedRoot,
            showFreeSpace: false,
            availableCapacity: nil
        )

        let immediateInput = model.input(
            baseInput: updatedBaseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )
        XCTAssertNotNil(immediateInput.treeStore.node(id: hidden.id))
        XCTAssertEqual(immediateInput.rootNode.allocatedSize, updatedRoot.allocatedSize)
        XCTAssertTrue(model.isInputPending(
            baseInput: updatedBaseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        ))

        model.update(
            baseInput: updatedBaseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )
        let secondFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: updatedBaseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id],
            removedNodeID: hidden.id
        )

        XCTAssertNil(secondFilteredInput.treeStore.node(id: hidden.id))
        XCTAssertEqual(secondFilteredInput.rootNode.allocatedSize, resizedVisible.allocatedSize)
    }

    func testEmptyHiddenNodeUpdateClearsCachedFilter() async throws {
        let hidden = makeTestFileNode(id: "/root/hidden.bin", name: "hidden.bin", size: 20)
        let visible = makeTestFileNode(id: "/root/visible.bin", name: "visible.bin", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [hidden, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [hidden, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = DiskMapVisualizationFilterModel()
        let baseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )
        _ = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id],
            removedNodeID: hidden.id
        )

        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: []
        )
        let inputAfterClear = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )

        XCTAssertNotNil(inputAfterClear.treeStore.node(id: hidden.id))
    }

    func testVolumeCapacityOverlaySurvivesBackgroundDiscardPileFiltering() async throws {
        let hidden = makeTestFileNode(id: "/volume/hidden.bin", name: "hidden.bin", size: 20)
        let visible = makeTestFileNode(id: "/volume/visible.bin", name: "visible.bin", size: 30)
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [hidden, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [hidden, visible]])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: store
        )
        let model = DiskMapVisualizationFilterModel()
        let baseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 50
        )

        model.update(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )
        let filteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id],
            removedNodeID: hidden.id
        )

        let children = filteredInput.treeStore.children(of: filteredInput.rootNode.id)
        XCTAssertEqual(filteredInput.rootNode.allocatedSize, visible.allocatedSize + 50)
        XCTAssertNotNil(children.first { $0.id == root.id })
        XCTAssertNotNil(children.first { DiskMapFreeSpaceVisualization.isFreeSpaceNodeID($0.id) })
    }

    private func waitForFilteredInput(
        model: DiskMapVisualizationFilterModel,
        baseInput: DiskMapVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        removedNodeID: FileNodeRecord.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> DiskMapVisualizationInput {
        for _ in 0..<100 {
            let input = model.input(
                baseInput: baseInput,
                snapshotID: snapshotID,
                focusNodeID: focusNodeID,
                hiddenNodeIDs: hiddenNodeIDs
            )
            if input.treeStore.node(id: removedNodeID) == nil {
                return input
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for filtered visualization input.", file: file, line: line)
        return model.input(
            baseInput: baseInput,
            snapshotID: snapshotID,
            focusNodeID: focusNodeID,
            hiddenNodeIDs: hiddenNodeIDs
        )
    }
}

private actor ControlledVisualizationFilterOperation {
    private let pausedHiddenNodeIDs: [FileNodeRecord.ID]
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var hiddenNodeIDCalls: [[FileNodeRecord.ID]] = []

    init(pausedHiddenNodeIDs: [FileNodeRecord.ID]) {
        self.pausedHiddenNodeIDs = pausedHiddenNodeIDs
    }

    func pauseIfNeeded(hiddenNodeIDs: [FileNodeRecord.ID]) async throws {
        hiddenNodeIDCalls.append(hiddenNodeIDs)
        if hiddenNodeIDs == pausedHiddenNodeIDs, !didPause {
            didPause = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }

        try Task.checkCancellation()
    }

    func waitUntilPaused() async {
        guard !didPause else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func recordedHiddenNodeIDs() -> [[FileNodeRecord.ID]] {
        hiddenNodeIDCalls
    }
}

@MainActor
private func filteredVisualizationInput(
    baseInput: DiskMapVisualizationInput,
    hiddenNodeIDs: [FileNodeRecord.ID],
    layoutIDComponent: String
) throws -> DiskMapVisualizationInput {
    let filteredStore = try baseInput.treeStore.removingSubtrees(
        rootedAt: hiddenNodeIDs,
        cancellationCheck: Task.checkCancellation
    )
    return DiskMapVisualizationInput(
        rootNode: filteredStore.node(id: baseInput.rootNode.id) ?? filteredStore.root,
        treeStore: filteredStore,
        treeContentID: filteredStore.contentID,
        layoutIDComponent: [
            baseInput.layoutIDComponent,
            layoutIDComponent,
        ].joined(separator: "|")
    )
}
