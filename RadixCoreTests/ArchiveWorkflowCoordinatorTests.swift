import XCTest
@testable import RadixCore

@MainActor
final class ArchiveWorkflowCoordinatorTests: XCTestCase {
    func testSupersededSuccessCannotApplyOrFinishNewWorkflow() async throws {
        let probe = ControlledArchiveWorkProbe()
        let coordinator = ArchiveWorkflowCoordinator()
        var successes: [Int] = []
        var finishes: [String] = []

        coordinator.start(
            work: { try await probe.value(for: 0) },
            onSuccess: { successes.append($0) },
            onFailure: { _ in XCTFail("Unexpected failure") },
            onFinish: { finishes.append("old") }
        )
        await probe.waitForIssuedRequestCount(1)
        coordinator.start(
            work: { try await probe.value(for: 1) },
            onSuccess: { successes.append($0) },
            onFailure: { _ in XCTFail("Unexpected failure") },
            onFinish: { finishes.append("new") }
        )
        await probe.waitForIssuedRequestCount(2)

        let didCompleteOldRequest = await probe.complete(id: 0, with: 10)
        XCTAssertTrue(didCompleteOldRequest)
        await Task.yield()
        XCTAssertEqual(successes, [])
        XCTAssertEqual(finishes, [])
        XCTAssertTrue(coordinator.isRunning)

        let didCompleteNewRequest = await probe.complete(id: 1, with: 20)
        XCTAssertTrue(didCompleteNewRequest)
        try await waitUntil("new archive workflow success") { !coordinator.isRunning }
        XCTAssertEqual(successes, [20])
        XCTAssertEqual(finishes, ["new"])
    }

    func testSupersededFailureCannotPublishFailureOrFinishNewWorkflow() async throws {
        let probe = ControlledArchiveWorkProbe()
        let coordinator = ArchiveWorkflowCoordinator()
        var failures: [String] = []
        var finishes: [String] = []

        coordinator.start(
            work: { try await probe.value(for: 0) },
            onSuccess: { _ in XCTFail("Unexpected success") },
            onFailure: { failures.append($0.localizedDescription) },
            onFinish: { finishes.append("old") }
        )
        await probe.waitForIssuedRequestCount(1)
        coordinator.start(
            work: { try await probe.value(for: 1) },
            onSuccess: { _ in },
            onFailure: { failures.append($0.localizedDescription) },
            onFinish: { finishes.append("new") }
        )
        await probe.waitForIssuedRequestCount(2)

        let didFailOldRequest = await probe.fail(id: 0, with: TestArchiveWorkflowError.failed)
        XCTAssertTrue(didFailOldRequest)
        await Task.yield()
        XCTAssertEqual(failures, [])
        XCTAssertEqual(finishes, [])
        XCTAssertTrue(coordinator.isRunning)

        let didCompleteNewRequest = await probe.complete(id: 1, with: 1)
        XCTAssertTrue(didCompleteNewRequest)
        try await waitUntil("new archive workflow success after stale failure") { !coordinator.isRunning }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(finishes, ["new"])
    }

    func testSupersededOnFinishDoesNotClearCurrentOperationState() async throws {
        let probe = ControlledArchiveWorkProbe()
        let coordinator = ArchiveWorkflowCoordinator()
        var staleFinishCount = 0

        coordinator.start(
            kind: .importPreview,
            title: "Old",
            message: "Old",
            work: { try await probe.value(for: 0) },
            onSuccess: { _ in },
            onFailure: { _ in },
            onFinish: { staleFinishCount += 1 }
        )
        await probe.waitForIssuedRequestCount(1)
        coordinator.start(
            kind: .compare,
            title: "Current",
            message: "Current",
            work: { try await probe.value(for: 1) },
            onSuccess: { _ in },
            onFailure: { _ in }
        )
        await probe.waitForIssuedRequestCount(2)

        let didCompleteOldRequest = await probe.complete(id: 0, with: 0)
        XCTAssertTrue(didCompleteOldRequest)
        await Task.yield()
        XCTAssertEqual(staleFinishCount, 0)
        XCTAssertEqual(coordinator.operation?.title, "Current")
        XCTAssertTrue(coordinator.isRunning)

        let didCompleteNewRequest = await probe.complete(id: 1, with: 1)
        XCTAssertTrue(didCompleteNewRequest)
        try await waitUntil("current archive workflow completion") { !coordinator.isRunning }
    }
}

private enum TestArchiveWorkflowError: LocalizedError {
    case failed

    var errorDescription: String? { "Archive workflow failed" }
}

private actor ControlledArchiveWorkProbe {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var issuedIDs: [Int] = []
    private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]
    private var waiters: [Waiter] = []

    func value(for id: Int) async throws -> Int {
        issuedIDs.append(id)
        resumeWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func waitForIssuedRequestCount(_ count: Int) async {
        guard issuedIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    func complete(id: Int, with value: Int) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: value)
        return true
    }

    func fail(id: Int, with error: any Error) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func resumeWaiters() {
        var pending: [Waiter] = []
        for waiter in waiters {
            if issuedIDs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
    }
}
