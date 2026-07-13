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
}
