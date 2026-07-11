import CoreGraphics
import XCTest
@testable import RadixCore

final class TreemapTooltipContentTests: XCTestCase {
    func testFolderContentIncludesSignificanceLocationAndFileCount() throws {
        let first = makeTestFileNode(id: "/disk/Documents/first", name: "first", size: 300)
        let second = makeTestFileNode(id: "/disk/Documents/second", name: "second", size: 100)
        let documents = makeTestDirectoryNode(
            id: "/disk/Documents",
            name: "Documents",
            children: [first, second]
        )
        let other = makeTestFileNode(id: "/disk/other", name: "other", size: 600)
        let root = makeTestDirectoryNode(
            id: "/disk",
            name: "Macintosh HD",
            children: [documents, other]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [documents, other],
                documents.id: [first, second]
            ]
        )
        let segment = try XCTUnwrap(segments(in: store, root: root).first { $0.id == documents.id })

        let content = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store
        )

        XCTAssertEqual(content.systemImageName, "folder.fill")
        XCTAssertEqual(content.title, "Documents")
        XCTAssertTrue(content.sizeAndSignificance.contains("40.0% of Macintosh HD"))
        XCTAssertEqual(content.location, "Macintosh HD")
        XCTAssertEqual(content.metadata, "2 files")
    }

    func testFileContentIncludesParentPathAndModificationDate() throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let report = makeTestFileNode(
            id: "/disk/Documents/Reports/annual.pdf",
            name: "annual.pdf",
            size: 100,
            lastModified: modified
        )
        let reports = makeTestDirectoryNode(
            id: "/disk/Documents/Reports",
            name: "Reports",
            children: [report]
        )
        let documents = makeTestDirectoryNode(
            id: "/disk/Documents",
            name: "Documents",
            children: [reports]
        )
        let other = makeTestFileNode(id: "/disk/other", name: "other", size: 900)
        let root = makeTestDirectoryNode(
            id: "/disk",
            name: "Macintosh HD",
            children: [documents, other]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [documents, other],
                documents.id: [reports],
                reports.id: [report]
            ]
        )
        let segment = try XCTUnwrap(segments(in: store, root: root).first { $0.id == report.id })

        let content = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store
        )

        XCTAssertEqual(content.systemImageName, "doc.fill")
        XCTAssertEqual(content.title, "annual.pdf")
        XCTAssertTrue(content.sizeAndSignificance.contains("10.0% of Macintosh HD"))
        XCTAssertEqual(content.location, "Macintosh HD › Documents › Reports")
        XCTAssertEqual(content.metadata, "Modified \(RadixFormatters.date(modified))")
    }

    func testAggregateContentIncludesContainerPathAndGroupedItemCount() throws {
        let large = makeTestFileNode(id: "/disk/Library/large", name: "large", size: 10_000)
        let small = (0..<4).map {
            makeTestFileNode(id: "/disk/Library/small-\($0)", name: "small-\($0)", size: 1)
        }
        let library = makeTestDirectoryNode(
            id: "/disk/Library",
            name: "Library",
            children: [large] + small
        )
        let root = makeTestDirectoryNode(id: "/disk", name: "Macintosh HD", children: [library])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [library], library.id: [large] + small]
        )
        let segment = try XCTUnwrap(segments(in: store, root: root).first(where: \.isAggregate))

        let content = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store
        )

        XCTAssertEqual(content.systemImageName, "square.grid.3x3.fill")
        XCTAssertEqual(content.title, "Smaller Items")
        XCTAssertEqual(content.location, "Macintosh HD › Library")
        XCTAssertEqual(content.metadata, "4 grouped items")
    }

    private func segments(
        in store: FileTreeStore,
        root: FileNodeRecord
    ) -> [TreemapSegment] {
        TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 4,
            size: CGSize(width: 800, height: 500),
            minimumTileArea: 120
        )
    }
}
