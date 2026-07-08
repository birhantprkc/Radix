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

    func testExpandedVersionOfSummarizedDirectorySuppressesMaterializedDescendants() async throws {
        let beforeCache = makeTestSummarizedDirectoryNode(id: "/before/cache", name: "cache", size: 100)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeCache])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeCache]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLeaf = makeTestFileNode(id: "/after/cache/file.bin", name: "file.bin", size: 100)
        let afterCache = makeTestDirectoryNode(id: "/after/cache", name: "cache", children: [afterLeaf])
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterCache])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterCache],
            afterCache.id: [afterLeaf],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.changedCount, 0)
    }

    func testExpandedVersionOfSummarizedDirectoryReportsOnlyBoundaryDelta() async throws {
        let beforeCache = makeTestSummarizedDirectoryNode(id: "/before/cache", name: "cache", size: 100)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeCache])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeCache]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLeaf = makeTestFileNode(id: "/after/cache/file.bin", name: "file.bin", size: 150)
        let afterCache = makeTestDirectoryNode(id: "/after/cache", name: "cache", children: [afterLeaf])
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterCache])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterCache],
            afterCache.id: [afterLeaf],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "cache")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 50)
        XCTAssertEqual(comparison.summary.allocatedDelta, 50)
    }

    func testNewHardLinkDoesNotMoveAllocatedSizeFromSharedPath() async throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let beforeShared = makeTestFileNode(
            id: "/before/z.bin",
            name: "z.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            fileIdentity: identity,
            linkCount: 1
        )
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeShared])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeShared]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterNewLink = makeTestFileNode(
            id: "/after/a/new.bin",
            name: "new.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            fileIdentity: identity,
            linkCount: 2
        )
        let afterFolder = makeTestDirectoryNode(id: "/after/a", name: "a", children: [afterNewLink])
        let afterShared = makeTestFileNode(
            id: "/after/z.bin",
            name: "z.bin",
            size: 0,
            unduplicatedAllocatedSize: 100,
            fileIdentity: identity,
            linkCount: 2
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/after",
            name: "after",
            children: [afterFolder, afterShared]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterFolder, afterShared],
            afterFolder.id: [afterNewLink],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "a")
        XCTAssertEqual(comparison.rows[0].kind, .added)
        XCTAssertEqual(comparison.rows[0].afterAllocatedSize, 0)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 0)
        XCTAssertFalse(comparison.rows.contains { $0.relativePath == "z.bin" })
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
    }

    func testRowQuerySortsDeltaByDisplayedSignedValue() {
        let grewBefore = makeTestFileNode(id: "/before/grew.bin", name: "grew.bin", size: 10)
        let grewAfter = makeTestFileNode(id: "/after/grew.bin", name: "grew.bin", size: 20)
        let shrankBefore = makeTestFileNode(id: "/before/shrank.bin", name: "shrank.bin", size: 100)
        let shrankAfter = makeTestFileNode(id: "/after/shrank.bin", name: "shrank.bin", size: 20)
        let rows = [
            ScanComparisonRow(
                relativePath: "shrank.bin",
                kind: .shrank,
                beforeNode: shrankBefore,
                afterNode: shrankAfter
            ),
            ScanComparisonRow(
                relativePath: "grew.bin",
                kind: .grew,
                beforeNode: grewBefore,
                afterNode: grewAfter
            ),
        ]
        let query = ScanComparisonRowQuery(
            changeKind: nil,
            searchText: "",
            sortOrder: [ScanComparisonRowComparator(field: .allocatedDelta, order: .reverse)]
        )

        let result = query.applying(to: rows)

        XCTAssertEqual(result.map(\.relativePath), ["grew.bin", "shrank.bin"])
    }

    func testRowQueryFiltersKindAndNormalizedPath() {
        let addedNode = makeTestFileNode(
            id: "/after/Library/Application Support/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let removedNode = makeTestFileNode(id: "/before/other.bin", name: "other.bin", size: 20)
        let rows = [
            ScanComparisonRow(
                relativePath: "Library/Application Support/cache.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: addedNode
            ),
            ScanComparisonRow(
                relativePath: "other.bin",
                kind: .removed,
                beforeNode: removedNode,
                afterNode: nil
            ),
        ]
        let query = ScanComparisonRowQuery(
            changeKind: .added,
            searchText: "application support",
            sortOrder: []
        )

        let result = query.applying(to: rows)

        XCTAssertEqual(result.map(\.relativePath), ["Library/Application Support/cache.bin"])
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
