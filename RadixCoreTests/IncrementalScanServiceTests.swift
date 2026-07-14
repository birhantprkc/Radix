import Foundation
import XCTest
@testable import RadixCore

final class IncrementalScanServiceTests: XCTestCase {
    func testFullScanCapturesCheckpointAndIncrementalRescanSplicesChangedSubtree() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        let untouchedURL = rootURL.appending(path: "Untouched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untouchedURL, withIntermediateDirectories: true)
        try Data([0x1]).write(to: changedURL.appending(path: "before.dat"))
        try Data([0x2]).write(to: untouchedURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: changedURL.appending(path: "after.dat").path,
                    eventID: 15,
                    flags: [.itemCreated, .itemIsFile]
                )
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )
        XCTAssertEqual(baseline.incrementalCheckpoint?.eventID, 10)

        let untouchedBefore = try XCTUnwrap(baseline.treeStore.node(id: untouchedURL.path))
        try Data([0x3]).write(to: changedURL.appending(path: "after.dat"))
        let rescanned = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )

        XCTAssertEqual(rescanned.incrementalCheckpoint?.eventID, 20)
        XCTAssertEqual(rescanned.root.descendantFileCount, 3)
        XCTAssertEqual(rescanned.treeStore.node(id: changedURL.path)?.descendantFileCount, 2)
        XCTAssertEqual(rescanned.treeStore.node(id: untouchedURL.path), untouchedBefore)
        XCTAssertEqual(provider.historyRequestCount, 1)
    }

    func testIncrementalRescanMatchesFullScanForHardLinksAcrossSubtrees() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let ownerDirectoryURL = rootURL.appending(path: "A-Owner", directoryHint: .isDirectory)
        let changedDirectoryURL = rootURL.appending(path: "Z-Changed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ownerDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: changedDirectoryURL, withIntermediateDirectories: true)

        let ownerURL = ownerDirectoryURL.appending(path: "shared.dat")
        let changedLinkURL = changedDirectoryURL.appending(path: "shared.dat")
        try Data(repeating: 0x5A, count: 16_384).write(to: ownerURL)
        try FileManager.default.linkItem(at: ownerURL, to: changedLinkURL)

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: changedDirectoryURL.appending(path: "new.dat").path,
                    eventID: 15,
                    flags: [.itemCreated, .itemIsFile]
                )
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        try Data([0x1]).write(to: changedDirectoryURL.appending(path: "new.dat"))
        let incremental = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        XCTAssertEqual(
            incremental.aggregateStats.totalAllocatedSize,
            full.aggregateStats.totalAllocatedSize
        )
        XCTAssertEqual(incremental.aggregateStats.totalLogicalSize, full.aggregateStats.totalLogicalSize)
        XCTAssertEqual(incremental.aggregateStats.fileCount, full.aggregateStats.fileCount)
        XCTAssertEqual(incremental.aggregateStats.directoryCount, full.aggregateStats.directoryCount)
        XCTAssertEqual(incremental.treeStore.indexedNodeIDs(), full.treeStore.indexedNodeIDs())
        for nodeID in full.treeStore.indexedNodeIDs() {
            let incrementalNode = try XCTUnwrap(incremental.treeStore.node(id: nodeID))
            let fullNode = try XCTUnwrap(full.treeStore.node(id: nodeID))
            XCTAssertEqual(incrementalNode.name, fullNode.name, nodeID)
            XCTAssertEqual(incrementalNode.isDirectory, fullNode.isDirectory, nodeID)
            XCTAssertEqual(incrementalNode.isSymbolicLink, fullNode.isSymbolicLink, nodeID)
            XCTAssertEqual(incrementalNode.allocatedSize, fullNode.allocatedSize, nodeID)
            XCTAssertEqual(
                incrementalNode.unduplicatedAllocatedSize,
                fullNode.unduplicatedAllocatedSize,
                nodeID
            )
            XCTAssertEqual(incrementalNode.logicalSize, fullNode.logicalSize, nodeID)
            XCTAssertEqual(incrementalNode.descendantFileCount, fullNode.descendantFileCount, nodeID)
            XCTAssertEqual(incrementalNode.fileIdentity, fullNode.fileIdentity, nodeID)
            XCTAssertEqual(incrementalNode.linkCount, fullNode.linkCount, nodeID)
            XCTAssertEqual(incrementalNode.isPackage, fullNode.isPackage, nodeID)
            XCTAssertEqual(incrementalNode.isAccessible, fullNode.isAccessible, nodeID)
            XCTAssertEqual(incrementalNode.isSelfAccessible, fullNode.isSelfAccessible, nodeID)
            XCTAssertEqual(incrementalNode.isSynthetic, fullNode.isSynthetic, nodeID)
            XCTAssertEqual(incrementalNode.isAutoSummarized, fullNode.isAutoSummarized, nodeID)
        }
        XCTAssertEqual(incremental.treeStore.childIDsByID, full.treeStore.childIDsByID)
    }

    func testNoChangeRescanAdvancesCheckpointWithoutChangingTree() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(30), checkpoint(40)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: ScanOptions())
        )
        let rescanned = try await finishedIncrementalSnapshot(
            from: service.rescan(
                target: target,
                options: ScanOptions(),
                from: baseline
            )
        )

        XCTAssertEqual(rescanned.incrementalCheckpoint?.eventID, 40)
        XCTAssertEqual(rescanned.treeStore.contentID, baseline.treeStore.contentID)
        XCTAssertNotEqual(rescanned.id, baseline.id)
    }

    func testSubtreeDisappearingAfterHistoryPlanningFallsBackToFullScan() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: true)
        try Data([0x1]).write(to: changedURL.appending(path: "payload.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: [
                FileSystemEventRecord(
                    path: changedURL.path,
                    eventID: 15,
                    flags: [.itemModified, .itemIsDirectory]
                )
            ],
            beforeReturningHistory: {
                try FileManager.default.removeItem(at: changedURL)
            }
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        let rescanned = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )

        XCTAssertNil(rescanned.treeStore.node(id: changedURL.path))
        XCTAssertEqual(rescanned.incrementalCheckpoint?.eventID, 30)
        XCTAssertEqual(provider.historyRequestCount, 1)
    }

    private func checkpoint(_ eventID: UInt64) -> ScanIncrementalCheckpoint {
        ScanIncrementalCheckpoint(volumeUUID: "test-volume", eventID: eventID)
    }
}

