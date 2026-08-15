import XCTest

final class BenchmarkSupportTests: XCTestCase {
    func testMedianHandlesEmptyOddAndEvenSamples() {
        XCTAssertNil(BenchmarkSupport.median([]))
        XCTAssertEqual(BenchmarkSupport.median([3, 1, 2]), 2)
        XCTAssertEqual(BenchmarkSupport.median([4, 1, 3, 2]), 2.5)
    }

    func testDurationSecondsIncludesAttoseconds() {
        XCTAssertEqual(
            BenchmarkSupport.durationSeconds(.seconds(1) + .milliseconds(250)),
            1.25,
            accuracy: 0.000_001
        )
    }

    func testByteDeltaClampsDecreasesToZero() {
        XCTAssertEqual(BenchmarkSupport.byteDelta(from: 100, to: 125), 25)
        XCTAssertEqual(BenchmarkSupport.byteDelta(from: 125, to: 100), 0)
    }

    func testResultLinePreservesBenchmarkOutputFormat() {
        XCTAssertEqual(
            BenchmarkSupport.resultLine(
                prefix: "TEST_RESULT",
                phase: "fixture",
                seconds: 1.25,
                count: 7,
                peakRSS: 99,
                extra: "fingerprint=abc"
            ),
            "TEST_RESULT phase=fixture seconds=1.250000 count=7 peak_rss=99 fingerprint=abc"
        )
        XCTAssertEqual(
            BenchmarkSupport.resultLine(
                prefix: "TEST_RESULT",
                phase: "fixture",
                seconds: 0,
                count: 0,
                peakRSS: 0
            ),
            "TEST_RESULT phase=fixture seconds=0.000000 count=0 peak_rss=0 "
        )
    }
}
