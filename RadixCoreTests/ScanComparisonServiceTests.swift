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
        XCTAssertEqual(comparison.summary.changedCount, 1)
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
        XCTAssertEqual(comparison.summary.fileCountDelta, 0)
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

    func testMultipleHardLinkGroupsKeepSparseAncestorAdjustmentsBalanced() async throws {
        let firstIdentity = FileIdentity(device: 1, inode: 101)
        let secondIdentity = FileIdentity(device: 1, inode: 202)

        func hardLink(
            root: String,
            name: String,
            size: Int64,
            unduplicatedSize: Int64,
            identity: FileIdentity
        ) -> FileNodeRecord {
            makeTestFileNode(
                id: "\(root)/folder/\(name)",
                name: name,
                size: size,
                unduplicatedAllocatedSize: unduplicatedSize,
                fileIdentity: identity,
                linkCount: 2
            )
        }

        let beforeFiles = [
            hardLink(root: "/before", name: "a-one", size: 0, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/before", name: "z-one", size: 100, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/before", name: "a-two", size: 0, unduplicatedSize: 200, identity: secondIdentity),
            hardLink(root: "/before", name: "z-two", size: 200, unduplicatedSize: 200, identity: secondIdentity),
        ]
        let beforeFolder = makeTestDirectoryNode(id: "/before/folder", name: "folder", children: beforeFiles)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeFolder])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeFolder],
            beforeFolder.id: beforeFiles,
        ])

        let afterFiles = [
            hardLink(root: "/after", name: "a-one", size: 100, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/after", name: "z-one", size: 0, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/after", name: "a-two", size: 200, unduplicatedSize: 200, identity: secondIdentity),
            hardLink(root: "/after", name: "z-two", size: 0, unduplicatedSize: 200, identity: secondIdentity),
        ]
        let afterFolder = makeTestDirectoryNode(id: "/after/folder", name: "folder", children: afterFiles)
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterFolder])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterFolder],
            afterFolder.id: afterFiles,
        ])

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.attributedAllocatedDelta, 0)
    }

    func testUnambiguousFileIdentityMoveIsReportedAtDestination() async throws {
        let identity = FileIdentity(device: 1, inode: 900)
        let beforeFile = makeTestFileNode(
            id: "/scan/Documents/old-name.bin",
            name: "old-name.bin",
            size: 64,
            fileIdentity: identity
        )
        let beforeDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [beforeFile]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeDocuments]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeDocuments],
            beforeDocuments.id: [beforeFile],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterFile = makeTestFileNode(
            id: "/scan/Documents/new-name.bin",
            name: "new-name.bin",
            size: 64,
            fileIdentity: identity
        )
        let afterDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [afterFile]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterDocuments]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterDocuments],
            afterDocuments.id: [afterFile],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        let row = try XCTUnwrap(comparison.rows.first)
        XCTAssertEqual(row.kind, .moved)
        XCTAssertEqual(row.relativePath, "Documents/new-name.bin")
        XCTAssertEqual(row.movedFromRelativePath, "Documents/old-name.bin")
        XCTAssertEqual(row.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.addedCount, 0)
        XCTAssertEqual(comparison.summary.removedCount, 0)
        XCTAssertEqual(comparison.summary.movedCount, 1)

        XCTAssertEqual(comparison.topLevelChanges.count, 1)
        let location = try XCTUnwrap(comparison.topLevelChanges.first)
        XCTAssertEqual(location.relativePath, "Documents")
        XCTAssertEqual(location.movedCount, 1)
        XCTAssertEqual(location.representativeRelativePath, "Documents/new-name.bin")
        XCTAssertEqual(location.afterNode?.id, "/scan/Documents")

        let movedProjection = comparison.changeTree.significantProjection(changeKinds: [.moved])
        XCTAssertEqual(movedProjection.roots.map(\.relativePath), ["Documents"])
        let allActivityProjection = comparison.changeTree.significantProjection(
            changeKinds: Set(ScanComparisonChangeKind.allCases)
        )
        XCTAssertEqual(allActivityProjection.roots.map(\.relativePath), ["Documents"])
    }

    func testLegacyResourceIdentityMatchesBulkIdentityForMoveOnSameVolume() async throws {
        let volumeToken: UInt64 = 0xA11CE
        let fileID: UInt64 = 900
        let rootIdentity = resourceIdentity(fileID: 1, volumeToken: volumeToken)
        let beforeFile = makeTestFileNode(
            id: "/scan/old-name.bin",
            name: "old-name.bin",
            size: 64,
            fileIdentity: resourceIdentity(fileID: fileID, volumeToken: volumeToken)
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeFile],
            fileIdentity: rootIdentity
        )
        let beforeSnapshot = makeTestSnapshot(
            root: beforeRoot,
            store: FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeFile]])
        )

        let afterFile = makeTestFileNode(
            id: "/scan/new-name.bin",
            name: "new-name.bin",
            size: 64,
            fileIdentity: FileIdentity(device: 99, inode: fileID)
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterFile],
            fileIdentity: rootIdentity
        )
        let afterSnapshot = makeTestSnapshot(
            root: afterRoot,
            store: FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [afterFile]])
        )

        let comparison = try await ScanComparisonService().compare(
            before: beforeSnapshot,
            after: afterSnapshot
        )

        XCTAssertEqual(comparison.rows.map(\.kind), [.moved])
        XCTAssertEqual(comparison.rows.first?.movedFromRelativePath, "old-name.bin")
        XCTAssertEqual(comparison.rows.first?.relativePath, "new-name.bin")
    }

    func testAmbiguousFileIdentityDoesNotInferMove() async throws {
        let identity = FileIdentity(device: 1, inode: 901)
        let beforeFirst = makeTestFileNode(
            id: "/scan/Documents/first.bin",
            name: "first.bin",
            size: 10,
            fileIdentity: identity
        )
        let beforeSecond = makeTestFileNode(
            id: "/scan/Documents/second.bin",
            name: "second.bin",
            size: 10,
            fileIdentity: identity
        )
        let beforeDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [beforeFirst, beforeSecond]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeDocuments]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeDocuments],
            beforeDocuments.id: [beforeFirst, beforeSecond],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterFile = makeTestFileNode(
            id: "/scan/Documents/renamed.bin",
            name: "renamed.bin",
            size: 10,
            fileIdentity: identity
        )
        let afterDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [afterFile]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterDocuments]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterDocuments],
            afterDocuments.id: [afterFile],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertFalse(comparison.rows.contains { $0.kind == .moved })
        XCTAssertEqual(comparison.summary.addedCount, 1)
        XCTAssertEqual(comparison.summary.removedCount, 2)
        XCTAssertEqual(comparison.summary.movedCount, 0)
    }

    func testTopLevelChangesPartitionFinalRowsAndReportGrossSpaceChanges() async throws {
        let beforeLibraryFile = makeTestFileNode(
            id: "/scan/Library/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let beforeDownloadsFile = makeTestFileNode(
            id: "/scan/Downloads/old.bin",
            name: "old.bin",
            size: 20
        )
        let beforeLibrary = makeTestDirectoryNode(
            id: "/scan/Library",
            name: "Library",
            children: [beforeLibraryFile]
        )
        let beforeDownloads = makeTestDirectoryNode(
            id: "/scan/Downloads",
            name: "Downloads",
            children: [beforeDownloadsFile]
        )
        let beforeWork = makeTestDirectoryNode(id: "/scan/Work", name: "Work", children: [])
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeLibrary, beforeDownloads, beforeWork]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeLibrary, beforeDownloads, beforeWork],
            beforeLibrary.id: [beforeLibraryFile],
            beforeDownloads.id: [beforeDownloadsFile],
            beforeWork.id: [],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLibraryFile = makeTestFileNode(
            id: "/scan/Library/cache.bin",
            name: "cache.bin",
            size: 30
        )
        let afterWorkFile = makeTestFileNode(
            id: "/scan/Work/new.bin",
            name: "new.bin",
            size: 40
        )
        let afterLibrary = makeTestDirectoryNode(
            id: "/scan/Library",
            name: "Library",
            children: [afterLibraryFile]
        )
        let afterDownloads = makeTestDirectoryNode(id: "/scan/Downloads", name: "Downloads", children: [])
        let afterWork = makeTestDirectoryNode(
            id: "/scan/Work",
            name: "Work",
            children: [afterWorkFile]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterLibrary, afterDownloads, afterWork]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterLibrary, afterDownloads, afterWork],
            afterLibrary.id: [afterLibraryFile],
            afterDownloads.id: [],
            afterWork.id: [afterWorkFile],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.topLevelChanges.map(\.relativePath), ["Work", "Downloads", "Library"])
        XCTAssertEqual(comparison.topLevelChanges.map(\.allocatedDelta), [40, -20, 20])
        XCTAssertEqual(comparison.topLevelChanges[0].addedCount, 1)
        XCTAssertEqual(comparison.topLevelChanges[1].removedCount, 1)
        XCTAssertEqual(comparison.topLevelChanges[2].grewCount, 1)
        XCTAssertEqual(comparison.topLevelChanges.reduce(0) { $0 + $1.allocatedDelta }, 40)
        XCTAssertEqual(comparison.topLevelChanges.reduce(0) { $0 + $1.affectedCount }, 3)
        XCTAssertEqual(comparison.summary.grossIncreasedAllocatedSize, 60)
        XCTAssertEqual(comparison.summary.grossReclaimedAllocatedSize, 20)
        XCTAssertEqual(comparison.summary.attributedAllocatedDelta, 40)
        XCTAssertEqual(comparison.summary.allocatedDelta, 40)
    }

    func testWarningsSuppressUncertainAddedAndRemovedRows() async throws {
        let beforePrivateFile = makeTestFileNode(
            id: "/scan/Private/old.bin",
            name: "old.bin",
            size: 100
        )
        let beforePrivate = makeTestDirectoryNode(
            id: "/scan/Private",
            name: "Private",
            children: [beforePrivateFile]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforePrivate]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforePrivate],
            beforePrivate.id: [beforePrivateFile],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterEmptyRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let afterEmptyStore = FileTreeStore(root: afterEmptyRoot, childrenByID: [afterEmptyRoot.id: []])
        let afterWarning = ScanWarning(
            path: "/scan/Private",
            message: "Permission denied",
            category: .permissionDenied
        )
        let afterWithWarning = makeTestSnapshot(
            root: afterEmptyRoot,
            store: afterEmptyStore,
            warnings: [afterWarning]
        )

        let removalComparison = try await ScanComparisonService().compare(
            before: beforeSnapshot,
            after: afterWithWarning
        )

        XCTAssertTrue(removalComparison.rows.isEmpty)
        XCTAssertEqual(removalComparison.summary.removedCount, 0)
        XCTAssertEqual(removalComparison.summary.grossReclaimedAllocatedSize, 0)
        XCTAssertEqual(removalComparison.summary.allocatedDelta, -100)
        XCTAssertEqual(removalComparison.summary.attributedAllocatedDelta, 0)
        XCTAssertTrue(removalComparison.coverage.issues.contains(.afterWarnings(1)))

        let beforeWarning = ScanWarning(
            path: "/scan/Private",
            message: "Permission denied",
            category: .permissionDenied
        )
        let beforeEmptyRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let beforeEmptyStore = FileTreeStore(root: beforeEmptyRoot, childrenByID: [beforeEmptyRoot.id: []])
        let beforeWithWarning = makeTestSnapshot(
            root: beforeEmptyRoot,
            store: beforeEmptyStore,
            warnings: [beforeWarning]
        )

        let additionComparison = try await ScanComparisonService().compare(
            before: beforeWithWarning,
            after: beforeSnapshot
        )

        XCTAssertTrue(additionComparison.rows.isEmpty)
        XCTAssertEqual(additionComparison.summary.addedCount, 0)
        XCTAssertEqual(additionComparison.summary.grossIncreasedAllocatedSize, 0)
        XCTAssertEqual(additionComparison.summary.allocatedDelta, 100)
        XCTAssertEqual(additionComparison.summary.attributedAllocatedDelta, 0)
        XCTAssertTrue(additionComparison.coverage.issues.contains(.beforeWarnings(1)))
    }

    func testCoverageIsHighForCompleteEquivalentSnapshotsWithKnownOptions() async throws {
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let store = FileTreeStore(root: root, childrenByID: [root.id: []])
        let target = makeTestTarget("/scan")
        let options = ScanOptions()
        let before = ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            scanOptions: options
        )
        let after = ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            scanOptions: options
        )

        let comparison = try await ScanComparisonService().compare(before: before, after: after)

        XCTAssertEqual(comparison.coverage.confidence, .high)
        XCTAssertTrue(comparison.coverage.issues.isEmpty)
        XCTAssertTrue(comparison.coverage.targetsMatch)
        XCTAssertEqual(comparison.coverage.scanOptionsMatch, true)
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
            changeKinds: [.added],
            searchText: "application support",
            sortOrder: []
        )

        let result = query.applying(to: rows)

        XCTAssertEqual(result.map(\.relativePath), ["Library/Application Support/cache.bin"])
    }

    func testRowQueryFiltersExactLocationPrefix() {
        let libraryNode = makeTestFileNode(
            id: "/after/Library/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let librarySupportNode = makeTestFileNode(
            id: "/after/Library Support/cache.bin",
            name: "cache.bin",
            size: 20
        )
        let rows = [
            ScanComparisonRow(
                relativePath: "Library/cache.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: libraryNode
            ),
            ScanComparisonRow(
                relativePath: "Library Support/cache.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: librarySupportNode
            ),
        ]
        let query = ScanComparisonRowQuery(
            searchText: "",
            sortOrder: [],
            pathPrefix: "Library"
        )

        XCTAssertEqual(query.applying(to: rows).map(\.relativePath), ["Library/cache.bin"])
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

    func testChangeTreeRollsEvidenceIntoEveryAncestorWithoutHidingChurn() async throws {
        let beforeCache = makeTestFileNode(
            id: "/scan/Users/colin/Library/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let beforeOld = makeTestFileNode(
            id: "/scan/Users/colin/Downloads/old.bin",
            name: "old.bin",
            size: 60
        )
        let beforeApp = makeTestFileNode(
            id: "/scan/Applications/app.bin",
            name: "app.bin",
            size: 10
        )
        let beforeLibrary = makeTestDirectoryNode(
            id: "/scan/Users/colin/Library",
            name: "Library",
            children: [beforeCache]
        )
        let beforeDownloads = makeTestDirectoryNode(
            id: "/scan/Users/colin/Downloads",
            name: "Downloads",
            children: [beforeOld]
        )
        let beforeColin = makeTestDirectoryNode(
            id: "/scan/Users/colin",
            name: "colin",
            children: [beforeLibrary, beforeDownloads]
        )
        let beforeUsers = makeTestDirectoryNode(
            id: "/scan/Users",
            name: "Users",
            children: [beforeColin]
        )
        let beforeApplications = makeTestDirectoryNode(
            id: "/scan/Applications",
            name: "Applications",
            children: [beforeApp]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeUsers, beforeApplications]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeUsers, beforeApplications],
            beforeUsers.id: [beforeColin],
            beforeColin.id: [beforeLibrary, beforeDownloads],
            beforeLibrary.id: [beforeCache],
            beforeDownloads.id: [beforeOld],
            beforeApplications.id: [beforeApp],
        ])

        let afterCache = makeTestFileNode(
            id: "/scan/Users/colin/Library/cache.bin",
            name: "cache.bin",
            size: 110
        )
        let afterApp = makeTestFileNode(
            id: "/scan/Applications/app.bin",
            name: "app.bin",
            size: 50
        )
        let afterLibrary = makeTestDirectoryNode(
            id: "/scan/Users/colin/Library",
            name: "Library",
            children: [afterCache]
        )
        let afterDownloads = makeTestDirectoryNode(
            id: "/scan/Users/colin/Downloads",
            name: "Downloads",
            children: []
        )
        let afterColin = makeTestDirectoryNode(
            id: "/scan/Users/colin",
            name: "colin",
            children: [afterLibrary, afterDownloads]
        )
        let afterUsers = makeTestDirectoryNode(
            id: "/scan/Users",
            name: "Users",
            children: [afterColin]
        )
        let afterApplications = makeTestDirectoryNode(
            id: "/scan/Applications",
            name: "Applications",
            children: [afterApp]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterUsers, afterApplications]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterUsers, afterApplications],
            afterUsers.id: [afterColin],
            afterColin.id: [afterLibrary, afterDownloads],
            afterLibrary.id: [afterCache],
            afterDownloads.id: [],
            afterApplications.id: [afterApp],
        ])

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        let users = try XCTUnwrap(comparison.changeTree.node(at: "Users"))
        XCTAssertEqual(users.increasedAllocatedSize, 100)
        XCTAssertEqual(users.reclaimedAllocatedSize, 60)
        XCTAssertEqual(users.allocatedDelta, 40)
        XCTAssertEqual(users.affectedCount, 2)
        XCTAssertEqual(users.childPaths, ["Users/colin"])

        let colin = try XCTUnwrap(comparison.changeTree.node(at: "Users/colin"))
        XCTAssertEqual(colin.increasedAllocatedSize, 100)
        XCTAssertEqual(colin.reclaimedAllocatedSize, 60)
        XCTAssertEqual(colin.childPaths, ["Users/colin/Library", "Users/colin/Downloads"])
        XCTAssertEqual(comparison.changeTree.rootPaths, ["Users", "Applications"])
        XCTAssertEqual(comparison.topLevelChanges.map(\.relativePath), ["Users", "Applications"])
        XCTAssertEqual(comparison.topLevelChanges.first?.increasedAllocatedSize, 100)
        XCTAssertEqual(comparison.topLevelChanges.first?.reclaimedAllocatedSize, 60)
        XCTAssertEqual(
            comparison.changeTree.rootPaths.compactMap(comparison.changeTree.node).reduce(0) {
                $0 + $1.increasedAllocatedSize
            },
            comparison.summary.grossIncreasedAllocatedSize
        )
        XCTAssertEqual(
            comparison.changeTree.rootPaths.compactMap(comparison.changeTree.node).reduce(0) {
                $0 + $1.reclaimedAllocatedSize
            },
            comparison.summary.grossReclaimedAllocatedSize
        )
    }

    func testSignificantProjectionCoversGrowthAndReclamationIndependently() async throws {
        let beforeNodes = [
            makeTestFileNode(id: "/scan/growth.bin", name: "growth.bin", size: 0),
            makeTestFileNode(id: "/scan/reclaimed.bin", name: "reclaimed.bin", size: 5),
            makeTestFileNode(id: "/scan/tail.bin", name: "tail.bin", size: 0),
        ]
        let beforeRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: beforeNodes)
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: beforeNodes])
        let afterNodes = [
            makeTestFileNode(id: "/scan/growth.bin", name: "growth.bin", size: 95),
            makeTestFileNode(id: "/scan/reclaimed.bin", name: "reclaimed.bin", size: 0),
            makeTestFileNode(id: "/scan/tail.bin", name: "tail.bin", size: 5),
        ]
        let afterRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: afterNodes)
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: afterNodes])
        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        let projection = comparison.changeTree.significantProjection(
            changeKinds: Set(ScanComparisonChangeKind.allCases),
            coverageTarget: 0.95
        )

        XCTAssertEqual(projection.namedRootCount, 2)
        XCTAssertEqual(projection.hiddenRootCount, 1)
        XCTAssertTrue(projection.roots.contains { $0.relativePath == "growth.bin" })
        XCTAssertTrue(projection.roots.contains { $0.relativePath == "reclaimed.bin" })
        XCTAssertTrue(projection.roots.contains(where: \.isRemainder))
    }

    func testSignificantProjectionHonorsExactChangeKindSelection() async throws {
        let grewBefore = makeTestFileNode(id: "/scan/grew.bin", name: "grew.bin", size: 10)
        let beforeRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [grewBefore])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [grewBefore]])

        let grewAfter = makeTestFileNode(id: "/scan/grew.bin", name: "grew.bin", size: 20)
        let added = makeTestFileNode(id: "/scan/added.bin", name: "added.bin", size: 50)
        let afterRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [grewAfter, added])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [grewAfter, added],
        ])
        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        let addedProjection = comparison.changeTree.significantProjection(changeKinds: [.added])
        let grewProjection = comparison.changeTree.significantProjection(changeKinds: [.grew])
        let combinedProjection = comparison.changeTree.significantProjection(changeKinds: [.added, .grew])

        XCTAssertEqual(addedProjection.roots.map(\.relativePath), ["added.bin"])
        XCTAssertEqual(addedProjection.roots.first?.increasedAllocatedSize, 50)
        XCTAssertEqual(grewProjection.roots.map(\.relativePath), ["grew.bin"])
        XCTAssertEqual(grewProjection.roots.first?.increasedAllocatedSize, 10)
        XCTAssertEqual(Set(combinedProjection.roots.map(\.relativePath)), ["added.bin", "grew.bin"])
    }

    func testComparisonClampsAggregateStorageOverflow() async throws {
        let beforeRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let beforeStore = FileTreeStore(root: beforeRoot)
        let first = makeTestFileNode(
            id: "/scan/first.bin",
            name: "first.bin",
            size: .max
        )
        let second = makeTestFileNode(
            id: "/scan/second.bin",
            name: "second.bin",
            size: .max
        )
        let afterRoot = FileNodeRecord(
            id: "/scan",
            url: URL(filePath: "/scan", directoryHint: .isDirectory),
            name: "scan",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: .max,
            logicalSize: .max,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let afterStore = FileTreeStore(
            root: afterRoot,
            childrenByID: [afterRoot.id: [first, second]]
        )

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )
        let projection = comparison.changeTree.significantProjection(changeKinds: [.added])

        XCTAssertEqual(comparison.rows.count, 2)
        XCTAssertEqual(comparison.summary.grossIncreasedAllocatedSize, Int64.max)
        XCTAssertEqual(projection.totalImpact, Int64.max)
        XCTAssertEqual(projection.representedImpact, Int64.max)
    }

    func testTopLevelChangesClampLargeReclamationUnderOnePath() async throws {
        let first = makeTestFileNode(id: "/scan/folder/first.bin", name: "first.bin", size: .max)
        let second = makeTestFileNode(id: "/scan/folder/second.bin", name: "second.bin", size: .max)
        let beforeFolder = FileNodeRecord(
            id: "/scan/folder",
            url: URL(filePath: "/scan/folder", directoryHint: .isDirectory),
            name: "folder",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: .max,
            logicalSize: .max,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let beforeRoot = FileNodeRecord(
            id: "/scan",
            url: URL(filePath: "/scan", directoryHint: .isDirectory),
            name: "scan",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: .max,
            logicalSize: .max,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeFolder],
            beforeFolder.id: [first, second],
        ])
        let afterFolder = makeTestDirectoryNode(id: "/scan/folder", name: "folder", children: [])
        let afterRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [afterFolder])
        let afterStore = FileTreeStore(
            root: afterRoot,
            childrenByID: [afterRoot.id: [afterFolder]]
        )

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )
        let location = try XCTUnwrap(comparison.topLevelChanges.first)

        XCTAssertEqual(comparison.rows.count, 2)
        XCTAssertEqual(location.relativePath, "folder")
        XCTAssertEqual(location.allocatedDelta, -Int64.max)
        XCTAssertEqual(location.absoluteAllocatedDelta, Int64.max)
        XCTAssertEqual(location.reclaimedAllocatedSize, Int64.max)
    }

    func testRowQueryCombinesSelectedChangeKinds() {
        let movedBefore = makeTestFileNode(id: "/before/old.bin", name: "old.bin", size: 100)
        let movedAfter = makeTestFileNode(id: "/after/new.bin", name: "new.bin", size: 150)
        let movedAndGrew = ScanComparisonRow(
            relativePath: "new.bin",
            kind: .moved,
            beforeNode: movedBefore,
            afterNode: movedAfter,
            movedFromRelativePath: "old.bin"
        )
        let removed = ScanComparisonRow(
            relativePath: "removed.bin",
            kind: .removed,
            beforeNode: makeTestFileNode(id: "/before/removed.bin", name: "removed.bin", size: 40),
            afterNode: nil
        )
        let rows = [movedAndGrew, removed]

        let movedAndRemoved = ScanComparisonRowQuery(
            changeKinds: [.moved, .removed],
            searchText: "",
            sortOrder: []
        ).applying(to: rows)
        let removedOnly = ScanComparisonRowQuery(
            changeKinds: [.removed],
            searchText: "",
            sortOrder: []
        ).applying(to: rows)
        let movedOnly = ScanComparisonRowQuery(
            changeKinds: [.moved],
            searchText: "",
            sortOrder: []
        ).applying(to: rows)

        XCTAssertEqual(movedAndRemoved.map(\.relativePath), ["new.bin", "removed.bin"])
        XCTAssertEqual(removedOnly.map(\.relativePath), ["removed.bin"])
        XCTAssertEqual(movedOnly.map(\.relativePath), ["new.bin"])
    }

    private func resourceIdentity(fileID: UInt64, volumeToken: UInt64) -> FileIdentity {
        var data = Data()
        var littleEndianFileID = fileID.littleEndian
        var littleEndianVolumeToken = volumeToken.littleEndian
        withUnsafeBytes(of: &littleEndianFileID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &littleEndianVolumeToken) { data.append(contentsOf: $0) }
        return FileIdentity(resourceIdentifier: data)
    }
}
