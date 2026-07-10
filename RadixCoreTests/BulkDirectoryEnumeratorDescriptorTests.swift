import Darwin
import XCTest
@testable import RadixCore

final class BulkDirectoryEnumeratorDescriptorTests: XCTestCase {
    func testDescriptorCursorMatchesPathCursor() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let directoryURL = rootURL.appending(path: "Folder", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.bin")
        let linkURL = rootURL.appending(path: "payload-link.bin")
        let symlinkURL = rootURL.appending(path: "payload-alias")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x4A, count: 8_193).write(to: fileURL)
        try FileManager.default.linkItem(at: fileURL, to: linkURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)

        let metadataLoader = ScanMetadataLoader()
        let pathResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))
        let descriptor = try openDirectoryDescriptor(at: rootURL)
        let handle = BulkDirectoryEnumerator.NativeDirectoryHandle(owning: descriptor)
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            owning: handle,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )
        var descriptorEntries: [DirectoryEntry] = []
        var descriptorItemCount = 0
        while let batch = try cursor.nextBatch(cancellationCheck: {}) {
            descriptorEntries.append(contentsOf: batch.entries)
            descriptorItemCount += batch.enumeratedItemCount
        }

        XCTAssertFalse(handle.isOpen)
        XCTAssertEqual(descriptorItemCount, pathResult.enumeratedItemCount)
        let pathEntries = Dictionary(uniqueKeysWithValues: pathResult.entries.map {
            ($0.url.lastPathComponent, $0)
        })
        let nativeEntries = Dictionary(uniqueKeysWithValues: descriptorEntries.map {
            ($0.url.lastPathComponent, $0)
        })
        XCTAssertEqual(Set(nativeEntries.keys), Set(pathEntries.keys))
        for name in pathEntries.keys {
            let pathMetadata = try XCTUnwrap(pathEntries[name]?.metadata)
            let nativeMetadata = try XCTUnwrap(nativeEntries[name]?.metadata)
            XCTAssertEqual(nativeMetadata.isDirectory, pathMetadata.isDirectory, name)
            XCTAssertEqual(nativeMetadata.isPackage, pathMetadata.isPackage, name)
            XCTAssertEqual(nativeMetadata.isSymbolicLink, pathMetadata.isSymbolicLink, name)
            XCTAssertEqual(nativeMetadata.logicalSize, pathMetadata.logicalSize, name)
            XCTAssertEqual(nativeMetadata.allocatedSize, pathMetadata.allocatedSize, name)
            XCTAssertEqual(nativeMetadata.fileIdentity, pathMetadata.fileIdentity, name)
            XCTAssertEqual(nativeMetadata.linkCount, pathMetadata.linkCount, name)
        }
    }

    func testDescriptorCursorOwnsAndClosesHandleWhenDropped() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "payload.bin"))

        let descriptor = try openDirectoryDescriptor(at: rootURL)
        let handle = BulkDirectoryEnumerator.NativeDirectoryHandle(owning: descriptor)
        var cursor: BulkDirectoryEnumerator.Cursor? = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            owning: handle,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {}
        )
        _ = try cursor?.nextBatch(cancellationCheck: {})

        cursor = nil

        XCTAssertFalse(handle.isOpen)
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testDescriptorCursorClosesHandleOnUnsupportedFallback() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "payload.bin"))

        let descriptor = try openDirectoryDescriptor(at: rootURL)
        let handle = BulkDirectoryEnumerator.NativeDirectoryHandle(owning: descriptor)
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            owning: handle,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {},
            forcedUnavailableAfterBatchCount: 0
        )

        XCTAssertThrowsError(try cursor.nextBatch(cancellationCheck: {})) { error in
            guard case BulkDirectoryEnumerator.StreamError.unavailable = error else {
                return XCTFail("Expected descriptor cursor fallback, got \(error)")
            }
        }
        XCTAssertFalse(handle.isOpen)
        XCTAssertNil(try cursor.nextBatch(cancellationCheck: {}))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openDirectoryDescriptor(at url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }
}
