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
        XCTAssertEqual(summary.topLevelSelectedNodes.map(\.id), [first.id, second.id])
        XCTAssertEqual(summary.topLevelSelectedCount, 2)
        XCTAssertEqual(summary.allocatedSize, 17)
        XCTAssertFalse(summary.containsOverlappingSelections)
        XCTAssertEqual(summary.missingSelectedNodeCount, 0)
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
        XCTAssertEqual(summary.topLevelSelectedNodes.map(\.id), [folder.id, sibling.id])
        XCTAssertEqual(summary.topLevelSelectedCount, 2)
        XCTAssertEqual(summary.allocatedSize, 25)
        XCTAssertTrue(summary.containsOverlappingSelections)
        XCTAssertEqual(summary.missingSelectedNodeCount, 0)
    }

    func testMissingSelectionIsNotReportedAsOverlap() {
        let present = makeTestFileNode(id: "/root/present.txt", name: "present.txt", size: 12)
        let stale = makeTestFileNode(id: "/root/stale.txt", name: "stale.txt", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [present])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [present]])

        let summary = InspectorSelectionSummary(
            selectedNodes: [present, stale],
            fileTreeStore: store
        )

        XCTAssertEqual(summary.selectedCount, 2)
        XCTAssertEqual(summary.topLevelSelectedNodes.map(\.id), [present.id])
        XCTAssertEqual(summary.topLevelSelectedCount, 1)
        XCTAssertEqual(summary.allocatedSize, present.allocatedSize)
        XCTAssertFalse(summary.containsOverlappingSelections)
        XCTAssertEqual(summary.missingSelectedNodeCount, 1)
    }

    func testSelectionPresentationCountsKindsAndOrdersLargestItemsFirst() {
        let file = makeTestFileNode(id: "/root/file.txt", name: "file.txt", size: 8)
        let folderChild = makeTestFileNode(id: "/root/folder/child.txt", name: "child.txt", size: 20)
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [folderChild]
        )
        let packageChild = makeTestFileNode(id: "/root/App.app/item", name: "item", size: 12)
        let package = makeTestDirectoryNode(
            id: "/root/App.app",
            name: "App.app",
            children: [packageChild],
            isPackage: true
        )

        let summary = InspectorSelectionSummary(
            selectedNodes: [file, package, folder],
            fileTreeStore: nil
        )

        XCTAssertEqual(summary.selectedFolderCount, 1)
        XCTAssertEqual(summary.selectedFileCount, 1)
        XCTAssertEqual(summary.selectedPackageCount, 1)
        XCTAssertEqual(summary.selectedStorageCategoryCount, 0)
        XCTAssertEqual(
            summary.selectedNodesByAllocatedSize.map(\.id),
            [folder.id, package.id, file.id]
        )
        XCTAssertEqual(
            summary.largestSelectedNodes(limit: 2).map(\.id),
            [folder.id, package.id]
        )
    }

    func testSyntheticStorageAndSharedFilesHaveDistinctPresentationState() {
        let synthetic = makeTestFileNode(
            id: "/root/unattributed",
            name: "Unattributed",
            size: 30,
            isSynthetic: true
        )
        let clone = makeTestFileNode(
            id: "/root/clone.dat",
            name: "clone.dat",
            size: 12,
            cloneIdentity: CloneIdentity(device: 1, cloneID: 7)
        )

        let summary = InspectorSelectionSummary(
            selectedNodes: [synthetic, clone],
            fileTreeStore: nil
        )

        XCTAssertEqual(summary.selectedFileCount, 1)
        XCTAssertEqual(summary.selectedStorageCategoryCount, 1)
        XCTAssertTrue(summary.containsSharedStorageItems)
        XCTAssertTrue(summary.containsKnownClones)
    }
}
