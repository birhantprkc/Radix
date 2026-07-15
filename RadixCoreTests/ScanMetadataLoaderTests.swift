import Darwin
import XCTest
@testable import RadixCore

final class ScanMetadataLoaderTests: XCTestCase {
    func testLogicalSizeIncludesResourceForkData() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "resource-fork.bin")
        try Data(repeating: 0xA5, count: 4_096).write(to: fileURL)
        try setExtendedAttribute(
            named: "com.apple.ResourceFork",
            data: Data(repeating: 0x5A, count: 10),
            at: fileURL
        )
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        let totalFileSize = try XCTUnwrap(values.totalFileSize)

        let metadata = try ScanMetadataLoader().metadata(for: fileURL)

        XCTAssertGreaterThan(totalFileSize, values.fileSize ?? 0)
        XCTAssertEqual(metadata.logicalSize, Int64(totalFileSize))
    }

    func testMissingAllocatedSizeUsesFileSystemBlockFallback() {
        let url = URL(filePath: "/virtual/sparse.bin")
        let loader = ScanMetadataLoader(
            fileAllocatedSizeProvider: { requestedURL in
                XCTAssertEqual(requestedURL, url)
                return 8_192
            }
        )

        let metadata = loader.metadata(for: url, prefetchedResourceValues: URLResourceValues())

        XCTAssertEqual(metadata.allocatedSize, 8_192)
        XCTAssertEqual(metadata.dataAllocatedSize, 8_192)
    }

    func testUnsupportedCloneMappingVolumeIsProbedOnlyOnce() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstURL = rootURL.appending(path: "first.bin")
        let secondURL = rootURL.appending(path: "second.bin")
        try Data(repeating: 0xA5, count: 128).write(to: firstURL)
        try Data(repeating: 0x5A, count: 128).write(to: secondURL)

        let counters = MetadataProbeCounters()
        let cache = CloneMappingCapabilityCache(
            probeProvider: { _ in
                counters.recordProbe()
                return CloneMappingCapabilityCache.ProbeResult(
                    identity: nil,
                    supportsCloneMapping: false
                )
            },
            volumeRootProvider: { _ in rootURL.path }
        )
        let loader = ScanMetadataLoader(cloneMappingCapabilityCache: cache)

        let firstMetadata = try loader.metadata(for: firstURL)
        let secondMetadata = try loader.metadata(for: secondURL)

        XCTAssertNil(firstMetadata.cloneIdentity)
        XCTAssertNil(secondMetadata.cloneIdentity)
        XCTAssertEqual(counters.probeCount, 1)
    }

    func testRootVolumeCloneCacheDoesNotMaskMountedVolume() {
        let counters = MetadataProbeCounters()
        let cache = CloneMappingCapabilityCache(
            probeProvider: { _ in
                counters.recordProbe()
                return CloneMappingCapabilityCache.ProbeResult(
                    identity: nil,
                    supportsCloneMapping: false
                )
            },
            volumeRootProvider: { url in
                url.path.hasPrefix("/Volumes/External/") ? "/Volumes/External" : "/"
            }
        )

        XCTAssertNil(cache.cloneIdentity(for: URL(filePath: "/Users/example/first.bin")))
        XCTAssertNil(cache.cloneIdentity(for: URL(filePath: "/Volumes/External/second.bin")))

        XCTAssertEqual(counters.probeCount, 2)
    }

    func testMissingLinkCountMetadataUsesLstatFallback() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let linkedURL = rootURL.appending(path: "linked.bin")
        try Data(repeating: 0xA5, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let loader = ScanMetadataLoader(diagnostics: nil)
        let metadata = loader.metadata(
            for: originalURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: originalURL)
        )

        XCTAssertEqual(metadata.linkCount, 2)
        XCTAssertNotNil(metadata.fileIdentity)
    }

    func testFailedLinkCountFallbackUsesConservativeCount() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appending(path: "source.bin")
        try Data(repeating: 0xA5, count: 128).write(to: sourceURL)

        let missingURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)

        let loader = ScanMetadataLoader(diagnostics: nil)
        let metadata = loader.metadata(
            for: missingURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: sourceURL)
        )

        XCTAssertEqual(metadata.linkCount, 1)
        XCTAssertNil(metadata.fileIdentity)
    }

    func testMissingLinkCountOnVolumeWithoutHardLinksSkipsLstatAfterProbe() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstURL = rootURL.appending(path: "first.bin")
        let secondURL = rootURL.appending(path: "second.bin")
        try Data(repeating: 0xA5, count: 128).write(to: firstURL)
        try Data(repeating: 0x5A, count: 128).write(to: secondURL)

        let counters = MetadataProbeCounters()
        let cache = LinkCountCapabilityCache { _ in
            counters.recordProbe()
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootURL.path,
                supportsHardLinks: false
            )
        }
        let fileSystemInfoProvider: ScanMetadataLoader.FileSystemInfoProvider = { _, _ in
            counters.recordLstat()
            return (FileIdentity(device: 1, inode: 2), 2)
        }
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            linkCountCapabilityCache: cache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )

        let firstMetadata = loader.metadata(
            for: firstURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: firstURL)
        )
        let secondMetadata = loader.metadata(
            for: secondURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: secondURL)
        )

        XCTAssertEqual(firstMetadata.linkCount, 1)
        XCTAssertNil(firstMetadata.fileIdentity)
        XCTAssertEqual(secondMetadata.linkCount, 1)
        XCTAssertNil(secondMetadata.fileIdentity)
        XCTAssertEqual(counters.probeCount, 1)
        XCTAssertEqual(counters.lstatCount, 0)
    }

    func testMissingLinkCountOnHardLinkCapableVolumeStillUsesLstatWithCachedProbe() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstURL = rootURL.appending(path: "first.bin")
        let secondURL = rootURL.appending(path: "second.bin")
        try Data(repeating: 0xA5, count: 128).write(to: firstURL)
        try Data(repeating: 0x5A, count: 128).write(to: secondURL)

        let counters = MetadataProbeCounters()
        let cache = LinkCountCapabilityCache { _ in
            counters.recordProbe()
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootURL.path,
                supportsHardLinks: true
            )
        }
        let fileSystemInfoProvider: ScanMetadataLoader.FileSystemInfoProvider = { url, _ in
            counters.recordLstat()
            return (
                FileIdentity(device: 1, inode: url.lastPathComponent == "first.bin" ? 10 : 11),
                2
            )
        }
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            linkCountCapabilityCache: cache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )

        let firstMetadata = loader.metadata(
            for: firstURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: firstURL)
        )
        let secondMetadata = loader.metadata(
            for: secondURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: secondURL)
        )

        XCTAssertEqual(firstMetadata.linkCount, 2)
        XCTAssertNotNil(firstMetadata.fileIdentity)
        XCTAssertEqual(secondMetadata.linkCount, 2)
        XCTAssertNotNil(secondMetadata.fileIdentity)
        XCTAssertEqual(counters.probeCount, 1)
        XCTAssertEqual(counters.lstatCount, 2)
    }

    func testNoHardLinkProbeWithoutVolumeRootDoesNotCacheWholeRoot() throws {
        let rootWithoutVolumeURL = try makeTemporaryDirectory()
        let rootWithVolumeURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootWithoutVolumeURL)
            try? FileManager.default.removeItem(at: rootWithVolumeURL)
        }

        let fileWithoutVolumeURL = rootWithoutVolumeURL.appending(path: "without-volume.bin")
        let fileWithVolumeURL = rootWithVolumeURL.appending(path: "with-volume.bin")
        try Data(repeating: 0xA5, count: 128).write(to: fileWithoutVolumeURL)
        try Data(repeating: 0x5A, count: 128).write(to: fileWithVolumeURL)

        let counters = MetadataProbeCounters()
        let cache = LinkCountCapabilityCache { url in
            counters.recordProbe()
            if url.path.hasPrefix(rootWithoutVolumeURL.path) {
                return LinkCountCapabilityCache.ProbeResult(
                    volumeRootPath: nil,
                    supportsHardLinks: false
                )
            }
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootWithVolumeURL.path,
                supportsHardLinks: true
            )
        }
        let fileSystemInfoProvider: ScanMetadataLoader.FileSystemInfoProvider = { _, _ in
            counters.recordLstat()
            return (FileIdentity(device: 1, inode: 12), 2)
        }
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            linkCountCapabilityCache: cache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )

        let metadataWithoutVolume = loader.metadata(
            for: fileWithoutVolumeURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: fileWithoutVolumeURL)
        )
        let metadataWithVolume = loader.metadata(
            for: fileWithVolumeURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: fileWithVolumeURL)
        )

        XCTAssertEqual(metadataWithoutVolume.linkCount, 1)
        XCTAssertNil(metadataWithoutVolume.fileIdentity)
        XCTAssertEqual(metadataWithVolume.linkCount, 2)
        XCTAssertNotNil(metadataWithVolume.fileIdentity)
        XCTAssertEqual(counters.probeCount, 2)
        XCTAssertEqual(counters.lstatCount, 1)
    }

    func testVisibleSymlinkMetadataUsesLstatIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let targetURL = rootURL.appending(path: "target.bin")
        let symlinkURL = rootURL.appending(path: "target-link")
        try Data(repeating: 0xA5, count: 128).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            fileSystemInfoProvider: { _, _ in
                counters.recordLstat()
                return (FileIdentity(device: 1, inode: 42), 1)
            }
        )

        let metadata = loader.metadata(
            for: symlinkURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: symlinkURL)
        )

        XCTAssertTrue(metadata.isSymbolicLink)
        XCTAssertEqual(metadata.fileIdentity, FileIdentity(device: 1, inode: 42))
        XCTAssertEqual(counters.lstatCount, 1)
    }

    func testDirectoryMetadataUsesFileSystemIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            fileSystemInfoProvider: { _, _ in
                counters.recordLstat()
                return (FileIdentity(device: 7, inode: 42), 9)
            }
        )

        let metadata = try loader.metadata(for: rootURL)

        XCTAssertTrue(metadata.isDirectory)
        XCTAssertEqual(metadata.fileIdentity, FileIdentity(device: 7, inode: 42))
        XCTAssertEqual(metadata.linkCount, 1)
        XCTAssertEqual(counters.lstatCount, 1)
    }

    func testAtomicSummarySymlinkMetadataSkipsLstatIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let targetURL = rootURL.appending(path: "target.bin")
        let symlinkURL = rootURL.appending(path: "target-link")
        try Data(repeating: 0xA5, count: 128).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            fileSystemInfoProvider: { _, _ in
                counters.recordLstat()
                return (FileIdentity(device: 1, inode: 42), 1)
            }
        )

        let metadata = loader.atomicSummaryMetadata(
            for: symlinkURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: symlinkURL)
        )

        XCTAssertTrue(metadata.isSymbolicLink)
        XCTAssertNil(metadata.fileIdentity)
        XCTAssertEqual(metadata.linkCount, 1)
        XCTAssertEqual(counters.lstatCount, 0)
    }

    private func resourceValuesWithoutIdentity(for url: URL) throws -> URLResourceValues {
        try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .contentModificationDateKey,
            .isReadableKey
        ])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setExtendedAttribute(named name: String, data: Data, at url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

}

private final class MetadataProbeCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var probes = 0
    private var lstats = 0

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    var lstatCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lstats
    }

    func recordProbe() {
        lock.lock()
        probes += 1
        lock.unlock()
    }

    func recordLstat() {
        lock.lock()
        lstats += 1
        lock.unlock()
    }
}
