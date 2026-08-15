import Foundation
import XCTest
@testable import RadixCore

final class ScanComparisonSetupTests: XCTestCase {
    func testWarnsAndAllowsDifferentScanSettings() {
        var beforeOptions = ScanOptions()
        beforeOptions.includeHiddenFiles = true
        var afterOptions = beforeOptions
        afterOptions.treatPackagesAsDirectories = true

        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example/Documents",
                fileSize: 10,
                scanOptions: beforeOptions
            )),
            after: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example/Documents",
                fileSize: 20,
                scanOptions: afterOptions
            ))
        )

        XCTAssertTrue(setup.canCompare)
        XCTAssertNil(setup.validationMessage)
        XCTAssertEqual(
            setup.coverageWarningMessage,
            "Coverage warning: Scan settings differ, so added or removed items may reflect coverage changes rather than disk changes."
        )
    }

    func testWarnsAndAllowsMissingScanSettings() {
        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example/Documents",
                fileSize: 10,
                scanOptions: nil
            )),
            after: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example/Documents",
                fileSize: 20,
                scanOptions: ScanOptions()
            ))
        )

        XCTAssertTrue(setup.canCompare)
        XCTAssertNil(setup.validationMessage)
        XCTAssertEqual(
            setup.coverageWarningMessage,
            "Coverage warning: Scan settings are unavailable for one or both scans, so some changes may be caused by different scan coverage."
        )
    }

    func testWarnsAndAllowsLegacyCloudSemantics() throws {
        let legacyOptions = try JSONDecoder().decode(
            ScanOptions.self,
            from: Data("""
            {
              "autoSummarizeDirectories": true,
              "cloudStorageRootPath": "/Users/example/Library/CloudStorage",
              "exclusionPatterns": [],
              "iCloudDriveRootPath": "/Users/example/Library/Mobile Documents",
              "includeCloudStorage": false,
              "includeHiddenFiles": false,
              "treatPackagesAsDirectories": false
            }
            """.utf8)
        )
        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example",
                fileSize: 10,
                scanOptions: legacyOptions
            )),
            after: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example",
                fileSize: 20,
                scanOptions: ScanOptions()
            ))
        )

        XCTAssertTrue(setup.canCompare)
        XCTAssertNil(setup.validationMessage)
        XCTAssertEqual(
            setup.coverageWarningMessage,
            "Coverage warning: Scan settings differ, so added or removed items may reflect coverage changes rather than disk changes."
        )
    }

    func testBlocksSelectingTheSameScanTwice() {
        let candidate = ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
            rootPath: "/Users/example/Documents",
            fileSize: 10,
            scanOptions: ScanOptions()
        ))
        let setup = ScanComparisonSetup(before: candidate, after: candidate)

        XCTAssertFalse(setup.canCompare)
        XCTAssertEqual(setup.validationMessage, "Choose two different scans.")
        XCTAssertNil(setup.coverageWarningMessage)
    }

    func testBlocksDifferentRootsWithMatchingScanOptions() {
        var options = ScanOptions()
        options.exclusionPatterns = ["*.tmp"]

        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example",
                fileSize: 10,
                scanOptions: options
            )),
            after: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example/Documents",
                fileSize: 20,
                scanOptions: options
            ))
        )

        XCTAssertFalse(setup.canCompare)
        XCTAssertEqual(setup.validationMessage, "Choose scans of the same location.")
    }

    func testBlocksDifferentTargetKinds() {
        let options = ScanOptions()
        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example",
                fileSize: 10,
                scanOptions: options,
                targetKind: .folder
            )),
            after: ScanComparisonCandidate(snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example",
                fileSize: 20,
                scanOptions: options,
                targetKind: .volume
            ))
        )

        XCTAssertFalse(setup.canCompare)
        XCTAssertEqual(setup.validationMessage, "Choose scans of the same location.")
    }

    func testDoesNotOfferCurrentScanInBothSlots() {
        let currentSnapshot = makeComparisonSnapshot(
            rootPath: "/Users/example",
            fileSize: 20,
            scanOptions: ScanOptions()
        )
        let setup = ScanComparisonSetup(
            after: ScanComparisonCandidate(snapshot: currentSnapshot)
        )

        XCTAssertFalse(setup.canAssignCurrentScan(to: .before))
        XCTAssertTrue(setup.canAssignCurrentScan(to: .after))
    }
}
