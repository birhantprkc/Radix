import XCTest
@testable import RadixCore

@MainActor
final class ChartLayoutPresentationStateTests: XCTestCase {
    func testInitialLayoutAwaitsAndObscuresRendering() {
        let state = presentationState(readiness: ChartLayoutReadiness())

        XCTAssertTrue(state.isAwaitingLayout)
        XCTAssertFalse(state.canUseRenderedLayout)
        XCTAssertTrue(state.shouldObscureRenderedLayout)
        XCTAssertFalse(state.showsFailure)
    }

    func testPendingReplacementBlocksCurrentRenderedLayout() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "current")
        readiness.start()

        let state = presentationState(readiness: readiness)

        XCTAssertTrue(state.isAwaitingLayout)
        XCTAssertFalse(state.canUseRenderedLayout)
        XCTAssertTrue(state.shouldObscureRenderedLayout)
    }

    func testCancelledSameLayoutKeepsRenderedLayoutUsable() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "current")
        readiness.start()
        readiness.cancel()

        let state = presentationState(readiness: readiness)

        XCTAssertFalse(state.isAwaitingLayout)
        XCTAssertTrue(state.canUseRenderedLayout)
        XCTAssertFalse(state.shouldObscureRenderedLayout)
    }

    func testSemanticFailureObscuresStaleRenderedLayout() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "stale")
        readiness.start()
        readiness.fail(
            ChartLayoutFailure(error: TestLayoutError.failed),
            layoutID: "current"
        )

        let state = presentationState(readiness: readiness)

        XCTAssertFalse(state.isAwaitingLayout)
        XCTAssertFalse(state.canUseRenderedLayout)
        XCTAssertTrue(state.shouldObscureRenderedLayout)
        XCTAssertTrue(state.showsFailure)
    }

    func testSameLayoutFailureKeepsRenderedLayoutUsable() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "current")
        readiness.start()
        readiness.fail(
            ChartLayoutFailure(error: TestLayoutError.failed),
            layoutID: "current"
        )

        let state = presentationState(readiness: readiness)

        XCTAssertFalse(state.isAwaitingLayout)
        XCTAssertTrue(state.canUseRenderedLayout)
        XCTAssertFalse(state.shouldObscureRenderedLayout)
        XCTAssertTrue(state.showsFailure)
    }

    private func presentationState(
        readiness: ChartLayoutReadiness
    ) -> ChartLayoutPresentationState {
        ChartLayoutPresentationState(
            readiness: readiness,
            layoutID: "current",
            isInputPending: false
        )
    }
}

private enum TestLayoutError: Error {
    case failed
}
