import XCTest
@testable import RadixCore

final class ChartViewportTransformTests: XCTestCase {
    func testZoomExpandsChartAroundBaseCenter() {
        let baseFrame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let transform = ChartViewportTransform().zoomed(
            by: 2,
            anchor: nil,
            in: baseFrame
        )

        XCTAssertEqual(transform.scale, 2)
        XCTAssertEqual(transform.offset, .zero)
        XCTAssertEqual(transform.frame(for: baseFrame), CGRect(x: -90, y: -30, width: 400, height: 200))
    }

    func testZoomAroundAnchorKeepsAnchoredPointStable() throws {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let anchor = CGPoint(x: 150, y: 100)
        let transform = ChartViewportTransform().zoomed(
            by: 2,
            anchor: anchor,
            in: baseFrame
        )

        let localChartPoint = try XCTUnwrap(transform.localChartPoint(for: anchor, in: baseFrame))

        XCTAssertEqual(transform.offset, CGSize(width: -50, height: 0))
        XCTAssertEqual(localChartPoint.point, CGPoint(x: 300, y: 200))
        XCTAssertEqual(localChartPoint.size, CGSize(width: 400, height: 400))
    }

    func testZoomAroundAnchorKeepsPannedContentStable() throws {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let anchor = CGPoint(x: 60, y: 40)
        let transform = ChartViewportTransform(
            scale: 2,
            offset: CGSize(width: 30, height: -10)
        )
        let originalPoint = try XCTUnwrap(
            transform.localChartPoint(for: anchor, in: baseFrame)
        )

        let zoomed = transform.zoomed(
            by: 1.5,
            anchor: anchor,
            in: baseFrame
        )
        let zoomedPoint = try XCTUnwrap(
            zoomed.localChartPoint(for: anchor, in: baseFrame)
        )

        XCTAssertEqual(zoomed.scale, 3)
        XCTAssertEqual(zoomed.offset, CGSize(width: 65, height: -10))
        XCTAssertEqual(
            zoomedPoint.point.x / zoomedPoint.size.width,
            originalPoint.point.x / originalPoint.size.width,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            zoomedPoint.point.y / zoomedPoint.size.height,
            originalPoint.point.y / originalPoint.size.height,
            accuracy: 0.000_001
        )
    }

    func testInverseMappingCombinesZoomAndPanInNonSquareViewport() throws {
        let baseFrame = CGRect(x: 0, y: 0, width: 300, height: 120)
        let transform = ChartViewportTransform(
            scale: 2.5,
            offset: CGSize(width: -70, height: 35)
        )
        let pointer = CGPoint(x: 80, y: 60)

        let chartPoint = try XCTUnwrap(
            transform.localChartPoint(for: pointer, in: baseFrame)
        )

        XCTAssertEqual(chartPoint.point, CGPoint(x: 375, y: 115))
        XCTAssertEqual(chartPoint.size, CGSize(width: 750, height: 300))
        XCTAssertEqual(
            chartPoint.point.x / chartPoint.size.width,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            chartPoint.point.y / chartPoint.size.height,
            115 / 300,
            accuracy: 0.000_001
        )
    }

    func testPanOffsetIsConstrainedToKeepBaseFrameCovered() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = ChartViewportTransform(scale: 2).panned(
            by: CGSize(width: 500, height: -500),
            in: baseFrame
        )

        XCTAssertEqual(transform.offset, CGSize(width: 100, height: -50))
        XCTAssertTrue(transform.frame(for: baseFrame).contains(baseFrame))
    }

    func testRevealingPointPansZoomedViewportIntoSafeFrame() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let transform = ChartViewportTransform(scale: 2)

        let revealed = transform.revealing(
            point: CGPoint(x: 280, y: 100),
            within: baseFrame,
            padding: 10
        )

        XCTAssertEqual(revealed.offset, CGSize(width: -90, height: 0))
    }

    func testRevealingVisiblePointPreservesViewport() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let transform = ChartViewportTransform(
            scale: 2,
            offset: CGSize(width: 20, height: -10)
        )

        XCTAssertEqual(
            transform.revealing(
                point: CGPoint(x: 100, y: 100),
                within: baseFrame,
                padding: 10
            ),
            transform
        )
    }

    func testConstrainedShrinksOffsetForSmallerFrame() {
        let smallerFrame = CGRect(x: 0, y: 0, width: 120, height: 80)
        let transform = ChartViewportTransform(
            scale: 2,
            offset: CGSize(width: 100, height: -100)
        ).constrained(to: smallerFrame)

        XCTAssertEqual(transform.offset, CGSize(width: 60, height: -40))
        XCTAssertTrue(transform.frame(for: smallerFrame).contains(smallerFrame))
    }

    func testZoomOutToMinimumResetsOffset() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = ChartViewportTransform(
            scale: 2,
            offset: CGSize(width: 40, height: -20)
        ).zoomed(
            by: 0.1,
            anchor: CGPoint(x: 50, y: 25),
            in: baseFrame
        )

        XCTAssertEqual(transform, .identity)
    }

    func testZoomRespectsCustomMaximumScale() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = ChartViewportTransform().zoomed(
            by: 4,
            anchor: nil,
            in: baseFrame,
            maximumScale: 2
        )

        XCTAssertEqual(transform.scale, 2)
    }
}
