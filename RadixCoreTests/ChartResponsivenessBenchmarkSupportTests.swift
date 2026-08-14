import XCTest

final class ChartResponsivenessBenchmarkSupportTests: XCTestCase {
    func testMedianReturnsNilForEmptySamples() {
        XCTAssertNil(ChartResponsivenessBenchmarkSupport.median([]))
    }
}
