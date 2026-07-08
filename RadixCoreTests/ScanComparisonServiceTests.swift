import XCTest
@testable import RadixCore

final class ScanComparisonServiceTests: XCTestCase {
    func testComparesSnapshotsByRelativePathAcrossDifferentRoots() async throws {
        let beforeFile = makeTestFileNode(id: "/before/shared.bin", name: "shared.bin", size: 10)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeFile])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeFile]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterFile = makeTestFileNode(id: "/after/shared.bin", name: "shared.bin", size: 25)
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterFile])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [afterFile]])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "shared.bin")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 15)
        XCTAssertEqual(comparison.summary.allocatedDelta, 15)
        XCTAssertEqual(comparison.summary.grewCount, 1)
    }

    func testAddedAndRemovedDirectoriesSuppressDescendantRows() async throws {
        let removedChild = makeTestFileNode(id: "/before/removed/child.bin", name: "child.bin", size: 30)
        let removedFolder = makeTestDirectoryNode(id: "/before/removed", name: "removed", children: [removedChild])
        let sharedBefore = makeTestFileNode(id: "/before/shared.bin", name: "shared.bin", size: 10)
        let beforeRoot = makeTestDirectoryNode(
            id: "/before",
            name: "before",
            children: [removedFolder, sharedBefore]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [removedFolder, sharedBefore],
            removedFolder.id: [removedChild],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let addedChild = makeTestFileNode(id: "/after/added/child.bin", name: "child.bin", size: 80)
        let addedFolder = makeTestDirectoryNode(id: "/after/added", name: "added", children: [addedChild])
        let sharedAfter = makeTestFileNode(id: "/after/shared.bin", name: "shared.bin", size: 45)
        let afterRoot = makeTestDirectoryNode(
            id: "/after",
            name: "after",
            children: [addedFolder, sharedAfter]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [addedFolder, sharedAfter],
            addedFolder.id: [addedChild],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(
            comparison.rows.map { "\($0.kind.rawValue):\($0.relativePath)" },
            [
                "added:added",
                "grew:shared.bin",
                "removed:removed",
            ]
        )
        XCTAssertFalse(comparison.rows.contains { $0.relativePath.contains("child.bin") })
        XCTAssertEqual(comparison.summary.addedCount, 1)
        XCTAssertEqual(comparison.summary.removedCount, 1)
        XCTAssertEqual(comparison.summary.grewCount, 1)
        XCTAssertEqual(comparison.summary.changedCount, 3)
    }

    func testNestedFileGrowthDoesNotEmitAncestorDirectoryRows() async throws {
        let beforeLeaf = makeTestFileNode(id: "/before/a/b/file.bin", name: "file.bin", size: 10)
        let beforeInner = makeTestDirectoryNode(id: "/before/a/b", name: "b", children: [beforeLeaf])
        let beforeOuter = makeTestDirectoryNode(id: "/before/a", name: "a", children: [beforeInner])
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeOuter])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeOuter],
            beforeOuter.id: [beforeInner],
            beforeInner.id: [beforeLeaf],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLeaf = makeTestFileNode(id: "/after/a/b/file.bin", name: "file.bin", size: 100)
        let afterInner = makeTestDirectoryNode(id: "/after/a/b", name: "b", children: [afterLeaf])
        let afterOuter = makeTestDirectoryNode(id: "/after/a", name: "a", children: [afterInner])
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterOuter])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterOuter],
            afterOuter.id: [afterInner],
            afterInner.id: [afterLeaf],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "a/b/file.bin")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 90)
        XCTAssertFalse(comparison.rows.contains { $0.isDirectory })
        XCTAssertEqual(comparison.summary.grewCount, 1)
        XCTAssertEqual(comparison.summary.changedCount, 1)
        // The aggregate delta still reflects the full change even though no directory row is emitted.
        XCTAssertEqual(comparison.summary.allocatedDelta, 90)
    }

    func testSummarizedLeafDirectoryGrowthEmitsRow() async throws {
        // An auto-summarized directory is a leaf node with no indexed children, so its size
        // change has no descendant rows to represent it and must be reported directly.
        let beforeCache = makeTestSummarizedDirectoryNode(id: "/before/cache", name: "cache", size: 100)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeCache])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeCache]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterCache = makeTestSummarizedDirectoryNode(id: "/after/cache", name: "cache", size: 500)
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterCache])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [afterCache]])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "cache")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertTrue(comparison.rows[0].isDirectory)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 400)
        XCTAssertEqual(comparison.summary.grewCount, 1)
    }

    func testUnchangedAndRootRowsAreExcluded() async throws {
        let unchangedBefore = makeTestFileNode(id: "/before/unchanged.bin", name: "unchanged.bin", size: 20)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [unchangedBefore])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [unchangedBefore]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let unchangedAfter = makeTestFileNode(id: "/after/unchanged.bin", name: "unchanged.bin", size: 20)
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [unchangedAfter])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [unchangedAfter]])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.changedCount, 0)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
    }
}
