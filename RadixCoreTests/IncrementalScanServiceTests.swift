import Foundation
import XCTest
@testable import RadixCore

final class IncrementalScanServiceTests: XCTestCase {
    func testRootShallowRelistAppliesMixedMembershipChanges() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let modifiedURL = rootURL.appending(path: "modified.dat")
        let removedURL = rootURL.appending(path: "removed.dat")
        let createdURL = rootURL.appending(path: "created.dat")
        let createdDirectoryURL = rootURL.appending(
            path: "Created",
            directoryHint: .isDirectory
        )
        try Data([0x1]).write(to: modifiedURL)
        try Data([0x2]).write(to: removedURL)

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: modifiedURL.path,
                    eventID: 14,
                    flags: [.itemModified, .itemIsFile]
                ),
                FileSystemEventRecord(
                    path: removedURL.path,
                    eventID: 15,
                    flags: [.itemRemoved, .itemIsFile]
                ),
                FileSystemEventRecord(
                    path: createdURL.path,
                    eventID: 16,
                    flags: [.itemCreated, .itemIsFile]
                ),
                FileSystemEventRecord(
                    path: createdDirectoryURL.path,
                    eventID: 17,
                    flags: [.itemCreated, .itemIsDirectory]
                ),
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        try Data(repeating: 0x3, count: 8_192).write(to: modifiedURL)
        try FileManager.default.removeItem(at: removedURL)
        try Data([0x4]).write(to: createdURL)
        try FileManager.default.createDirectory(
            at: createdDirectoryURL,
            withIntermediateDirectories: false
        )
        try Data([0x5]).write(to: createdDirectoryURL.appending(path: "nested.dat"))

        let incremental = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        try assertEquivalent(incremental, full)
        XCTAssertEqual(incremental.incrementalCheckpoint?.eventID, 20)
    }

    func testBatchedShallowRelistsMatchFullScanAcrossDirectories() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let directoryURLs = (0..<3).map { index in
            rootURL.appending(path: "Directory-\(index)", directoryHint: .isDirectory)
        }
        for directoryURL in directoryURLs {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            try Data([0x1]).write(to: directoryURL.appending(path: "existing.dat"))
        }
        let changedURLs = directoryURLs.map { $0.appending(path: "changed.dat") }
        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: changedURLs.enumerated().map { index, url in
                FileSystemEventRecord(
                    path: url.path,
                    eventID: UInt64(14 + index),
                    flags: [.itemCreated, .itemIsFile]
                )
            }
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        for changedURL in changedURLs {
            try Data(repeating: 0x6, count: 4_096).write(to: changedURL)
        }
        let incremental = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        try assertEquivalent(incremental, full)
        XCTAssertEqual(incremental.incrementalCheckpoint?.eventID, 20)
    }

    func testShallowRelistPreservesAutoSummaryThresholdSemantics() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let parentURL = rootURL.appending(path: "Parent", directoryHint: .isDirectory)
        let candidateURL = parentURL.appending(path: "Candidate", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        try Data([0x1]).write(to: candidateURL.appending(path: "before.dat"))
        let createdURL = candidateURL.appending(path: "after.dat")

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: createdURL.path,
                    eventID: 15,
                    flags: [.itemCreated, .itemIsFile]
                ),
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 2
        options.autoSummarizeMaxAverageFileSize = 1_000_000
        options.autoSummarizeMinDepthForSummarization = 2
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )
        XCTAssertEqual(baseline.treeStore.node(id: candidateURL.path)?.isAutoSummarized, false)

        try Data([0x2]).write(to: createdURL)
        let incremental = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        try assertEquivalent(incremental, full)
        XCTAssertEqual(incremental.treeStore.node(id: candidateURL.path)?.isAutoSummarized, true)
        XCTAssertEqual(incremental.incrementalCheckpoint?.eventID, 20)
    }

    func testFullScanCapturesCheckpointAndIncrementalRescanRelistsChangedDirectory() async throws {
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

        try assertEquivalent(incremental, full)
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

    private func assertEquivalent(
        _ incremental: ScanSnapshot,
        _ full: ScanSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            incremental.treeStore.indexedNodeIDs(),
            full.treeStore.indexedNodeIDs(),
            file: file,
            line: line
        )
        for nodeID in full.treeStore.indexedNodeIDs() {
            XCTAssertEqual(
                try XCTUnwrap(incremental.treeStore.node(id: nodeID)),
                try XCTUnwrap(full.treeStore.node(id: nodeID)),
                nodeID,
                file: file,
                line: line
            )
            XCTAssertEqual(
                incremental.treeStore.childIDs(of: nodeID),
                full.treeStore.childIDs(of: nodeID),
                nodeID,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            incremental.aggregateStats.fileCount,
            full.aggregateStats.fileCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            incremental.aggregateStats.directoryCount,
            full.aggregateStats.directoryCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            incremental.aggregateStats.accessibleItemCount,
            full.aggregateStats.accessibleItemCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            incremental.aggregateStats.inaccessibleItemCount,
            full.aggregateStats.inaccessibleItemCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            incremental.scanWarnings.map { "\($0.category.rawValue)|\($0.path)|\($0.message)" }.sorted(),
            full.scanWarnings.map { "\($0.category.rawValue)|\($0.path)|\($0.message)" }.sorted(),
            file: file,
            line: line
        )
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
