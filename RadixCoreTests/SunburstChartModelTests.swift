import Combine
import XCTest
@testable import RadixCore

@MainActor
final class SunburstChartModelTests: XCTestCase {
    func testKeyboardSelectionMovesAroundCurrentRingAndWraps() async {
        let first = makeSegment(id: "first", startAngle: 0, endAngle: 1)
        let aggregate = makeSegment(
            id: "aggregate",
            startAngle: 1,
            endAngle: 2,
            isSelectable: false
        )
        let second = makeSegment(id: "second", startAngle: 2, endAngle: 3)
        let third = makeSegment(id: "third", startAngle: 3, endAngle: 4)
        let model = await loadedModel(
            with: [third, aggregate, first, second]
        )

        XCTAssertEqual(
            model.keyboardSelection(from: first.id, moving: .left)?.nodeID,
            third.id
        )
        XCTAssertEqual(
            model.keyboardSelection(from: first.id, moving: .right)?.nodeID,
            second.id
        )
        XCTAssertEqual(
            model.keyboardSelection(from: third.id, moving: .right)?.nodeID,
            first.id
        )
    }

    func testKeyboardSelectionSkipsItemsMovingToTrash() async {
        let first = makeSegment(id: "first", startAngle: 0, endAngle: 1)
        let moving = makeSegment(id: "moving", startAngle: 1, endAngle: 2)
        let last = makeSegment(id: "last", startAngle: 2, endAngle: 3)
        let model = await loadedModel(with: [first, moving, last])

        XCTAssertEqual(
            model.keyboardSelection(
                from: first.id,
                moving: .right,
                excludingMovingToTrashNodeIDs: [moving.id]
            )?.nodeID,
            last.id
        )
        XCTAssertEqual(
            model.keyboardSelection(
                from: nil,
                moving: .right,
                excludingMovingToTrashNodeIDs: [first.id, moving.id]
            )?.nodeID,
            last.id
        )
    }

    func testKeyboardSelectionMovesOneRingInAndOut() async {
        let parent = makeSegment(
            id: "parent",
            startAngle: 0,
            endAngle: 2
        )
        let otherParent = makeSegment(
            id: "other-parent",
            startAngle: 2,
            endAngle: 4
        )
        let firstChild = makeSegment(
            id: "first-child",
            depth: 1,
            startAngle: 0,
            endAngle: 0.8
        )
        let secondChild = makeSegment(
            id: "second-child",
            depth: 1,
            startAngle: 0.8,
            endAngle: 2
        )
        let unrelatedChild = makeSegment(
            id: "unrelated-child",
            depth: 1,
            startAngle: 2,
            endAngle: 4
        )
        let model = await loadedModel(
            with: [
                unrelatedChild,
                secondChild,
                otherParent,
                firstChild,
                parent
            ]
        )

        XCTAssertEqual(
            model.keyboardSelection(from: secondChild.id, moving: .up)?.nodeID,
            parent.id
        )
        XCTAssertEqual(
            model.keyboardSelection(from: parent.id, moving: .down)?.nodeID,
            secondChild.id
        )
        XCTAssertNil(
            model.keyboardSelection(from: parent.id, moving: .up)
        )
        XCTAssertNil(
            model.keyboardSelection(from: secondChild.id, moving: .down)
        )
    }

    func testKeyboardSelectionStartsAtFirstSegmentInTopLevelRing() async {
        let first = makeSegment(
            id: "first",
            startAngle: 0,
            endAngle: 1
        )
        let later = makeSegment(
            id: "later",
            startAngle: 1,
            endAngle: 2
        )
        let deeper = makeSegment(
            id: "deeper",
            depth: 1,
            startAngle: 0,
            endAngle: 1
        )
        let model = await loadedModel(with: [deeper, later, first])

        XCTAssertEqual(
            model.keyboardSelection(from: nil, moving: .right)?.nodeID,
            first.id
        )
        XCTAssertEqual(
            model.keyboardSelection(from: "missing", moving: .down)?.nodeID,
            first.id
        )
    }

    func testKeyboardSelectionUsesIDToOrderEqualAngles() async {
        let laterID = makeSegment(
            id: "b",
            startAngle: 0,
            endAngle: 1
        )
        let earlierID = makeSegment(
            id: "a",
            startAngle: 0,
            endAngle: 1
        )
        let model = await loadedModel(with: [laterID, earlierID])

        XCTAssertEqual(
            model.keyboardSelection(from: nil, moving: .right)?.nodeID,
            earlierID.id
        )
        XCTAssertEqual(
            model.keyboardSelection(from: earlierID.id, moving: .right)?.nodeID,
            laterID.id
        )
    }

