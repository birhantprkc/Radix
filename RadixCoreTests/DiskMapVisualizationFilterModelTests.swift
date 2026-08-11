import XCTest
@testable import RadixCore

@MainActor
final class DiskMapVisualizationFilterModelTests: XCTestCase {
    func testFilterRequestCanonicalizesHiddenNodeIDsOnce() {
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [])
        let store = FileTreeStore(root: root, childrenByID: [:])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let baseInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        let request = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: ["/root/z.bin", "/root/a.bin"]
        )

        XCTAssertEqual(request.hiddenNodeIDs, ["/root/a.bin", "/root/z.bin"])
        XCTAssertEqual(request.discardPileLayoutComponent, "discard-pile:2:11:/root/a.bin:11:/root/z.bin")
    }

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
        let request = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )

        let immediateInput = model.input(
            baseInput: baseInput,
            request: request
        )

        XCTAssertNotNil(immediateInput.treeStore.node(id: hidden.id))
        XCTAssertTrue(model.isInputPending(for: request))
        model.update(
            baseInput: baseInput,
            request: request
        )
        XCTAssertTrue(model.isFiltering)

        let filteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: request,
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
        XCTAssertFalse(model.isInputPending(for: request))
    }

    func testDiscardPileFilterReleasesCachedInputBeforeReplacementCompletes() async throws {
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
        let firstRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        let secondRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        )

        _ = model.input(
            baseInput: baseInput,
            request: firstRequest
        )
        model.update(
            baseInput: baseInput,
            request: firstRequest
        )
        let firstFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: firstRequest,
            removedNodeID: firstHidden.id
        )
        XCTAssertNil(firstFilteredInput.treeStore.node(id: firstHidden.id))

        let immediateInput = model.input(
            baseInput: baseInput,
            request: secondRequest
        )

        XCTAssertNotNil(immediateInput.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(immediateInput.treeStore.node(id: secondHidden.id))
        XCTAssertTrue(model.isInputPending(for: secondRequest))
        model.update(
            baseInput: baseInput,
            request: secondRequest
        )
        let inputWhileFiltering = model.input(
            baseInput: baseInput,
            request: secondRequest
        )
        XCTAssertNotNil(inputWhileFiltering.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(inputWhileFiltering.treeStore.node(id: secondHidden.id))

        let secondFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: secondRequest,
            removedNodeID: secondHidden.id
        )

        XCTAssertNotNil(secondFilteredInput.treeStore.node(id: firstHidden.id))
        XCTAssertNil(secondFilteredInput.treeStore.node(id: secondHidden.id))
    }

    func testReturningToPreviousRequestRebuildsReleasedCache() async throws {
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
        let firstRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        let secondRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        )

        model.update(
            baseInput: baseInput,
            request: firstRequest
        )
        _ = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: firstRequest,
            removedNodeID: firstHidden.id
        )

        model.update(
            baseInput: baseInput,
            request: secondRequest
        )
        await operation.waitUntilPaused()
        XCTAssertTrue(model.isFiltering)

        let immediateInput = model.input(
            baseInput: baseInput,
            request: firstRequest
        )
        XCTAssertNotNil(immediateInput.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(immediateInput.treeStore.node(id: secondHidden.id))

        model.update(
            baseInput: baseInput,
            request: firstRequest
        )
        XCTAssertTrue(model.isFiltering)
        await operation.resume()
        let rebuiltInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: firstRequest,
            removedNodeID: firstHidden.id
        )
        XCTAssertNil(rebuiltInput.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(rebuiltInput.treeStore.node(id: secondHidden.id))
        let hiddenNodeIDCalls = await operation.recordedHiddenNodeIDs()
        XCTAssertEqual(hiddenNodeIDCalls, [[firstHidden.id], [secondHidden.id], [firstHidden.id]])
    }

    func testReplacementWaitsForCancelledFilterBeforeStartingNextWorker() async throws {
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
        let operation = ControlledVisualizationFilterOperation(
            pausedHiddenNodeIDs: [firstHidden.id]
        )
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
        let firstRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        let secondRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        )
        let unfilteredRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: []
        )

        model.update(baseInput: baseInput, request: firstRequest)
        await operation.waitUntilPaused()
        model.update(baseInput: baseInput, request: unfilteredRequest)
        model.update(baseInput: baseInput, request: secondRequest)
        try await Task.sleep(nanoseconds: 10_000_000)

        let callsBeforeCancelledWorkerExited = await operation.recordedHiddenNodeIDs()
        XCTAssertEqual(callsBeforeCancelledWorkerExited, [[firstHidden.id]])

        await operation.resume()
        let filteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: secondRequest,
            removedNodeID: secondHidden.id
        )

        XCTAssertNotNil(filteredInput.treeStore.node(id: firstHidden.id))
        XCTAssertNil(filteredInput.treeStore.node(id: secondHidden.id))
        let finalCalls = await operation.recordedHiddenNodeIDs()
        XCTAssertEqual(finalCalls, [[firstHidden.id], [secondHidden.id]])
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
        let firstRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )

        model.update(
            baseInput: baseInput,
            request: firstRequest
        )
        let firstFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: firstRequest,
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
        let updatedRequest = DiskMapVisualizationFilterRequest(
            baseInput: updatedBaseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )

        let immediateInput = model.input(
            baseInput: updatedBaseInput,
            request: updatedRequest
        )
        XCTAssertNotNil(immediateInput.treeStore.node(id: hidden.id))
        XCTAssertEqual(immediateInput.rootNode.allocatedSize, updatedRoot.allocatedSize)
        XCTAssertTrue(model.isInputPending(for: updatedRequest))

        model.update(
            baseInput: updatedBaseInput,
            request: updatedRequest
        )
        let secondFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: updatedBaseInput,
            request: updatedRequest,
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
        let filteredRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )
        let emptyRequest = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: []
        )

        model.update(
            baseInput: baseInput,
            request: filteredRequest
        )
        _ = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: filteredRequest,
            removedNodeID: hidden.id
        )

        model.update(
            baseInput: baseInput,
            request: emptyRequest
        )
        let inputAfterClear = model.input(
            baseInput: baseInput,
            request: filteredRequest
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
        let request = DiskMapVisualizationFilterRequest(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )

        model.update(
            baseInput: baseInput,
            request: request
        )
        let filteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            request: request,
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
        request: DiskMapVisualizationFilterRequest,
        removedNodeID: FileNodeRecord.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> DiskMapVisualizationInput {
        for _ in 0..<100 {
            let input = model.input(
                baseInput: baseInput,
                request: request
            )
            if input.treeStore.node(id: removedNodeID) == nil {
                return input
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for filtered visualization input.", file: file, line: line)
        return model.input(
            baseInput: baseInput,
            request: request
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
