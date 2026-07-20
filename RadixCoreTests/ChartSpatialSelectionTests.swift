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

    func testUsesFirstCandidateWhenSelectionIsMissing() {
        let candidates = [
            candidate("first", x: 20, y: 20),
            candidate("second", x: 40, y: 20)
        ]

        XCTAssertEqual(next(from: nil, moving: .right, among: candidates), "first")
        XCTAssertEqual(next(from: "not-rendered", moving: .left, among: candidates), "first")
    }

    func testReturnsNilAtDirectionalEdge() {
        let candidates = [
            candidate("left", x: 20, y: 20),
            candidate("right", x: 40, y: 20)
        ]

        XCTAssertNil(next(from: "right", moving: .right, among: candidates))
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