    func testStartingLayoutPublishesPendingState() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()
        var publishCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            publishCount += 1
        }

        let layoutTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "layout"
            )
        }
        await service.waitForIssuedRequestCount(1)

        XCTAssertTrue(model.layoutReadiness.isPending)
        XCTAssertTrue(model.layoutReadiness.isRenderingPending(layoutID: "layout"))
        XCTAssertNil(model.layoutReadiness.renderedLayoutID)
        XCTAssertGreaterThanOrEqual(publishCount, 1)

        let segment = makeSegment(id: "segment")
        let didCompleteRequest = await service.completeRequest(id: 0, with: [segment])
        XCTAssertTrue(didCompleteRequest)
        let didApplyLayout = await layoutTask.value

        XCTAssertTrue(didApplyLayout)
        XCTAssertFalse(model.layoutReadiness.isPending)
        XCTAssertEqual(model.renderedSegments.map(\.id), [segment.id])
        XCTAssertEqual(model.layoutReadiness.renderedLayoutID, "layout")
        XCTAssertFalse(model.layoutReadiness.isRenderingPending(layoutID: "layout"))
        XCTAssertGreaterThanOrEqual(publishCount, 2)
        withExtendedLifetime(cancellable) {}
    }

    func testStartingNewLayoutCancelsPreviousLayoutWork() async {
        let service = ControllableSunburstLayoutService(resumesOnCancellation: true)
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let oldTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "new"
            )
        }
        await service.waitForCancelledRequest(id: 0)
        await service.waitForIssuedRequestCount(2)

        let didApplyOldLayout = await oldTask.value
        XCTAssertFalse(didApplyOldLayout)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        XCTAssertTrue(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        XCTAssertTrue(didApplyNewLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])
    }

    func testStartingNewLayoutClearsHoverState() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let firstTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let oldSegment = makeSegment(id: "old-segment")
        let didCompleteFirstRequest = await service.completeRequest(id: 0, with: [oldSegment])
        XCTAssertTrue(didCompleteFirstRequest)
        let didApplyFirstLayout = await firstTask.value
        XCTAssertTrue(didApplyFirstLayout)
        model.setHoveredSegmentID(oldSegment.id)
        XCTAssertEqual(model.hoveredSegmentID, oldSegment.id)

        let secondTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "new"
            )
        }
        await service.waitForIssuedRequestCount(2)

        XCTAssertNil(model.hoveredSegmentID)
        XCTAssertTrue(model.layoutReadiness.isPending)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteSecondRequest = await service.completeRequest(id: 1, with: [newSegment])
        XCTAssertTrue(didCompleteSecondRequest)
        let didApplySecondLayout = await secondTask.value
        XCTAssertTrue(didApplySecondLayout)
    }

    func testStaleLayoutResultDoesNotReplaceNewerSegments() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let oldTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "new"
            )
        }
        await service.waitForIssuedRequestCount(2)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        XCTAssertTrue(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        XCTAssertTrue(didApplyNewLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])

        let oldSegment = makeSegment(id: "old-segment")
        let didCompleteOldRequest = await service.completeRequest(id: 0, with: [oldSegment])
        XCTAssertTrue(didCompleteOldRequest)
        let didApplyOldLayout = await oldTask.value
        XCTAssertFalse(didApplyOldLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])
    }

    func testLayoutFailurePreservesLastRenderAndPublishesError() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let initialTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "initial"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let initialSegment = makeSegment(id: "initial")
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
                layoutID: "failing"
            )
        }
        await service.waitForIssuedRequestCount(2)
        let didFailRequest = await service.failRequest(id: 1, with: TestChartLayoutError.failed)
        XCTAssertTrue(didFailRequest)

        let didApplyFailingLayout = await failingTask.value
        XCTAssertFalse(didApplyFailingLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [initialSegment.id])
        XCTAssertEqual(model.renderedLayoutVersion, initialVersion)
        XCTAssertEqual(model.layoutReadiness.failure?.message, TestChartLayoutError.failed.localizedDescription)
        XCTAssertFalse(model.layoutReadiness.isPending)
        XCTAssertEqual(model.layoutReadiness.renderedLayoutID, "initial")
        XCTAssertEqual(model.layoutReadiness.failedLayoutID, "failing")
        XCTAssertFalse(model.layoutReadiness.isRenderingPending(layoutID: "failing"))
    }

    func testStaleLayoutFailureDoesNotReplaceNewerSuccessOrPublishError() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let staleTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "stale"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let currentTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "current"
            )
        }
        await service.waitForIssuedRequestCount(2)

        let currentSegment = makeSegment(id: "current")
        let didCompleteCurrentRequest = await service.completeRequest(id: 1, with: [currentSegment])
        XCTAssertTrue(didCompleteCurrentRequest)
        let didApplyCurrentLayout = await currentTask.value
        XCTAssertTrue(didApplyCurrentLayout)
        let didFailStaleRequest = await service.failRequest(id: 0, with: TestChartLayoutError.failed)
        XCTAssertTrue(didFailStaleRequest)

        let didApplyStaleLayout = await staleTask.value
        XCTAssertFalse(didApplyStaleLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [currentSegment.id])
        XCTAssertNil(model.layoutReadiness.failure)
        XCTAssertFalse(model.layoutReadiness.isPending)
    }

    func testRetryClearsFailureAndAppliesSuccessfulLayout() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let failingTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "unchanged-layout"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let didFailRequest = await service.failRequest(id: 0, with: TestChartLayoutError.failed)
        XCTAssertTrue(didFailRequest)
        let didApplyFailingLayout = await failingTask.value
        XCTAssertFalse(didApplyFailingLayout)
        XCTAssertNotNil(model.layoutReadiness.failure)

        let retryTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "unchanged-layout"
            )
        }
        await service.waitForIssuedRequestCount(2)
        XCTAssertNil(model.layoutReadiness.failure)
        XCTAssertTrue(model.layoutReadiness.isPending)

        let retrySegment = makeSegment(id: "retry")
        let didCompleteRetryRequest = await service.completeRequest(id: 1, with: [retrySegment])
        XCTAssertTrue(didCompleteRetryRequest)
        let didApplyRetryLayout = await retryTask.value
        XCTAssertTrue(didApplyRetryLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [retrySegment.id])
        XCTAssertNil(model.layoutReadiness.failure)
    }

    func testCancellationPreservesLastRenderWithoutPublishingError() async {
        let service = ControllableSunburstLayoutService(resumesOnCancellation: true)
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let initialTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "initial"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let initialSegment = makeSegment(id: "initial")
        let didCompleteInitialRequest = await service.completeRequest(id: 0, with: [initialSegment])
        XCTAssertTrue(didCompleteInitialRequest)
        let didApplyInitialLayout = await initialTask.value
        XCTAssertTrue(didApplyInitialLayout)

        let cancelledTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 2,
                layoutID: "cancelled"
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
    }

    func testSelectionOverlaySegmentsIncludeAncestorsAndSelectedLast() async {
        let firstAncestor = makeSegment(id: "first-ancestor", depth: 0)
        let secondAncestor = makeSegment(id: "second-ancestor", depth: 1)
        let selected = makeSegment(id: "selected", depth: 1)
        let sibling = makeSegment(id: "sibling", depth: 1)
        let service = ImmediateSunburstLayoutService(
            segments: [secondAncestor, sibling, firstAncestor, selected]
        )
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let didApplyLayout = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 2,
            layoutID: "layout"
        )

        XCTAssertTrue(didApplyLayout)
        let overlaySegments = model.selectionOverlaySegments(
            selectedNodeID: selected.nodeID,
            selectedAncestorIDs: Set([
                firstAncestor.nodeID!,
                selected.nodeID!,
                secondAncestor.nodeID!,
                "missing",
            ])
        )

        XCTAssertEqual(
            overlaySegments.map(\.segment.id),
            [secondAncestor.id, firstAncestor.id, selected.id]
        )
        XCTAssertEqual(
            overlaySegments.map(\.role),
            [.ancestor, .ancestor, .selected]
        )
    }

    func testSelectionOverlayCacheIsInvalidatedByNewLayout() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()
        let firstSelected = makeSegment(id: "selected", depth: 0)

        let firstTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "first"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let didCompleteFirstRequest = await service.completeRequest(
            id: 0,
            with: [firstSelected]
        )
        XCTAssertTrue(didCompleteFirstRequest)
        let didApplyFirstLayout = await firstTask.value
        XCTAssertTrue(didApplyFirstLayout)
        XCTAssertEqual(
            model.selectionOverlaySegments(
                selectedNodeID: firstSelected.nodeID,
                selectedAncestorIDs: []
            ).last?.segment.depth,
            0
        )

        let secondSelected = makeSegment(id: "selected", depth: 1)
        let secondTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 2,
                layoutID: "second"
            )
        }
        await service.waitForIssuedRequestCount(2)
        let didCompleteSecondRequest = await service.completeRequest(
            id: 1,
            with: [secondSelected]
        )
        XCTAssertTrue(didCompleteSecondRequest)
        let didApplySecondLayout = await secondTask.value
        XCTAssertTrue(didApplySecondLayout)

        XCTAssertEqual(
            model.selectionOverlaySegments(
                selectedNodeID: secondSelected.nodeID,
                selectedAncestorIDs: []
            ).last?.segment.depth,
            1
        )
    }

    private func loadedModel(
        with segments: [SunburstSegment]
    ) async -> SunburstChartModel {
        let model = SunburstChartModel(
            layoutService: ImmediateSunburstLayoutService(segments: segments)
        )
        let store = makeStore()
        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 3,
            layoutID: "layout"
        )
        return model
    }
}

