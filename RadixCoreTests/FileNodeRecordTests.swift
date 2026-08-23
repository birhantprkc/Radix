import XCTest
@testable import RadixCore

final class FileNodeRecordTests: XCTestCase {
    func testVolumeRootUsesVolumeKindWhileOrdinaryDirectoriesRemainFolders() {
        let volumeRoot = makeTestDirectoryNode(id: "/", name: "Macintosh HD", children: [])
        let volumeTarget = ScanTarget(url: volumeRoot.url, kind: .volume)
        let ordinaryFolder = makeTestDirectoryNode(id: "/Users", name: "Users", children: [])

        XCTAssertEqual(volumeRoot.itemKind(activeTarget: volumeTarget), "Volume")
        XCTAssertEqual(ordinaryFolder.itemKind(activeTarget: volumeTarget), "Folder")
        XCTAssertEqual(volumeRoot.itemKind(activeTarget: ScanTarget(url: volumeRoot.url, kind: .folder)), "Folder")
    }

    func testSyntheticVolumeVisualizationRootUsesVolumeKind() {
        let target = ScanTarget(url: URL(filePath: "/", directoryHint: .isDirectory), kind: .volume)
        let visualizationRoot = FileNodeRecord.directory(
            id: "/\u{0}radix-volume-capacity",
            url: target.url,
            name: "Macintosh HD",
            children: [],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        XCTAssertEqual(visualizationRoot.itemKind(activeTarget: target), "Volume")
    }

    func testSharedAPFSStorageStatusDistinguishesFullAndPartialClones() {
        let fullClone = makeTestFileNode(
            id: "/full.bin",
            name: "full.bin",
            cloneIdentity: CloneIdentity(device: 1, cloneID: 2),
            mayShareDataBlocks: true
        )
        let partialClone = makeTestFileNode(
            id: "/partial.bin",
            name: "partial.bin",
            mayShareDataBlocks: true
        )

        XCTAssertEqual(fullClone.secondaryStatusText, "APFS clone · shared storage")
        XCTAssertEqual(partialClone.secondaryStatusText, "May share APFS storage")
    }
}
