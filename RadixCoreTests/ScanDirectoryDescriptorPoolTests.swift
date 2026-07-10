import Darwin
import XCTest
@testable import RadixCore

final class ScanDirectoryDescriptorPoolTests: XCTestCase {
    func testOpenChildRefusesDirectoryReplacedBySymlink() throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        let pool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 4)
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        try FileManager.default.removeItem(at: childURL)
        try FileManager.default.createSymbolicLink(at: childURL, withDestinationURL: outsideURL)
        let name = try XCTUnwrap(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8)))

        XCTAssertThrowsError(try pool.openChild(named: name, at: childURL, relativeTo: rootLease)) { error in
            let code = (error as NSError).code
            XCTAssertTrue(code == Int(ELOOP) || code == Int(ENOTDIR), "Unexpected error: \(error)")
        }
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 1)
        rootLease.close()
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 0)
    }

    func testOpenChildRejectsIdentityChangedAfterEnumeration() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        let pool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 4)
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let name = try XCTUnwrap(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8)))

        XCTAssertThrowsError(try pool.openChild(
            named: name,
            at: childURL,
            relativeTo: rootLease,
            expectedIdentity: FileIdentity(device: 0, inode: 0)
        )) { error in
            XCTAssertEqual((error as NSError).code, Int(ESTALE))
        }
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 1)
        rootLease.close()
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 0)
    }

    func testEMFILEEvictsAnotherLeaseAndRetriesOnce() throws {
        let tracker = RetryingDescriptorTracker()
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 4,
            systemCalls: tracker.systemCalls
        )
        let rootURL = URL(filePath: "/virtual/root", directoryHint: .isDirectory)
        let childName = try XCTUnwrap(
            BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8))
        )
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let disposableLease = try lease(from: pool.openChild(
            named: childName,
            at: rootURL.appending(path: "Disposable", directoryHint: .isDirectory),
            relativeTo: rootLease
        ))
        tracker.failNextChildOpenWithEMFILE()

        let retriedLease = try lease(from: pool.openChild(
            named: childName,
            at: rootURL.appending(path: "Retried", directoryHint: .isDirectory),
            relativeTo: rootLease
        ))

        XCTAssertFalse(disposableLease.isOpen)
        XCTAssertTrue(retriedLease.isOpen)
        XCTAssertEqual(pool.debugCounters.retryCount, 1)
        XCTAssertEqual(pool.debugCounters.fallbackCount, 0)
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 2)
        retriedLease.close()
        rootLease.close()
        XCTAssertEqual(tracker.openDescriptorCount, 0)
    }

    func testLowBudgetFallsBackWithoutExceedingPeakAndRecoversAfterClose() throws {
        let tracker = DescriptorTracker()
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 2,
            systemCalls: tracker.systemCalls
        )
        let rootURL = URL(filePath: "/virtual/root", directoryHint: .isDirectory)
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        let childName = try XCTUnwrap(
            BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8))
        )
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let firstChildLease = try lease(from: pool.openChild(
            named: childName,
            at: childURL,
            relativeTo: rootLease
        ))

        guard case .fallback = try pool.openChild(
            named: childName,
            at: childURL,
            relativeTo: rootLease
        ) else {
            return XCTFail("Expected descriptor-budget fallback")
        }
        XCTAssertEqual(pool.debugCounters.peakOpenDescriptorCount, 2)
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 2)
        XCTAssertEqual(pool.debugCounters.fallbackCount, 1)

        firstChildLease.close()
        let replacementLease = try lease(from: pool.openChild(
            named: childName,
            at: childURL,
            relativeTo: rootLease
        ))
        XCTAssertEqual(pool.debugCounters.peakOpenDescriptorCount, 2)
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 2)

        replacementLease.close()
        rootLease.close()
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 0)
        XCTAssertEqual(tracker.openDescriptorCount, 0)
    }

    func testCancellationClosesEveryActiveLeaseAndRejectsNewOpens() throws {
        let tracker = DescriptorTracker()
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 4,
            systemCalls: tracker.systemCalls
        )
        let rootURL = URL(filePath: "/virtual/root", directoryHint: .isDirectory)
        let childName = try XCTUnwrap(
            BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8))
        )
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let childLease = try lease(from: pool.openChild(
            named: childName,
            at: rootURL.appending(path: "Child", directoryHint: .isDirectory),
            relativeTo: rootLease
        ))

        pool.cancel()

        XCTAssertFalse(rootLease.isOpen)
        XCTAssertFalse(childLease.isOpen)
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 0)
        XCTAssertEqual(tracker.openDescriptorCount, 0)
        guard case .fallback = try pool.openRoot(at: rootURL) else {
            return XCTFail("An invalidated pool must reject new opens")
        }
    }

    func testCancellationDuringOpenClosesInFlightDescriptor() async throws {
        let tracker = BlockingDescriptorTracker()
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 1,
            systemCalls: tracker.systemCalls
        )
        let openTask = Task {
            try pool.openRoot(at: URL(filePath: "/virtual/root", directoryHint: .isDirectory))
        }
        XCTAssertEqual(tracker.didEnterOpen.wait(timeout: .now() + 2), .success)

        pool.cancel()
        tracker.allowOpenToReturn.signal()

        do {
            _ = try await openTask.value
            XCTFail("An open completing after cancellation must not vend a lease")
        } catch is CancellationError {
            // Expected: registration observes the invalidated pool.
        }
        XCTAssertEqual(pool.debugCounters.currentOpenDescriptorCount, 0)
        XCTAssertEqual(tracker.openDescriptorCount, 0)
    }

    private func lease(
        from outcome: ScanDirectoryDescriptorPool.OpenOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ScanDirectoryDescriptorPool.Lease {
        guard case .lease(let lease) = outcome else {
            XCTFail("Expected descriptor lease", file: file, line: line)
            throw NSError(domain: "ScanDirectoryDescriptorPoolTests", code: 1)
        }
        return lease
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class DescriptorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var nextDescriptor: Int32 = 100
    private var openDescriptors: Set<Int32> = []

    var systemCalls: ScanDirectoryDescriptorPool.SystemCalls {
        ScanDirectoryDescriptorPool.SystemCalls(
            openRoot: { [weak self] _ in
                guard let self else { return (-1, EBADF) }
                return (self.open(), 0)
            },
            openChild: { [weak self] _, _ in
                guard let self else { return (-1, EBADF) }
                return (self.open(), 0)
            },
            fileIdentity: { _ in (nil, 0) },
            close: { [weak self] descriptor in
                self?.close(descriptor)
            }
        )
    }

    var openDescriptorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openDescriptors.count
    }

    private func open() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = nextDescriptor
        nextDescriptor += 1
        openDescriptors.insert(descriptor)
        return descriptor
    }

    private func close(_ descriptor: Int32) {
        lock.lock()
        openDescriptors.remove(descriptor)
        lock.unlock()
    }
}

