import Darwin
import XCTest
@testable import RadixCore

final class PackageClassifierTests: XCTestCase {
    func testClassifierRoutesAndCachesConservativeExtensionDecisions() {
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(
            extensionDispositionProvider: { pathExtension in
                counters.recordExtension(pathExtension)
                return pathExtension == "txt" ? .knownNonPackage : .ambiguous
            },
            foundationPackageProvider: { url in
                counters.recordFoundation(url)
                return ["Sample.app", "Custom.weird"].contains(url.lastPathComponent)
            }
        )

        let ordinaryURL = URL(filePath: "/tmp/Ordinary.TXT", directoryHint: .isDirectory)
        XCTAssertFalse(classifier.classification(for: ordinaryURL, hasFinderPackageFlag: false).isPackage)
        XCTAssertFalse(classifier.classification(for: ordinaryURL, hasFinderPackageFlag: false).isPackage)
        XCTAssertEqual(counters.extensionCount(for: "txt"), 1)
        XCTAssertEqual(counters.foundationCount, 0)

        let appURL = URL(filePath: "/tmp/Sample.app", directoryHint: .isDirectory)
        XCTAssertTrue(classifier.classification(for: appURL, hasFinderPackageFlag: false).isPackage)
        XCTAssertTrue(classifier.classification(for: appURL, hasFinderPackageFlag: false).isPackage)
        XCTAssertEqual(counters.foundationCount, 1)

        let customURL = URL(filePath: "/tmp/Custom.weird", directoryHint: .isDirectory)
        XCTAssertTrue(classifier.classification(for: customURL, hasFinderPackageFlag: false).isPackage)
        XCTAssertTrue(classifier.classification(for: customURL, hasFinderPackageFlag: false).isPackage)
        XCTAssertEqual(counters.extensionCount(for: "weird"), 1)
        XCTAssertEqual(counters.foundationCount, 2)

        let extensionlessURL = URL(filePath: "/tmp/Extensionless", directoryHint: .isDirectory)
        XCTAssertFalse(classifier.classification(for: extensionlessURL, hasFinderPackageFlag: false).isPackage)
        XCTAssertEqual(counters.foundationCount, 3)

        XCTAssertTrue(classifier.classification(for: ordinaryURL, hasFinderPackageFlag: true).isPackage)
        XCTAssertEqual(counters.foundationCount, 3)

        XCTAssertFalse(classifier.classification(for: ordinaryURL, hasFinderPackageFlag: nil).isPackage)
        XCTAssertEqual(counters.foundationCount, 4)
    }