private actor ImmediateSunburstLayoutService: SunburstLayouting {
    private let renderedSegments: [SunburstSegment]

    init(segments: [SunburstSegment]) {
        renderedSegments = segments
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        renderedSegments
    }
}

private actor ControllableSunburstLayoutService: SunburstLayouting {
    private struct RequestWaiter {
        let requestCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CancellationWaiter {
        let requestID: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let resumesOnCancellation: Bool
    private var issuedRequestCount = 0
    private var continuations: [Int: CheckedContinuation<[SunburstSegment], Error>] = [:]
    private var cancelledRequestIDs: Set<Int> = []
    private var waiters: [RequestWaiter] = []
    private var cancellationWaiters: [CancellationWaiter] = []

    init(resumesOnCancellation: Bool = false) {
        self.resumesOnCancellation = resumesOnCancellation
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
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
            waiters.append(RequestWaiter(requestCount: requestCount, continuation: continuation))
        }
    }

    func waitForCancelledRequest(id requestID: Int) async {
        guard !cancelledRequestIDs.contains(requestID) else { return }

        await withCheckedContinuation { continuation in
            cancellationWaiters.append(CancellationWaiter(requestID: requestID, continuation: continuation))
        }
    }

    func completeRequest(id: Int, with segments: [SunburstSegment]) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: segments)
        return true
    }

    func failRequest(id: Int, with error: any Error) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func resumeSatisfiedWaiters() {
        var waiting: [RequestWaiter] = []
        for waiter in waiters {
            if issuedRequestCount >= waiter.requestCount {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        waiters = waiting
    }

    private func handleCancellation(id requestID: Int) {
        cancelledRequestIDs.insert(requestID)
        if resumesOnCancellation,
           let continuation = continuations.removeValue(forKey: requestID) {
            continuation.resume(throwing: CancellationError())
        }
        resumeCancellationWaiters()
    }

    private func resumeCancellationWaiters() {
        var waiting: [CancellationWaiter] = []
        for waiter in cancellationWaiters {
            if cancelledRequestIDs.contains(waiter.requestID) {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        cancellationWaiters = waiting
    }
}

private enum TestChartLayoutError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test layout failure"
    }
}

private func makeStore() -> FileTreeStore {
    let root = FileNodeRecord(
        id: "/root",
        url: URL(filePath: "/root", directoryHint: .isDirectory),
        name: "root",
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: 1,
        logicalSize: 1,
        descendantFileCount: 0,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
    return FileTreeStore(root: root)
}

private func makeSegment(
    id: String,
    depth: Int = 0,
    startAngle: Double = 0,
    endAngle: Double = 1,
    innerRadius: CGFloat = 0,
    outerRadius: CGFloat = 1,
    isSelectable: Bool = true
) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: isSelectable ? id : nil,
        containerNodeID: "/root",
        label: id,
        startAngle: .radians(startAngle),
        endAngle: .radians(endAngle),
        innerRadius: innerRadius,
        outerRadius: outerRadius,
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false
    )
}
