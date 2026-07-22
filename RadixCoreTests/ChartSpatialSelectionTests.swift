import CoreGraphics
import XCTest
@testable import RadixCore

final class ChartSpatialSelectionTests: XCTestCase {
    func testChoosesClosestWellAlignedCandidateInEachDirection() {
        let candidates = [
            candidate("center", x: 100, y: 100),
            candidate("up", x: 100, y: 60),
            candidate("down", x: 100, y: 140),
            candidate("left", x: 60, y: 100),
            candidate("right", x: 140, y: 100),
            candidate("off-axis", x: 105, y: 20)
        ]

        XCTAssertEqual(next(from: "center", moving: .up, among: candidates), "up")
        XCTAssertEqual(next(from: "center", moving: .down, among: candidates), "down")
        XCTAssertEqual(next(from: "center", moving: .left, among: candidates), "left")
        XCTAssertEqual(next(from: "center", moving: .right, among: candidates), "right")
    }

    func testInvalidSelectionUsesDirectionalEntryEdge() {
        let candidates = [
            candidate("first", x: 20, y: 20),
            candidate("second", x: 40, y: 20)
        ]

        XCTAssertEqual(next(from: nil, moving: .right, among: candidates), "first")
        XCTAssertEqual(next(from: "not-rendered", moving: .left, among: candidates), "second")
    }

    func testReturnsNilAtDirectionalEdge() {
        let candidates = [
            candidate("left", x: 20, y: 20),
            candidate("right", x: 40, y: 20)
        ]

        XCTAssertNil(next(from: "right", moving: .right, among: candidates))
    }

    func testRejectsCandidateThatIsMostlyPerpendicularToMovement() {
        let candidates = [
            candidate("current", x: 0, y: 0),
            candidate("mostly-down", x: 1, y: 10),
            candidate("right", x: 30, y: 0)
        ]

        XCTAssertEqual(next(from: "current", moving: .right, among: candidates), "right")
    }

    func testMissingSelectionEntersFromEdgeOppositeMovement() {
        let candidates = [
            candidate("center", x: 50, y: 50),
            candidate("right", x: 90, y: 50),
            candidate("bottom", x: 50, y: 90),
            candidate("left", x: 10, y: 50),
            candidate("top", x: 50, y: 10)
        ]

        XCTAssertEqual(next(from: nil, moving: .right, among: candidates), "left")
        XCTAssertEqual(next(from: nil, moving: .left, among: candidates), "right")
        XCTAssertEqual(next(from: nil, moving: .down, among: candidates), "top")
        XCTAssertEqual(next(from: nil, moving: .up, among: candidates), "bottom")
    }

    private func next(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartSpatialSelectionCandidate]
    ) -> String? {
        ChartSpatialSelection.nextNodeID(
            from: selectedNodeID,
            moving: direction,
            among: candidates
        )
    }

    private func candidate(_ nodeID: String, x: CGFloat, y: CGFloat) -> ChartSpatialSelectionCandidate {
        ChartSpatialSelectionCandidate(nodeID: nodeID, center: CGPoint(x: x, y: y))
    }
}
