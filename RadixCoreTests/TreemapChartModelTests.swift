import XCTest
@testable import RadixCore

@MainActor
final class TreemapChartModelTests: XCTestCase {
    func testSpatialSelectionStartsAmongTopLevelTiles() async {
        let topLevel = makeTreemapSegment(
            id: "top-level",
            rect: CGRect(x: 0.4, y: 0, width: 0.6, height: 1)
        )
        let deeper = makeTreemapSegment(
            id: "deeper",
            rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
            depth: 1,
            containerNodeID: topLevel.id
        )
        let model = TreemapChartModel(
            layoutService: ImmediateTreemapLayoutService(segments: [topLevel, deeper])
        )
        let store = makeTreemapStore()

        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 2,
            size: CGSize(width: 600, height: 300),
            layoutID: "layout"
        )

        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: nil,
                moving: .right,
                in: CGSize(width: 600, height: 300)
            ),
            topLevel.id
        )
    }

    func testSpatialSelectionSkipsDiscardPileTiles() async {
        let queued = makeTreemapSegment(
            id: "queued",
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let available = makeTreemapSegment(
            id: "available",
            rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        )
        let model = TreemapChartModel(
            layoutService: ImmediateTreemapLayoutService(segments: [queued, available])
        )
        let store = makeTreemapStore()

        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 1,
            size: CGSize(width: 600, height: 300),
            layoutID: "layout"
        )

        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: nil,
                moving: .right,
                in: CGSize(width: 600, height: 300),
                excluding: [queued.id]
            ),
            available.id
        )
    }

    func testSpatialSelectionDoesNotTreatNestedTileAsSidewaysFromContainerHeader() async {
        let container = makeTreemapSegment(
            id: "container",
            rect: CGRect(x: 0, y: 0, width: 0.9, height: 1),
            showsContainerHeader: true
        )
        let child = makeTreemapSegment(
            id: "child",
            rect: CGRect(x: 0.5, y: 0.1, width: 0.1, height: 0.2),
            depth: 1,
            containerNodeID: container.id
        )
        let rightSibling = makeTreemapSegment(
            id: "right-sibling",
            rect: CGRect(x: 0.9, y: 0, width: 0.1, height: 1)
        )
        let model = TreemapChartModel(
            layoutService: ImmediateTreemapLayoutService(
                segments: [container, child, rightSibling]
            )
        )
        let store = makeTreemapStore()

        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 2,
            size: CGSize(width: 600, height: 300),
            layoutID: "layout"
        )

        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: container.id,
                moving: .right,
                in: CGSize(width: 600, height: 300)
            ),
            rightSibling.id
        )
        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: container.id,
                moving: .down,
                in: CGSize(width: 600, height: 300)
            ),
            child.id
        )
    }

    func testSpatialSelectionDoesNotMoveSidewaysIntoAncestorHeaders() async {
        let ancestor = makeTreemapSegment(
            id: "ancestor",
            rect: CGRect(x: 0, y: 0, width: 0.8, height: 1),
            showsContainerHeader: true
        )
        let current = makeTreemapSegment(
            id: "current",
            rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.8),
            depth: 1,
            containerNodeID: ancestor.id,
            showsContainerHeader: true
        )
        let child = makeTreemapSegment(
            id: "child",
            rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3),
            depth: 2,
            containerNodeID: current.id,
            showsContainerHeader: false
        )
        let rightSibling = makeTreemapSegment(
            id: "right-sibling",
            rect: CGRect(x: 0.6, y: 0.1, width: 0.4, height: 0.8),
            depth: 1,
            containerNodeID: ancestor.id,
            showsContainerHeader: false
        )
        let model = TreemapChartModel(
            layoutService: ImmediateTreemapLayoutService(
                segments: [ancestor, current, child, rightSibling]
            )
        )
        let store = makeTreemapStore()

        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 3,
            size: CGSize(width: 600, height: 300),
            layoutID: "layout"
        )

        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: current.id,
                moving: .right,
                in: CGSize(width: 600, height: 300)
            ),
            rightSibling.id
        )
        XCTAssertNil(
            model.spatialSelectionNodeID(
                from: current.id,
                moving: .left,
                in: CGSize(width: 600, height: 300)
            )
        )
        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: current.id,
                moving: .up,
                in: CGSize(width: 600, height: 300)
            ),
            ancestor.id
        )
    }

    func testSpatialSelectionMeasuresDistanceInCurrentDisplayedAspectRatio() async {
        let current = makeTreemapSegment(
            id: "current",
            rect: CGRect(x: 0.499, y: 0.499, width: 0.002, height: 0.002)
        )
        let normalizedFavorite = makeTreemapSegment(
            id: "normalized-favorite",
            rect: CGRect(x: 0.649, y: 0.579, width: 0.002, height: 0.002)
        )
        let displayedFavorite = makeTreemapSegment(
            id: "displayed-favorite",
            rect: CGRect(x: 0.579, y: 0.649, width: 0.002, height: 0.002)
        )
        let service = ImmediateTreemapLayoutService(
            segments: [current, normalizedFavorite, displayedFavorite]
        )
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 1,
            size: CGSize(width: 1_000, height: 250),
            layoutID: "wide-layout"
        )

        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: current.id,
                moving: .right,
                in: CGSize(width: 1_000, height: 250)
            ),
            displayedFavorite.id
        )
        XCTAssertNil(
            model.spatialSelectionNodeID(
                from: current.id,
                moving: .right,
                in: CGSize(width: 250, height: 1_000)
            )
        )
    }

    func testSpatialSelectionUsesExposedContainerHeaderInsteadOfCoveredCenter() async {
        let parent = makeTreemapSegment(
            id: "parent",
            rect: CGRect(x: 0, y: 0, width: 0.6, height: 1),
            showsContainerHeader: true
        )
        let child = makeTreemapSegment(
            id: "child",
            rect: CGRect(x: 0, y: 0.2, width: 0.6, height: 0.3),
            depth: 1,
            containerNodeID: parent.id
        )
        let lowerSibling = makeTreemapSegment(
            id: "lower-sibling",
            rect: CGRect(x: 0, y: 0.55, width: 0.6, height: 0.45),
            depth: 1,
            containerNodeID: parent.id
        )
        let service = ImmediateTreemapLayoutService(segments: [parent, child, lowerSibling])
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 2,
            size: CGSize(width: 600, height: 300),
            layoutID: "layout"
        )

        XCTAssertEqual(
            model.spatialSelectionNodeID(
                from: child.id,
                moving: .down,
                in: CGSize(width: 600, height: 300)
            ),
            lowerSibling.id
        )
    }

    func testSelectedSegmentDoesNotIncludeAncestorOverlays() async {
        let ancestor = makeTreemapSegment(id: "ancestor", depth: 0)
        let selected = makeTreemapSegment(id: "selected", depth: 1)
        let sibling = makeTreemapSegment(id: "sibling", depth: 1)
        let service = ImmediateTreemapLayoutService(segments: [ancestor, selected, sibling])
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        let didApply = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 2,
            size: CGSize(width: 600, height: 300),
            layoutID: "layout"
        )
        let selectedSegment = model.selectedSegment(nodeID: selected.nodeID)

        XCTAssertTrue(didApply)
        XCTAssertEqual(selectedSegment?.id, selected.id)
        XCTAssertEqual(model.layoutReadiness.renderedLayoutID, "layout")
        XCTAssertFalse(model.layoutReadiness.isRenderingPending(layoutID: "layout"))
        XCTAssertNil(model.selectedSegment(nodeID: "missing"))
        XCTAssertNil(model.selectedSegment(nodeID: nil))
    }

    func testStaleLayoutResultDoesNotReplaceNewerTiles() async {
        let service = ControllableTreemapLayoutService()
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        let oldTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 600, height: 300),
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 800, height: 400),
                layoutID: "new"
            )
        }
        await service.waitForIssuedRequestCount(2)

        let newSegment = makeTreemapSegment(id: "new")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        let didApplyNewLayout = await newTask.value
        XCTAssertTrue(didCompleteNewRequest)
        XCTAssertTrue(didApplyNewLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])

        let oldSegment = makeTreemapSegment(id: "old")
        let didCompleteOldRequest = await service.completeRequest(id: 0, with: [oldSegment])
        let didApplyOldLayout = await oldTask.value
        XCTAssertTrue(didCompleteOldRequest)
        XCTAssertFalse(didApplyOldLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])
    }

    func testStartingNewLayoutCancelsPreviousLayoutWork() async {
        let service = ControllableTreemapLayoutService(resumesOnCancellation: true)
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        let oldTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 600, height: 300),
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 800, height: 400),
                layoutID: "new"
            )
        }
        await service.waitForCancelledRequest(id: 0)
        await service.waitForIssuedRequestCount(2)

        let didApplyOldLayout = await oldTask.value
        XCTAssertFalse(didApplyOldLayout)

        let newSegment = makeTreemapSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        XCTAssertTrue(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        XCTAssertTrue(didApplyNewLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])
        XCTAssertEqual(model.renderedLayoutVersion, 1)
    }

    func testLayoutFailurePreservesLastRenderAndPublishesError() async {
        let service = ControllableTreemapLayoutService()
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        let initialTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 600, height: 300),
                layoutID: "initial"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let initialSegment = makeTreemapSegment(id: "initial")
        let didCompleteInitialRequest = await service.completeRequest(id: 0, with: [initialSegment])
        XCTAssertTrue(didCompleteInitialRequest)
        let didApplyInitialLayout = await initialTask.value
        XCTAssertTrue(didApplyInitialLayout)
        let initialVersion = model.renderedLayoutVersion

        let failingTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 2,
                size: CGSize(width: 800, height: 400),
                layoutID: "failing"
            )
        }
        await service.waitForIssuedRequestCount(2)
        let didFailRequest = await service.failRequest(id: 1, with: TestTreemapLayoutError.failed)
        XCTAssertTrue(didFailRequest)

        let didApplyFailingLayout = await failingTask.value
        XCTAssertFalse(didApplyFailingLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [initialSegment.id])
        XCTAssertEqual(model.renderedLayoutVersion, initialVersion)
        XCTAssertEqual(model.layoutReadiness.failure?.message, TestTreemapLayoutError.failed.localizedDescription)
        XCTAssertFalse(model.layoutReadiness.isPending)
        XCTAssertEqual(model.layoutReadiness.renderedLayoutID, "initial")
        XCTAssertEqual(model.layoutReadiness.failedLayoutID, "failing")
        XCTAssertFalse(model.layoutReadiness.isRenderingPending(layoutID: "failing"))
    }

    func testStaleLayoutFailureDoesNotReplaceNewerSuccessOrPublishError() async {
        let service = ControllableTreemapLayoutService()
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        let staleTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 600, height: 300),
                layoutID: "stale"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let currentTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 800, height: 400),
                layoutID: "current"
            )
        }
        await service.waitForIssuedRequestCount(2)

        let currentSegment = makeTreemapSegment(id: "current")
        let didCompleteCurrentRequest = await service.completeRequest(id: 1, with: [currentSegment])
        XCTAssertTrue(didCompleteCurrentRequest)
        let didApplyCurrentLayout = await currentTask.value
        XCTAssertTrue(didApplyCurrentLayout)
        let didFailStaleRequest = await service.failRequest(id: 0, with: TestTreemapLayoutError.failed)
        XCTAssertTrue(didFailStaleRequest)

        let didApplyStaleLayout = await staleTask.value
        XCTAssertFalse(didApplyStaleLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [currentSegment.id])
        XCTAssertNil(model.layoutReadiness.failure)
        XCTAssertFalse(model.layoutReadiness.isPending)
    }

    func testRetryClearsFailureAndAppliesSuccessfulLayout() async {
        let service = ControllableTreemapLayoutService()
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        let failingTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 600, height: 300),
                layoutID: "unchanged-layout"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let didFailRequest = await service.failRequest(id: 0, with: TestTreemapLayoutError.failed)
        XCTAssertTrue(didFailRequest)
        let didApplyFailingLayout = await failingTask.value
        XCTAssertFalse(didApplyFailingLayout)
        XCTAssertNotNil(model.layoutReadiness.failure)

        let retryTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 600, height: 300),
                layoutID: "unchanged-layout"
            )
        }
        await service.waitForIssuedRequestCount(2)
        XCTAssertNil(model.layoutReadiness.failure)
        XCTAssertTrue(model.layoutReadiness.isPending)

        let retrySegment = makeTreemapSegment(id: "retry")
        let didCompleteRetryRequest = await service.completeRequest(id: 1, with: [retrySegment])
        XCTAssertTrue(didCompleteRetryRequest)
        let didApplyRetryLayout = await retryTask.value
        XCTAssertTrue(didApplyRetryLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [retrySegment.id])
        XCTAssertNil(model.layoutReadiness.failure)
    }

    func testSameSemanticLayoutCancellationPreservesResolvedRender() async {
        let service = ControllableTreemapLayoutService(resumesOnCancellation: true)
        let model = TreemapChartModel(layoutService: service)
        let store = makeTreemapStore()

        let initialTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                size: CGSize(width: 600, height: 300),
                layoutID: "initial"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let initialSegment = makeTreemapSegment(id: "initial")
        let didCompleteInitialRequest = await service.completeRequest(id: 0, with: [initialSegment])
        XCTAssertTrue(didCompleteInitialRequest)
        let didApplyInitialLayout = await initialTask.value
        XCTAssertTrue(didApplyInitialLayout)

        let cancelledTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 2,
                size: CGSize(width: 800, height: 400),
                layoutID: "initial"
            )
        }
        await service.waitForIssuedRequestCount(2)
        cancelledTask.cancel()
        await service.waitForCancelledRequest(id: 1)

        let didApplyCancelledLayout = await cancelledTask.value
        XCTAssertFalse(didApplyCancelledLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [initialSegment.id])
        XCTAssertNil(model.layoutReadiness.failure)
        XCTAssertFalse(model.layoutReadiness.isPending)
        XCTAssertFalse(model.layoutReadiness.isRenderingPending(layoutID: "initial"))
        XCTAssertTrue(model.layoutReadiness.isRenderingPending(layoutID: "different"))
    }
}

