import XCTest
@testable import RadixCore

@MainActor
final class TreemapChartModelTests: XCTestCase {
    func testSelectionOverlayIncludesAncestorsAndSelectedTileLast() async {
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
        let overlays = model.selectionOverlaySegments(
            selectedNodeID: selected.nodeID,
            selectedAncestorIDs: Set([ancestor.nodeID!, selected.nodeID!, "missing"])
        )

        XCTAssertTrue(didApply)
        XCTAssertEqual(overlays.map(\.segment.id), [ancestor.id, selected.id])
        XCTAssertEqual(overlays.map(\.role), [.ancestor, .selected])
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
}

private actor ImmediateTreemapLayoutService: TreemapLayouting {
    private let renderedSegments: [TreemapSegment]

    init(segments: [TreemapSegment]) {
        renderedSegments = segments
    }

    func segments(
        in treeStore: FileTreeStore,
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

    private var issuedRequestCount = 0
    private var continuations: [Int: CheckedContinuation<[TreemapSegment], Error>] = [:]
    private var waiters: [Waiter] = []

    func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment] {
        let requestID = issuedRequestCount
        issuedRequestCount += 1
        resumeSatisfiedWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
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
}

private func makeTreemapStore() -> FileTreeStore {
    let root = makeTestDirectoryNode(id: "/root", name: "root", children: [])
    return FileTreeStore(root: root)
}

private func makeTreemapSegment(id: String, depth: Int = 0) -> TreemapSegment {
    TreemapSegment(
        id: id,
        nodeID: id,
        label: id,
        rect: CGRect(x: 0, y: 0, width: 1, height: 1),
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false,
        isDirectory: depth == 0,
        showsContainerHeader: depth == 0
    )
}
