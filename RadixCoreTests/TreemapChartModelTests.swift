import XCTest
@testable import RadixCore

@MainActor
final class TreemapChartModelTests: XCTestCase {
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
        XCTAssertEqual(model.layoutError?.message, TestTreemapLayoutError.failed.localizedDescription)
        XCTAssertFalse(model.isLayoutPending)
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
        XCTAssertNil(model.layoutError)
        XCTAssertFalse(model.isLayoutPending)
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
        XCTAssertNotNil(model.layoutError)

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
        XCTAssertNil(model.layoutError)
        XCTAssertTrue(model.isLayoutPending)

        let retrySegment = makeTreemapSegment(id: "retry")
        let didCompleteRetryRequest = await service.completeRequest(id: 1, with: [retrySegment])
        XCTAssertTrue(didCompleteRetryRequest)
        let didApplyRetryLayout = await retryTask.value
        XCTAssertTrue(didApplyRetryLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [retrySegment.id])
        XCTAssertNil(model.layoutError)
    }

    func testCancellationPreservesLastRenderWithoutPublishingError() async {
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
                layoutID: "cancelled"
            )
        }
        await service.waitForIssuedRequestCount(2)
        cancelledTask.cancel()
        await service.waitForCancelledRequest(id: 1)

        let didApplyCancelledLayout = await cancelledTask.value
        XCTAssertFalse(didApplyCancelledLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [initialSegment.id])
        XCTAssertNil(model.layoutError)
        XCTAssertFalse(model.isLayoutPending)
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

private func makeTreemapSegment(id: String, depth: Int = 0) -> TreemapSegment {
    TreemapSegment(
        id: id,
        nodeID: id,
        containerNodeID: "/root",
        label: id,
        rect: CGRect(x: 0, y: 0, width: 1, height: 1),
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false,
        groupedItemCount: nil,
        isDirectory: depth == 0,
        showsContainerHeader: depth == 0
    )
}