private actor ImmediateTreemapLayoutService: TreemapLayouting {
    private let renderedSegments: [TreemapSegment]

    init(segments: [TreemapSegment]) {
        renderedSegments = segments
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment] {
        renderedSegments
    }
}

private actor ControllableTreemapLayoutService: TreemapLayouting {
    private struct Waiter {
        let requestCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CancellationWaiter {
        let requestID: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let resumesOnCancellation: Bool
    private var issuedRequestCount = 0
    private var continuations: [Int: CheckedContinuation<[TreemapSegment], Error>] = [:]
    private var cancelledRequestIDs: Set<Int> = []
    private var waiters: [Waiter] = []
    private var cancellationWaiters: [CancellationWaiter] = []

    init(resumesOnCancellation: Bool = false) {
        self.resumesOnCancellation = resumesOnCancellation
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment] {
        let requestID = issuedRequestCount
        issuedRequestCount += 1
        resumeSatisfiedWaiters()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledRequestIDs.contains(requestID) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[requestID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.handleCancellation(id: requestID)
            }
        }
    }

    func waitForIssuedRequestCount(_ requestCount: Int) async {
        guard issuedRequestCount < requestCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(requestCount: requestCount, continuation: continuation))
        }
    }

    func completeRequest(id: Int, with segments: [TreemapSegment]) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: segments)
        return true
    }

    func failRequest(id: Int, with error: any Error) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    func waitForCancelledRequest(id requestID: Int) async {
        guard !cancelledRequestIDs.contains(requestID) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(CancellationWaiter(requestID: requestID, continuation: continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        var pending: [Waiter] = []
        for waiter in waiters {
            if issuedRequestCount >= waiter.requestCount {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
    }

    private func handleCancellation(id requestID: Int) {
        cancelledRequestIDs.insert(requestID)
        if resumesOnCancellation,
           let continuation = continuations.removeValue(forKey: requestID) {
            continuation.resume(throwing: CancellationError())
        }

        var pending: [CancellationWaiter] = []
        for waiter in cancellationWaiters {
            if cancelledRequestIDs.contains(waiter.requestID) {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        cancellationWaiters = pending
    }
}

private enum TestTreemapLayoutError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test treemap layout failure"
    }
}

private func makeTreemapStore() -> FileTreeStore {
    let root = makeTestDirectoryNode(id: "/root", name: "root", children: [])
    return FileTreeStore(root: root)
}

private func makeTreemapSegment(
    id: String,
    rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
    depth: Int = 0,
    containerNodeID: String = "/root",
    showsContainerHeader: Bool? = nil
) -> TreemapSegment {
    TreemapSegment(
        id: id,
        nodeID: id,
        containerNodeID: containerNodeID,
        label: id,
        rect: rect,
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false,
        groupedItemCount: nil,
        isDirectory: depth == 0,
        showsContainerHeader: showsContainerHeader ?? (depth == 0)
    )
}
