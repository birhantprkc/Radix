import XCTest
@testable import RadixCore

final class IncrementalRescanPlannerTests: XCTestCase {
    func testInjectedHistoryProviderFeedsPlannerWithinExplicitCutoff() async throws {
        let fixture = makeFixture()
        let since = ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 10)
        let through = ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 30)
        let provider = FakeFileSystemEventHistoryProvider(
            checkpoint: through,
            history: FileSystemEventHistory(
                since: since,
                through: through,
                events: [
                    FileSystemEventRecord(
                        path: "/scan/folder/new.txt",
                        eventID: 20,
                        flags: [.itemCreated, .itemIsFile]
                    ),
                ]
            )
        )

        let cutoff = try provider.currentCheckpoint(
            for: URL(filePath: "/scan", directoryHint: .isDirectory)
        )
        let eventHistory = try await provider.history(
            for: URL(filePath: "/scan", directoryHint: .isDirectory),
            since: since,
            through: cutoff
        )
        let plan = IncrementalRescanPlanner().plan(
            history: eventHistory,
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(cutoff, through)
        XCTAssertEqual(plan, .update(
            relistDirectoryIDs: [fixture.folder.id],
            rescanSubtreeIDs: []
        ))
    }

    func testFileEventRelistsContainingDirectory() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder/new.txt", flags: [.itemCreated, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(plan, .update(
            relistDirectoryIDs: [fixture.folder.id],
            rescanSubtreeIDs: []
        ))
    }

    func testRootLevelFileEventRelistsScanRoot() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/new.txt", flags: [.itemCreated, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(plan, .update(
            relistDirectoryIDs: [fixture.store.rootID],
            rescanSubtreeIDs: []
        ))
    }

    func testDisjointRelistAndSubtreeRescanShareOnePlan() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder/new.txt", flags: [.itemCreated, .itemIsFile]),
                event(
                    "/scan/Tool.app/Contents/MacOS/Tool",
                    flags: [.itemModified, .itemIsFile]
                ),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(plan, .update(
            relistDirectoryIDs: [fixture.folder.id],
            rescanSubtreeIDs: [fixture.package.id]
        ))
    }

    func testAncestorRelistWithNestedUpdateFallsBackAtScanRoot() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/new.txt", flags: [.itemCreated, .itemIsFile]),
                event("/scan/folder/new.txt", flags: [.itemCreated, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(plan, .fullScan(reason: .changedScanRoot))
    }

    func testBroadRelistPlanFallsBackToFullScan() {
        let directories = (0..<32).map { index in
            directory("/scan/directory-\(index)", children: [])
        }
        let root = directory("/scan", children: directories)
        let store = FileTreeStore(root: root, childrenByID: [root.id: directories])
        let events = directories.map { directory in
            event(
                directory.id + "/new.txt",
                flags: [.itemCreated, .itemIsFile]
            )
        }
        let plan = IncrementalRescanPlanner().plan(
            history: history(events),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: store
        )

        XCTAssertEqual(plan, .fullScan(reason: .incrementalWorkTooBroad))
    }

    func testNestedEventsCoalesceToTopLevelChangedSubtree() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder", flags: [.mustScanSubdirectories, .itemIsDirectory]),
                event("/scan/folder/nested/payload.bin", flags: [.itemModified, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(plan, .update(
            relistDirectoryIDs: [],
            rescanSubtreeIDs: [fixture.folder.id]
        ))
    }

    func testManyDisjointEventsRemainIndependentRelistsBelowBroadWorkThreshold() {
        let directories = (0..<128).map { index in
            directory("/scan/directory-\(index)", children: [])
        }
        let paddingFiles = (0..<512).map { index in
            file("/scan/padding-\(index).dat")
        }
        let rootChildren = directories + paddingFiles
        let root = directory("/scan", children: rootChildren)
        let store = FileTreeStore(root: root, childrenByID: [root.id: rootChildren])
        let events = directories.map { directory in
            event(directory.id + "/new.txt", flags: [.itemCreated, .itemIsFile])
        }

        let plan = IncrementalRescanPlanner().plan(
            history: history(events),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: store
        )

        XCTAssertEqual(plan, .update(
            relistDirectoryIDs: directories.map(\.id),
            rescanSubtreeIDs: []
        ))
    }

    func testDroppedRootAndMountEventsRequireFullScan() {
        let fixture = makeFixture()
        let target = ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory))
        let cases: [(FileSystemEventFlags, IncrementalRescanFallbackReason)] = [
            (.userDropped, .userDroppedEvents),
            (.kernelDropped, .kernelDroppedEvents),
            (.eventIDsWrapped, .eventIDsWrapped),
            (.rootChanged, .watchedRootChanged),
            (.volumeMounted, .nestedVolumeChanged),
            (.itemCloned, .cloneTopologyChanged),
        ]

        for (flags, expectedReason) in cases {
            let plan = IncrementalRescanPlanner().plan(
                history: history([event("/scan/folder", flags: flags)]),
                target: target,
                treeStore: fixture.store
            )
            XCTAssertEqual(plan, .fullScan(reason: expectedReason))
        }
    }

    func testEventInsidePackageUsesMaterializedPackageLeaf() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/Tool.app/Contents/MacOS/Tool", flags: [.itemModified, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(plan, .update(
            relistDirectoryIDs: [],
            rescanSubtreeIDs: [fixture.package.id]
        ))
    }

    func testEventInsideAutoSummaryFallsBackToFullScan() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/cache/shard/payload", flags: [.itemModified, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        XCTAssertEqual(plan, .fullScan(reason: .autoSummarizedBoundary))
    }

    func testExcludedKnownEventDoesNotTriggerRescan() {
        let fixture = makeFixture()
        let matcher = ScanExclusionMatcher(
            patterns: ["*.log"],
            rootPath: "/scan"
        )
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder/debug.log", flags: [.itemModified, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store,
            exclusionMatcher: matcher
        )

        XCTAssertEqual(plan, .noChanges)
    }

    private func history(_ events: [FileSystemEventRecord]) -> FileSystemEventHistory {
        FileSystemEventHistory(
            since: ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 10),
            through: ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 100),
            events: events
        )
    }

    private func event(
        _ path: String,
        flags: FileSystemEventFlags
    ) -> FileSystemEventRecord {
        FileSystemEventRecord(path: path, eventID: 20, flags: flags)
    }

    private func makeFixture() -> (
        store: FileTreeStore,
        folder: FileNodeRecord,
        package: FileNodeRecord,
        autoSummary: FileNodeRecord
    ) {
        let payload = file("/scan/folder/nested/payload.bin")
        let nested = directory("/scan/folder/nested", children: [payload])
        let folder = directory("/scan/folder", children: [nested])
        let package = FileNodeRecord(
            id: "/scan/Tool.app",
            url: URL(filePath: "/scan/Tool.app", directoryHint: .isDirectory),
            name: "Tool.app",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 10,
            logicalSize: 10,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: true,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let autoSummary = FileNodeRecord(
            id: "/scan/cache",
            url: URL(filePath: "/scan/cache", directoryHint: .isDirectory),
            name: "cache",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 20,
            logicalSize: 20,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let root = directory("/scan", children: [folder, package, autoSummary])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, package, autoSummary],
            folder.id: [nested],
            nested.id: [payload],
        ])
        return (store, folder, package, autoSummary)
    }

    private func directory(_ path: String, children: [FileNodeRecord]) -> FileNodeRecord {
        FileNodeRecord.directory(
            id: path,
            url: URL(filePath: path, directoryHint: .isDirectory),
            name: URL(filePath: path).lastPathComponent,
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
    }

    private func file(_ path: String) -> FileNodeRecord {
        FileNodeRecord(
            id: path,
            url: URL(filePath: path),
            name: URL(filePath: path).lastPathComponent,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}

private nonisolated struct FakeFileSystemEventHistoryProvider: FileSystemEventHistoryProviding {
    let checkpoint: ScanIncrementalCheckpoint
    let storedHistory: FileSystemEventHistory

    init(checkpoint: ScanIncrementalCheckpoint, history: FileSystemEventHistory) {
        self.checkpoint = checkpoint
        self.storedHistory = history
    }

    func currentCheckpoint(for targetURL: URL) throws -> ScanIncrementalCheckpoint {
        _ = targetURL
        return checkpoint
    }

    func history(
        for targetURL: URL,
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint
    ) async throws -> FileSystemEventHistory {
        _ = targetURL
        XCTAssertEqual(since, storedHistory.since)
        XCTAssertEqual(through, storedHistory.through)
        return storedHistory
    }
}
