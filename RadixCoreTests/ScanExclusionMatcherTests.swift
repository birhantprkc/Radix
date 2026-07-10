import XCTest
@testable import RadixCore

final class ScanExclusionMatcherTests: XCTestCase {
    func testCommonBasenamePatternsPreserveExactAndSimpleGlobSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ScanExclusionMatcher.commonPresetPatterns,
            rootPath: rootPath,
            includeCloudStorage: true
        )

        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/Packages/node_modules", isDirectory: true))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("\(rootPath)/Packages/node_modules", isDirectory: false))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/Logs/debug.log", isDirectory: false))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("\(rootPath)/Logs/debug.log.1", isDirectory: false))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/.DS_Store", isDirectory: false))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/Project/build", isDirectory: true))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("\(rootPath)/Project/build", isDirectory: false))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/Project/DerivedData", isDirectory: true))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("\(rootPath)/Sources/App.swift", isDirectory: false))
    }

    func testSimpleBasenameGlobStrategiesPreserveWildcardSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["debug-*", "*-cache", "*temporary*", "file?.txt"],
            rootPath: rootPath,
            includeCloudStorage: true
        )

        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/debug-output", isDirectory: false))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/image-cache", isDirectory: false))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/my-temporary-file", isDirectory: false))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/file1.txt", isDirectory: false))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("\(rootPath)/file10.txt", isDirectory: false))
    }

    func testPathGlobSingleStarStillDoesNotCrossDirectorySeparators() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["Library/*"],
            rootPath: rootPath,
            includeCloudStorage: true
        )

        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/Library/Caches", isDirectory: true))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("\(rootPath)/Library/Caches/file.bin", isDirectory: false))
    }

    func testMatcherHandlesManyExcludedChildren() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: [
                "node_modules/",
                "*.log",
                "Library/Caches/**"
            ],
            rootPath: rootPath,
            includeCloudStorage: false,
            cloudStorageRootPath: "\(rootPath)/Library/CloudStorage"
        )

        for index in 0..<512 {
            XCTAssertTrue(
                matcher.excludes(
                    URL(filePath: "\(rootPath)/Packages/pkg\(index)/node_modules", directoryHint: .isDirectory),
                    isDirectory: true
                )
            )
            XCTAssertTrue(
                matcher.excludes(
                    URL(filePath: "\(rootPath)/Logs/./debug-\(index).log"),
                    isDirectory: false
                )
            )
        }

        XCTAssertTrue(
            matcher.excludes(
                URL(filePath: "\(rootPath)/Library/Caches/build/artifact.o"),
                isDirectory: false
            )
        )
        XCTAssertTrue(
            matcher.excludes(
                URL(filePath: "\(rootPath)/Library/CloudStorage/Dropbox/remote.bin"),
                isDirectory: false
            )
        )
        XCTAssertFalse(
            matcher.excludes(
                URL(filePath: "\(rootPath)/Sources/App.swift"),
                isDirectory: false
            )
        )
    }
}
