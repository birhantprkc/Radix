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
