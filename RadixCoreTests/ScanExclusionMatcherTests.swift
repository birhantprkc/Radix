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

    func testComplexGlobUsesBoundedMatchingAndPreservesGlobstarSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["**/cache/**/file?.txt", "*a*a*a*a*a*a*a*a*b"],
            rootPath: rootPath,
            includeCloudStorage: true
        )

        XCTAssertTrue(matcher.excludesKnownNormalizedPath(
            "\(rootPath)/Sources/cache/nested/file1.txt",
            isDirectory: false
        ))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath(
            "\(rootPath)/Sources/cache/nested/file10.txt",
            isDirectory: false
        ))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath(
            "\(rootPath)/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            isDirectory: false
        ))
    }

    func testSingleUserCloudRuleCompilesConcreteBoundaryAwarePrefixes() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users/alex",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertTrue(matcher.excludesKnownNormalizedPath(
            "/Users/alex/Library/CloudStorage/Dropbox/file.bin",
            isDirectory: false
        ))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath(
            "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin",
            isDirectory: false
        ))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath(
            "/Users/alex/Library/CloudStorageBackup/file.bin",
            isDirectory: false
        ))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath(
            "/Users/alexander/Library/CloudStorage/file.bin",
            isDirectory: false
        ))
    }

    func testRootCloudRuleRejectsMalformedAndNearPrefixPaths() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertTrue(matcher.excludesKnownNormalizedPath(
            "/Users/alex/Library/CloudStorage/file.bin",
            isDirectory: false
        ))
        XCTAssertTrue(matcher.excludesKnownNormalizedPath(
            "/Users/blair/Library/Mobile Documents/file.bin",
            isDirectory: false
        ))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath(
            "/Users//Library/CloudStorage/file.bin",
            isDirectory: false
        ))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("/Users/alex", isDirectory: true))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath(
            "/Users/alex/Library/Mobile Documents Backup/file.bin",
            isDirectory: false
        ))
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