private final class BlockingDescriptorTracker: @unchecked Sendable {
    let didEnterOpen = DispatchSemaphore(value: 0)
    let allowOpenToReturn = DispatchSemaphore(value: 0)
    private let tracker = DescriptorTracker()

    var systemCalls: ScanDirectoryDescriptorPool.SystemCalls {
        let underlying = tracker.systemCalls
        return ScanDirectoryDescriptorPool.SystemCalls(
            openRoot: { [didEnterOpen, allowOpenToReturn] url in
                let result = underlying.openRoot(url)
                didEnterOpen.signal()
                allowOpenToReturn.wait()
                return result
            },
            openChild: underlying.openChild,
            fileIdentity: underlying.fileIdentity,
            close: underlying.close
        )
    }

    var openDescriptorCount: Int {
        tracker.openDescriptorCount
    }
}

private final class RetryingDescriptorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var nextDescriptor: Int32 = 200
    private var openDescriptors: Set<Int32> = []
    private var shouldFailNextChildOpen = false

    var systemCalls: ScanDirectoryDescriptorPool.SystemCalls {
        ScanDirectoryDescriptorPool.SystemCalls(
            openRoot: { [weak self] _ in
                guard let self else { return (-1, EBADF) }
                return (self.open(), 0)
            },
            openChild: { [weak self] _, _ in
                guard let self else { return (-1, EBADF) }
                return self.openChild()
            },
            fileIdentity: { _ in (nil, 0) },
            close: { [weak self] descriptor in
                self?.close(descriptor)
            }
        )
    }

    var openDescriptorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openDescriptors.count
    }

    func failNextChildOpenWithEMFILE() {
        lock.lock()
        shouldFailNextChildOpen = true
        lock.unlock()
    }

    private func openChild() -> (descriptor: Int32, errorCode: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailNextChildOpen {
            shouldFailNextChildOpen = false
            return (-1, EMFILE)
        }
        let descriptor = nextDescriptor
        nextDescriptor += 1
        openDescriptors.insert(descriptor)
        return (descriptor, 0)
    }

    private func open() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = nextDescriptor
        nextDescriptor += 1
        openDescriptors.insert(descriptor)
        return descriptor
    }

    private func close(_ descriptor: Int32) {
        lock.lock()
        openDescriptors.remove(descriptor)
        lock.unlock()
    }
}
