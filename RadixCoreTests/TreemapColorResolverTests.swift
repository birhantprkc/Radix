import XCTest
@testable import RadixCore

final class TreemapColorResolverTests: XCTestCase {
    func testTopLevelBranchesUseDistinctCuratedHues() {
        let tokens = (0..<8).map { index in
            SunburstColorToken(
                branchID: "branch-\(index)",
                localID: "branch-\(index)",
                branchIndex: index,
                branchCount: 8,
                siblingIndex: index,
                siblingCount: 8,
                depth: 0,
                role: .normal
            )
        }

        let colors = tokens.map {
            TreemapColorResolver.components(for: $0, appearance: .dark)
        }

        XCTAssertEqual(Set(colors.map(\.hue)).count, 8)
        XCTAssertTrue(colors.allSatisfy { (0.44...0.66).contains($0.saturation) })
        XCTAssertTrue(colors.allSatisfy { (0.46...0.68).contains($0.brightness) })
    }

    func testSiblingTilesVaryWithinTheSameBranch() {
        let tokens = (0..<5).map { index in
            SunburstColorToken(
                branchID: "branch",
                localID: "branch/child-\(index)",
                branchIndex: 0,
                branchCount: 2,
                siblingIndex: index,
                siblingCount: 5,
                depth: 1,
                role: .normal
            )
        }

        let colors = tokens.map {
            TreemapColorResolver.components(for: $0, appearance: .dark)
        }

        XCTAssertEqual(Set(colors).count, tokens.count)
        XCTAssertGreaterThan((colors.map(\.hue).max() ?? 0) - (colors.map(\.hue).min() ?? 0), 0.04)
    }

    func testAppearanceUsesDarkAndLightBrightnessBands() {
        let token = SunburstColorToken.single(id: "branch", depth: 2)

        let dark = TreemapColorResolver.components(for: token, appearance: .dark)
        let light = TreemapColorResolver.components(for: token, appearance: .light)

        XCTAssertLessThan(dark.brightness, light.brightness)
        XCTAssertGreaterThanOrEqual(dark.brightness, 0.46)
        XCTAssertLessThanOrEqual(dark.brightness, 0.68)
        XCTAssertGreaterThanOrEqual(light.brightness, 0.73)
        XCTAssertLessThanOrEqual(light.brightness, 0.93)
    }

    func testAggregateAndFreeSpaceTilesRemainNeutral() {
        let aggregate = SunburstColorToken.single(id: "aggregate", role: .aggregate)
        let freeSpace = SunburstColorToken.single(id: "free", role: .freeSpace)

        for appearance in [TreemapColorAppearance.light, .dark] {
            XCTAssertEqual(
                TreemapColorResolver.components(for: aggregate, appearance: appearance).saturation,
                0
            )
            XCTAssertEqual(
                TreemapColorResolver.components(for: freeSpace, appearance: appearance).saturation,
                0
            )
        }
    }
}
