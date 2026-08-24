import XCTest
@testable import RadixCore

final class InspectorSelectionSummaryTests: XCTestCase {
    func testSiblingSelectionsAreAggregated() {
        let first = makeTestFileNode(id: "/root/first.txt", name: "first.txt", size: 12)
        let second = makeTestFileNode(id: "/root/second.txt", name: "second.txt", size: 5)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])

        let summary = InspectorSelectionSummary(
            selectedNodes: [first, second],
            fileTreeStore: store
        )

        XCTAssertEqual(summary.selectedCount, 2)
        XCTAssertEqual(summary.countedNodes.map(\.id), [first.id, second.id])
        XCTAssertEqual(summary.allocatedSize, 17)
        XCTAssertEqual(summary.logicalSize, 17)
        XCTAssertFalse(summary.containsOverlappingSelections)
    }

    func testNestedSelectionIsCountedOnce() {
        let nestedFile = makeTestFileNode(
            id: "/root/folder/nested.txt",
            name: "nested.txt",
            size: 20
        )
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [nestedFile]
        )
        let sibling = makeTestFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 5)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [nestedFile]
        ])

        let summary = InspectorSelectionSummary(
            selectedNodes: [nestedFile, folder, sibling],
            fileTreeStore: store
        )

        XCTAssertEqual(summary.selectedCount, 3)
        XCTAssertEqual(summary.countedNodes.map(\.id), [folder.id, sibling.id])
        XCTAssertEqual(summary.allocatedSize, 25)
        XCTAssertEqual(summary.logicalSize, 25)
        XCTAssertTrue(summary.containsOverlappingSelections)
    }
}
