import CoreGraphics
import XCTest
@testable import RadixCore

final class TreemapTooltipPlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    private let tooltipSize = CGSize(width: 200, height: 80)

    func testPlacesTooltipBelowAndRightOfPointerWhenSpaceIsAvailable() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 100, y: 100),
            tooltipSize: tooltipSize,
            in: bounds
        )

        XCTAssertEqual(origin, CGPoint(x: 114, y: 114))
    }

    func testFlipsTooltipLeftNearRightEdge() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 580, y: 100),
            tooltipSize: tooltipSize,
            in: bounds
        )

        XCTAssertEqual(origin, CGPoint(x: 366, y: 114))
    }

    func testFlipsTooltipAboveNearBottomEdge() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 100, y: 380),
            tooltipSize: tooltipSize,
            in: bounds
        )

        XCTAssertEqual(origin, CGPoint(x: 114, y: 286))
    }

    func testClampsOversizedTooltipToBoundsMargin() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 10, y: 10),
            tooltipSize: CGSize(width: 800, height: 500),
            in: bounds
        )

        XCTAssertEqual(origin, CGPoint(x: 8, y: 8))
    }

    func testTinyBoundsDoNotProduceAnInvertedPlacementArea() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 5, y: 4),
            tooltipSize: tooltipSize,
            in: CGRect(x: 0, y: 0, width: 10, height: 8)
        )

        XCTAssertEqual(origin, CGPoint(x: 5, y: 4))
    }
}
