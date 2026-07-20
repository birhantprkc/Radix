import XCTest
@testable import RadixCore

final class ScanExclusionMatcherTests: XCTestCase {
    func testCommonBasenamePatternsPreserveExactAndSimpleGlobSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ScanExclusionMatcher.commonPresetPatterns,
            rootPath: rootPath
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

    func testKnownChildMatchingPreservesBasenameAndPathRules() {
        let rootPath = "/Users/alex"
        let matcher = ScanExclusionMatcher(
            patterns: ["*.log", "Sources/**/generated.swift"],
            rootPath: rootPath
        )
        let cases = [
            ("debug.log", "/Users/alex/Logs", false, true),
            ("generated.swift", "/Users/alex/Sources/Module", false, true),
            ("App.swift", "/Users/alex/Sources", false, false),
        ]

        for (name, parentPath, isDirectory, expected) in cases {
            XCTAssertEqual(
                matcher.excludesKnownNormalizedChild(
                    named: name,
                    under: parentPath,
                    isDirectory: isDirectory
                ),
                expected,
                parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
            )
        }

        let filesystemRootMatcher = ScanExclusionMatcher(
            patterns: ["System/**"],
            rootPath: "/"
        )
        XCTAssertTrue(filesystemRootMatcher.excludesKnownNormalizedChild(
            named: "System",
            under: "/",
            isDirectory: true
        ))
    }

    func testSimpleBasenameGlobStrategiesPreserveWildcardSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["debug-*", "*-cache", "*temporary*", "file?.txt"],
            rootPath: rootPath
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
            rootPath: rootPath
        )

        XCTAssertTrue(matcher.excludesKnownNormalizedPath("\(rootPath)/Library/Caches", isDirectory: true))
        XCTAssertFalse(matcher.excludesKnownNormalizedPath("\(rootPath)/Library/Caches/file.bin", isDirectory: false))
    }

    func testComplexGlobUsesBoundedMatchingAndPreservesGlobstarSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["**/cache/**/file?.txt", "*a*a*a*a*a*a*a*a*b"],
            rootPath: rootPath
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

    func testMatcherHandlesManyExcludedChildren() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: [
                "node_modules/",
                "*.log",
                "Library/Caches/**"
            ],
            rootPath: rootPath
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
        XCTAssertFalse(
            matcher.excludes(
                URL(filePath: "\(rootPath)/Sources/App.swift"),
                isDirectory: false
            )
        )
    }

    func testCloudStorageLocationRecognizesManagedRootsWithoutNearPrefixMatches() {
        XCTAssertTrue(CloudStorageLocation.contains(path: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"))
        XCTAssertTrue(CloudStorageLocation.contains(path: "/Users/blair/Library/Mobile Documents/com~apple~CloudDocs/file.bin"))
        XCTAssertFalse(CloudStorageLocation.contains(path: "/Users/alex/Library/CloudStorageBackup/file.bin"))
        XCTAssertFalse(CloudStorageLocation.contains(path: "/Users/alex/Library/Mobile Documents Backup/file.bin"))
        XCTAssertFalse(CloudStorageLocation.contains(path: "/Library/CloudStorage/file.bin"))
    }

    func testCloudStorageLocationClassifiesDirectItemsWithoutRootLookup() {
        let impact = CloudStorageLocation.impact(
            of: URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"),
            cloudRootExists: { _ in
                XCTFail("Direct cloud items should not require a root existence check.")
                return false
            }
        )

        XCTAssertEqual(impact, .storedInCloud)
    }

    func testCloudStorageLocationOnlyClassifiesAncestorsWhenManagedRootExists() {
        let libraryURL = URL(filePath: "/Users/alex/Library", directoryHint: .isDirectory)

        XCTAssertNil(CloudStorageLocation.impact(of: libraryURL, cloudRootExists: { _ in false }))
        XCTAssertEqual(
            CloudStorageLocation.impact(
                of: libraryURL,
                cloudRootExists: { $0.path == "/Users/alex/Library/CloudStorage" }
            ),
            .containsCloudStorage
        )
        XCTAssertNil(CloudStorageLocation.impact(
            of: URL(filePath: "/Users/alex/Documents"),
            cloudRootExists: { _ in true }
        ))
    }
}