private final class IncrementalHistoryStub: FileSystemEventHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints: [ScanIncrementalCheckpoint]
    private let events: [FileSystemEventRecord]
    private let beforeReturningHistory: @Sendable () throws -> Void
    private var historyRequests = 0

    init(
        checkpoints: [ScanIncrementalCheckpoint],
        events: [FileSystemEventRecord],
        beforeReturningHistory: @escaping @Sendable () throws -> Void = {}
    ) {
        self.checkpoints = checkpoints
        self.events = events
        self.beforeReturningHistory = beforeReturningHistory
    }

    var historyRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return historyRequests
    }

    func currentCheckpoint(for targetURL: URL) throws -> ScanIncrementalCheckpoint {
        _ = targetURL
        lock.lock()
        defer { lock.unlock() }
        guard !checkpoints.isEmpty else {
            throw FileSystemEventHistoryError.eventIDUnavailable(targetURL.path)
        }
        return checkpoints.removeFirst()
    }

    func history(
        for targetURL: URL,
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint
    ) async throws -> FileSystemEventHistory {
        _ = targetURL
        lock.withLock {
            historyRequests += 1
        }
        try beforeReturningHistory()
        return FileSystemEventHistory(since: since, through: through, events: events)
    }
}

private func makeIncrementalTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "radix-incremental-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func finishedIncrementalSnapshot(
    from stream: AsyncThrowingStream<ScanProgressEvent, Error>
) async throws -> ScanSnapshot {
    for try await event in stream {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }
    XCTFail("Expected a finished incremental scan snapshot")
    throw CancellationError()
}