    func testBulkEnumerationUsesClassifierOnlyForNeededDirectories() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for name in ["Ordinary.txt", "Sample.app", "Custom.weird", "Extensionless"] {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(
            extensionDispositionProvider: { pathExtension in
                counters.recordExtension(pathExtension)
                return pathExtension == "txt" ? .knownNonPackage : .ambiguous
            },
            foundationPackageProvider: { url in
                counters.recordFoundation(url)
                return ["Sample.app", "Custom.weird", "Extensionless"].contains(url.lastPathComponent)
            }
        )
        let metadataLoader = ScanMetadataLoader(packageClassifier: classifier)
        let result = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))
        let packageValueByName = Dictionary(uniqueKeysWithValues: result.entries.map {
            ($0.url.lastPathComponent, $0.metadata?.isPackage ?? false)
        })

        XCTAssertEqual(packageValueByName["Ordinary.txt"], false)
        XCTAssertEqual(packageValueByName["Sample.app"], true)
        XCTAssertEqual(packageValueByName["Custom.weird"], true)
        XCTAssertEqual(packageValueByName["Extensionless"], true)
        XCTAssertEqual(counters.foundationCount, 3)

        let noPackageResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            loadsPackageMetadata: false,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))
        XCTAssertTrue(noPackageResult.entries.allSatisfy { $0.metadata?.isPackage == false })
        XCTAssertEqual(counters.foundationCount, 3)
    }

    func testAmbiguousExtensionUsesOneFoundationDecisionPerScan() {
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counters.recordFoundation(url)
            return false
        })

        XCTAssertFalse(classifier.classification(
            for: URL(filePath: "/tmp/First.cache", directoryHint: .isDirectory),
            hasFinderPackageFlag: false
        ).isPackage)
        XCTAssertFalse(classifier.classification(
            for: URL(filePath: "/tmp/Second.CACHE", directoryHint: .isDirectory),
            hasFinderPackageFlag: false
        ).isPackage)
        XCTAssertEqual(counters.foundationCount, 1)
    }

    func testDefaultPolicyFastNegativesOnlyKnownContentExtensions() {
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counters.recordFoundation(url)
            return false
        })

        let textClassification = classifier.classification(
            for: URL(filePath: "/tmp/Ordinary.txt", directoryHint: .isDirectory),
            hasFinderPackageFlag: false
        )
        XCTAssertFalse(textClassification.isPackage)
        XCTAssertEqual(textClassification.source, .fastNegative)
        XCTAssertEqual(counters.foundationCount, 0)

        let unknownClassification = classifier.classification(
            for: URL(filePath: "/tmp/Unknown.radixunknown", directoryHint: .isDirectory),
            hasFinderPackageFlag: false
        )
        XCTAssertFalse(unknownClassification.isPackage)
        XCTAssertEqual(unknownClassification.source, .foundation)
        XCTAssertEqual(counters.foundationCount, 1)
    }

    func testKnownPackageCandidateExtensionsRemainConservative() {
        let candidateExtensions = [
            "app", "appex", "artifactbundle", "bundle", "component", "doccarchive",
            "dsym", "framework", "kext", "mlmodelc", "momd", "mpkg", "pkg",
            "systemextension", "vst", "vst3", "xcarchive", "xcdatamodeld",
            "xcframework", "xcodeproj", "xcresult", "xctest", "xcworkspace", "xpc"
        ]
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(
            extensionDispositionProvider: { _ in .knownNonPackage },
            foundationPackageProvider: { url in
                counters.recordFoundation(url)
                return false
            }
        )

        for pathExtension in candidateExtensions {
            let url = URL(
                filePath: "/tmp/Candidate.\(pathExtension)",
                directoryHint: .isDirectory
            )
            let classification = classifier.classification(
                for: url,
                hasFinderPackageFlag: false
            )
            XCTAssertFalse(classification.isPackage)
            XCTAssertEqual(classification.source, .foundation)
        }
        XCTAssertEqual(counters.foundationCount, candidateExtensions.count)
    }

    func testNativeAndFoundationHintsOverrideCachedExtensionValues() {
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counters.recordFoundation(url)
            return url.lastPathComponent == "Direct.cache"
        })

        let cachedURL = URL(filePath: "/tmp/Cached.cache", directoryHint: .isDirectory)
        XCTAssertFalse(classifier.classification(
            for: cachedURL,
            hasFinderPackageFlag: false
        ).isPackage)
        XCTAssertEqual(counters.foundationCount, 1)

        XCTAssertTrue(classifier.classification(
            for: cachedURL,
            hasFinderPackageFlag: true
        ).isPackage)
        XCTAssertEqual(counters.foundationCount, 1)

        XCTAssertTrue(classifier.classification(
            for: URL(filePath: "/tmp/Direct.cache", directoryHint: .isDirectory),
            hasFinderPackageFlag: nil
        ).isPackage)
        XCTAssertEqual(counters.foundationCount, 2)
    }

    func testFailedFoundationDecisionDoesNotPoisonExtensionCache() {
        let provider = FlakyPackageProvider()
        let classifier = PackageClassifier(foundationPackageProvider: provider.value)
        let url = URL(filePath: "/tmp/Retry.custom", directoryHint: .isDirectory)

        XCTAssertFalse(classifier.classification(for: url, hasFinderPackageFlag: false).isPackage)
        XCTAssertTrue(classifier.classification(for: url, hasFinderPackageFlag: false).isPackage)
        XCTAssertEqual(provider.callCount, 2)
    }

    func testConcurrentAmbiguousExtensionResolutionIsSingleFlight() {
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counters.recordFoundation(url)
            usleep(20_000)
            return false
        })

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let url = URL(filePath: "/tmp/Concurrent-\(index).cache", directoryHint: .isDirectory)
            XCTAssertFalse(classifier.classification(for: url, hasFinderPackageFlag: false).isPackage)
        }
        XCTAssertEqual(counters.foundationCount, 1)
    }

    func testFinderBundleBitPreservesExtensionlessAndOrdinaryExtensionPackages() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let extensionlessURL = rootURL.appending(path: "MarkedPackage", directoryHint: .isDirectory)
        let ordinaryExtensionURL = rootURL.appending(path: "MarkedPackage.txt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extensionlessURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinaryExtensionURL, withIntermediateDirectories: true)
        try setFinderBundleBit(at: extensionlessURL)
        try setFinderBundleBit(at: ordinaryExtensionURL)

        XCTAssertEqual(
            try extensionlessURL.resourceValues(forKeys: [.isPackageKey]).isPackage,
            true
        )
        XCTAssertEqual(
            try ordinaryExtensionURL.resourceValues(forKeys: [.isPackageKey]).isPackage,
            true
        )

        let result = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {}
        ))
        XCTAssertTrue(result.entries.allSatisfy { $0.metadata?.isPackage == true })
    }

    func testRegisteredPackageExtensionsMatchFoundation() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let names = [
            "Application.app", "Installer.pkg", "MetaInstaller.mpkg",
            "Presentation.key", "Book.epub"
        ]
        for name in names {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let result = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {}
        ))
        let bulkValueByName = Dictionary(uniqueKeysWithValues: result.entries.map {
            ($0.url.lastPathComponent, $0.metadata?.isPackage ?? false)
        })

        for name in names {
            let url = rootURL.appending(path: name, directoryHint: .isDirectory)
            let foundationValue = try url.resourceValues(forKeys: [.isPackageKey]).isPackage ?? false
            XCTAssertEqual(bulkValueByName[name], foundationValue, "Package mismatch for .\(url.pathExtension)")
        }
    }

    private func setFinderBundleBit(at url: URL) throws {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x20
        let result = finderInfo.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return setxattr(
                    path,
                    "com.apple.FinderInfo",
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private final class PackageClassifierCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var extensionCounts: [String: Int] = [:]
    private var foundationURLs: [URL] = []

    var foundationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return foundationURLs.count
    }

    func extensionCount(for pathExtension: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return extensionCounts[pathExtension, default: 0]
    }

    func recordExtension(_ pathExtension: String) {
        lock.lock()
        extensionCounts[pathExtension, default: 0] += 1
        lock.unlock()
    }

    func recordFoundation(_ url: URL) {
        lock.lock()
        foundationURLs.append(url)
        lock.unlock()
    }
}

private final class FlakyPackageProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func value(for url: URL) -> Bool? {
        _ = url
        lock.lock()
        calls += 1
        let result: Bool? = calls == 1 ? nil : true
        lock.unlock()
        return result
    }
}
