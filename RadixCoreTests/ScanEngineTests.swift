import Darwin
import XCTest
@testable import RadixCore

final class ScanEngineTests: XCTestCase {
    func testAtomicSummarySizeAccumulationClampsInsteadOfOverflowing() {
        var partial = AtomicDirectorySummaryPartial(
            allocatedSize: Int64.max,
            logicalSize: Int64.max,
            descendantFileCount: Int.max
        )
        let metadata = NodeMetadata(
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            logicalSize: 1,
            allocatedSize: 1,
            lastModified: nil,
            isReadable: true,
            volumeCapacity: nil,
            fileIdentity: nil,
            linkCount: 1
        )

        partial.accumulateFile(
            metadata,
            url: URL(filePath: "/overflow.bin"),
            ownerNodeID: "/"
        )

        XCTAssertEqual(partial.allocatedSize, Int64.max)
        XCTAssertEqual(partial.logicalSize, Int64.max)
        XCTAssertEqual(partial.descendantFileCount, Int.max)

        let accumulator = AtomicSummaryAccumulator(seed: partial)
        accumulator.merge(AtomicDirectorySummaryPartial(
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 1
        ))
        let summary = accumulator.makeSummary()
        XCTAssertEqual(summary.allocatedSize, Int64.max)
        XCTAssertEqual(summary.logicalSize, Int64.max)
        XCTAssertEqual(summary.descendantFileCount, Int.max)
    }

    func testLowDescriptorBudgetMatchesNormalScanAndStaysWithinPeak() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for branch in 0..<8 {
            let nestedURL = rootURL.appending(
                path: "Branch-\(branch)/Nested/Deep",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(branch), count: branch + 1).write(
                to: nestedURL.appending(path: "payload.bin")
            )
        }
        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 4
        let reference = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let descriptorPool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 2)
        let constrained = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
        )

        let referenceIDs = reference.treeStore.indexedNodeIDs()
        XCTAssertEqual(constrained.treeStore.indexedNodeIDs(), referenceIDs)
        for nodeID in referenceIDs {
            XCTAssertEqual(constrained.treeStore.node(id: nodeID), reference.treeStore.node(id: nodeID), nodeID)
            XCTAssertEqual(
                constrained.treeStore.children(of: nodeID).map(\.id),
                reference.treeStore.children(of: nodeID).map(\.id),
                nodeID
            )
        }
        XCTAssertEqual(constrained.aggregateStats.totalAllocatedSize, reference.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(constrained.aggregateStats.totalLogicalSize, reference.aggregateStats.totalLogicalSize)
        XCTAssertEqual(constrained.aggregateStats.fileCount, reference.aggregateStats.fileCount)
        XCTAssertEqual(constrained.aggregateStats.directoryCount, reference.aggregateStats.directoryCount)
        XCTAssertEqual(constrained.aggregateStats.accessibleItemCount, reference.aggregateStats.accessibleItemCount)
        XCTAssertEqual(constrained.aggregateStats.inaccessibleItemCount, reference.aggregateStats.inaccessibleItemCount)
        let counters = descriptorPool.debugCounters
        XCTAssertLessThanOrEqual(counters.peakOpenDescriptorCount, 2)
        XCTAssertGreaterThan(counters.openatCallCount, 0)
        XCTAssertGreaterThan(counters.fallbackCount, 0)
        XCTAssertEqual(counters.currentOpenDescriptorCount, 0)
    }

    func testDirectorySymlinkSwapAfterDiscoveryIsRefused() async throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        let outsideFileURL = outsideURL.appending(path: "outside.bin")
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try Data([0x5A]).write(to: outsideFileURL)

        let blocker = BlockingLiveChildOpen()
        let descriptorPool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 8,
            systemCalls: blocker.systemCalls
        )
        let scanTask = Task {
            try await finishedSnapshot(
                target: ScanTarget(url: rootURL),
                options: ScanOptions(),
                engine: ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
            )
        }
        defer {
            blocker.release()
            scanTask.cancel()
        }
        XCTAssertEqual(blocker.didReachChildOpen.wait(timeout: .now() + 2), .success)
        try FileManager.default.removeItem(at: childURL)
        try FileManager.default.createSymbolicLink(at: childURL, withDestinationURL: outsideURL)
        blocker.release()

        let snapshot = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }
        let childNode = try XCTUnwrap(snapshot.treeStore.node(id: childURL.path))
        XCTAssertFalse(childNode.isAccessible)
        XCTAssertNil(snapshot.treeStore.node(id: childURL.appending(path: "outside.bin").path))
        XCTAssertNil(snapshot.treeStore.node(id: outsideFileURL.path))
        XCTAssertFalse(snapshot.scanWarnings.isEmpty)
        XCTAssertEqual(descriptorPool.debugCounters.currentOpenDescriptorCount, 0)
    }

    func testCancellingDescriptorRelativeScanClosesInFlightAndRetainedLeases() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try Data([0x4A]).write(to: childURL.appending(path: "payload.bin"))

        let blocker = BlockingLiveChildOpen()
        let descriptorPool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 8,
            systemCalls: blocker.systemCalls
        )
        let engine = ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
        let scanTask = Task {
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event { return true }
                }
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
            return false
        }
        defer {
            blocker.release()
            scanTask.cancel()
        }
        XCTAssertEqual(blocker.didReachChildOpen.wait(timeout: .now() + 2), .success)

        scanTask.cancel()
        blocker.release()
        let didFinish = try await withTimeout(.seconds(2)) {
            await scanTask.value
        }

        XCTAssertFalse(didFinish)
        for _ in 0..<100 where descriptorPool.debugCounters.currentOpenDescriptorCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(descriptorPool.debugCounters.currentOpenDescriptorCount, 0)
    }

    func testBulkDirectoryEnumerationRejectsIncompleteMetadataAttributeSets() {
        var returned = attribute_set_t()
        returned.commonattr = .max
        returned.fileattr = .max

        XCTAssertTrue(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VREG.rawValue))

        returned.fileattr &= ~attrgroup_t(ATTR_FILE_LINKCOUNT)
        XCTAssertFalse(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VREG.rawValue))
        XCTAssertFalse(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VLNK.rawValue))
        XCTAssertTrue(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VDIR.rawValue))

        returned.commonattr &= ~attrgroup_t(ATTR_CMN_OBJTYPE)
        XCTAssertFalse(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VDIR.rawValue))
    }

    func testBulkDirectoryEnumerationMatchesScannerMetadataAndHiddenFiltering() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let directoryURL = rootURL.appending(path: "Folder", directoryHint: .isDirectory)
        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.bin")
        let hardLinkURL = rootURL.appending(path: "payload-link.bin")
        let symbolicLinkURL = rootURL.appending(path: "payload-alias")
        let hiddenURL = rootURL.appending(path: ".hidden")
        var flaggedHiddenURL = rootURL.appending(path: "flagged-hidden")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 4_097).write(to: fileURL)
        try FileManager.default.linkItem(at: fileURL, to: hardLinkURL)
        try FileManager.default.createSymbolicLink(at: symbolicLinkURL, withDestinationURL: fileURL)
        try Data([0x1]).write(to: hiddenURL)
        try Data([0x2]).write(to: flaggedHiddenURL)
        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        try flaggedHiddenURL.setResourceValues(hiddenValues)

        let metadataLoader = ScanMetadataLoader()
        let visibleResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: false,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))
        let completeResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))

        XCTAssertEqual(visibleResult.enumeratedItemCount, 7)
        XCTAssertEqual(completeResult.enumeratedItemCount, 7)
        XCTAssertFalse(visibleResult.entries.contains { $0.url.lastPathComponent == ".hidden" })
        XCTAssertFalse(visibleResult.entries.contains { $0.url.lastPathComponent == "flagged-hidden" })
        XCTAssertTrue(completeResult.entries.contains { $0.url.lastPathComponent == ".hidden" })
        XCTAssertTrue(completeResult.entries.contains { $0.url.lastPathComponent == "flagged-hidden" })

        let entriesByName = Dictionary(uniqueKeysWithValues: completeResult.entries.map {
            ($0.url.lastPathComponent, $0)
        })
        let fileMetadata = try XCTUnwrap(entriesByName["payload.bin"]?.metadata)
        let linkMetadata = try XCTUnwrap(entriesByName["payload-link.bin"]?.metadata)
        let symlinkMetadata = try XCTUnwrap(entriesByName["payload-alias"]?.metadata)
        let directoryMetadata = try XCTUnwrap(entriesByName["Folder"]?.metadata)
        let loadedDirectoryMetadata = try metadataLoader.metadata(for: directoryURL)

        XCTAssertEqual(directoryMetadata.lastModified, loadedDirectoryMetadata.lastModified)
        let packageMetadata = try XCTUnwrap(entriesByName["Sample.app"]?.metadata)
        let foundationFileMetadata = try metadataLoader.metadata(for: fileURL)

        XCTAssertEqual(fileMetadata.logicalSize, foundationFileMetadata.logicalSize)
        XCTAssertEqual(fileMetadata.allocatedSize, foundationFileMetadata.allocatedSize)
        XCTAssertEqual(fileMetadata.linkCount, foundationFileMetadata.linkCount)
        XCTAssertEqual(fileMetadata.fileIdentity, linkMetadata.fileIdentity)
        XCTAssertGreaterThan(fileMetadata.linkCount, 1)
        XCTAssertTrue(symlinkMetadata.isSymbolicLink)
        XCTAssertTrue(directoryMetadata.isDirectory)
        XCTAssertFalse(directoryMetadata.isPackage)
        XCTAssertTrue(packageMetadata.isDirectory)
        XCTAssertTrue(packageMetadata.isPackage)
    }

    func testBulkDirectoryCursorStreamsAndCancelsBetweenBatches() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<1_200 {
            try Data([UInt8(index % 256)]).write(
                to: rootURL.appending(path: String(format: "streamed-%06d-with-padding-payload.dat", index))
            )
        }

        let metadataLoader = ScanMetadataLoader()
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )
        var names: Set<String> = []
        var batchCount = 0
        var maxBatchSize = 0
        var enumeratedItemCount = 0
        while let batch = try cursor.nextBatch(cancellationCheck: {}) {
            batchCount += 1
            maxBatchSize = max(maxBatchSize, batch.entries.count)
            enumeratedItemCount += batch.enumeratedItemCount
            names.formUnion(batch.entries.map(\.url.lastPathComponent))
        }

        XCTAssertGreaterThan(batchCount, 1)
        XCTAssertLessThan(maxBatchSize, 1_200)
        XCTAssertEqual(enumeratedItemCount, 1_200)
        XCTAssertEqual(names.count, 1_200)

        let unavailableResult = try BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            forcedUnavailableAfterBatchCount: 1
        )
        XCTAssertNil(unavailableResult, "Late native fallback must discard earlier uncommitted batches.")

        let cancellation = DirectoryEnumerationCancellation()
        let cancellingCursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: cancellation.check
        )
        let firstBatch = try XCTUnwrap(cancellingCursor.nextBatch(cancellationCheck: cancellation.check))
        XCTAssertLessThan(firstBatch.enumeratedItemCount, 1_200)
        cancellation.cancel()
        XCTAssertThrowsError(try cancellingCursor.nextBatch(cancellationCheck: cancellation.check)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let parsingCancellation = CancellationAfterChecks(3)
        let parsingCursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: parsingCancellation.check
        )
        XCTAssertThrowsError(try parsingCursor.nextBatch(cancellationCheck: parsingCancellation.check)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(try parsingCursor.nextBatch(cancellationCheck: {}))
    }

    func testDescriptorRelativeTraversalMatchesBudgetFallback() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for branch in 0..<6 {
            let leafURL = rootURL
                .appending(path: "branch-\(branch)", directoryHint: .isDirectory)
                .appending(path: "nested", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: leafURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(branch), count: 257 + branch).write(
                to: leafURL.appending(path: "payload-\(branch).bin")
            )
        }

        let descriptorPool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 32)
        let descriptorEngine = ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
        let descriptorSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: descriptorEngine
        )

        let fallbackPool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 1)
        let fallbackEngine = ScanEngine(directoryDescriptorPoolFactory: { fallbackPool })
        let fallbackSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: fallbackEngine
        )

        XCTAssertEqual(descriptorSnapshot.treeStore.indexedNodeIDs(), fallbackSnapshot.treeStore.indexedNodeIDs())
        XCTAssertEqual(descriptorSnapshot.treeStore.childIDsByID, fallbackSnapshot.treeStore.childIDsByID)
        XCTAssertEqual(descriptorSnapshot.root.allocatedSize, fallbackSnapshot.root.allocatedSize)
        XCTAssertGreaterThan(descriptorPool.debugCounters.openatCallCount, 0)
        XCTAssertEqual(descriptorPool.debugCounters.currentOpenDescriptorCount, 0)
        XCTAssertLessThanOrEqual(descriptorPool.debugCounters.peakOpenDescriptorCount, 32)
        XCTAssertGreaterThan(fallbackPool.debugCounters.fallbackCount, 0)
        XCTAssertEqual(fallbackPool.debugCounters.currentOpenDescriptorCount, 0)
        XCTAssertLessThanOrEqual(fallbackPool.debugCounters.peakOpenDescriptorCount, 1)
    }

    func testBulkAndFoundationScannersMatchAdversarialFixture() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let unicodeDirectoryURL = rootURL.appending(
            path: "Ångström-文件-🙂",
            directoryHint: .isDirectory
        )
        let ownerDirectoryURL = rootURL.appending(path: "A-Owner", directoryHint: .isDirectory)
        let linkDirectoryURL = rootURL.appending(path: "Z-Link", directoryHint: .isDirectory)
        let packageURL = rootURL.appending(path: "Payload.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unicodeDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ownerDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: packageURL.appending(path: "Contents/Resources", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let sparseURL = unicodeDirectoryURL.appending(path: "sparse-ß.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparseURL.path, contents: nil))
        let sparseHandle = try FileHandle(forWritingTo: sparseURL)
        try sparseHandle.truncate(atOffset: 16 * 1_024 * 1_024)
        try sparseHandle.close()
        try Data([0x11]).write(to: unicodeDirectoryURL.appending(path: ".hidden"))

        let ownerURL = ownerDirectoryURL.appending(path: "shared.dat")
        let linkedURL = linkDirectoryURL.appending(path: "shared.dat")
        try Data(repeating: 0x5A, count: 8_192).write(to: ownerURL)
        try FileManager.default.linkItem(at: ownerURL, to: linkedURL)
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "file-alias"),
            withDestinationURL: ownerURL
        )
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "directory-alias"),
            withDestinationURL: unicodeDirectoryURL
        )
        try Data(repeating: 0x7F, count: 257).write(
            to: packageURL.appending(path: "Contents/Resources/asset.dat")
        )

        var options = ScanOptions()
        options.includeHiddenFiles = true
        options.autoSummarizeDirectories = false
        let optimized = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let foundation = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(directoryContents: { url, keys, enumerationOptions, cancellationCheck in
                try cancellationCheck()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: enumerationOptions
                )
                try cancellationCheck()
                return contents
            })
        )

        XCTAssertEqual(optimized.treeStore.indexedNodeIDs(), foundation.treeStore.indexedNodeIDs())
        XCTAssertEqual(optimized.treeStore.childIDsByID, foundation.treeStore.childIDsByID)
        XCTAssertEqual(optimized.aggregateStats.totalAllocatedSize, foundation.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(optimized.aggregateStats.totalLogicalSize, foundation.aggregateStats.totalLogicalSize)
        XCTAssertEqual(optimized.aggregateStats.fileCount, foundation.aggregateStats.fileCount)
        XCTAssertEqual(optimized.aggregateStats.directoryCount, foundation.aggregateStats.directoryCount)
        XCTAssertEqual(optimized.aggregateStats.accessibleItemCount, foundation.aggregateStats.accessibleItemCount)
        XCTAssertEqual(optimized.aggregateStats.inaccessibleItemCount, foundation.aggregateStats.inaccessibleItemCount)

        for nodeID in optimized.treeStore.indexedNodeIDs() {
            let optimizedNode = try XCTUnwrap(optimized.treeStore.node(id: nodeID))
            let foundationNode = try XCTUnwrap(foundation.treeStore.node(id: nodeID))
            XCTAssertEqual(optimizedNode.name, foundationNode.name, nodeID)
            XCTAssertEqual(optimizedNode.isDirectory, foundationNode.isDirectory, nodeID)
            XCTAssertEqual(optimizedNode.isSymbolicLink, foundationNode.isSymbolicLink, nodeID)
            XCTAssertEqual(optimizedNode.allocatedSize, foundationNode.allocatedSize, nodeID)
            XCTAssertEqual(
                optimizedNode.unduplicatedAllocatedSize,
                foundationNode.unduplicatedAllocatedSize,
                nodeID
            )
            XCTAssertEqual(optimizedNode.dataAllocatedSize, foundationNode.dataAllocatedSize, nodeID)
            XCTAssertEqual(optimizedNode.logicalSize, foundationNode.logicalSize, nodeID)
            XCTAssertEqual(optimizedNode.descendantFileCount, foundationNode.descendantFileCount, nodeID)
            XCTAssertEqual(optimizedNode.linkCount, foundationNode.linkCount, nodeID)
            XCTAssertEqual(optimizedNode.cloneIdentity, foundationNode.cloneIdentity, nodeID)
            XCTAssertEqual(optimizedNode.isPackage, foundationNode.isPackage, nodeID)
            XCTAssertEqual(optimizedNode.isAccessible, foundationNode.isAccessible, nodeID)
            XCTAssertEqual(optimizedNode.isSelfAccessible, foundationNode.isSelfAccessible, nodeID)
            if optimizedNode.linkCount > 1 {
                XCTAssertNotNil(optimizedNode.fileIdentity, nodeID)
                XCTAssertNotNil(foundationNode.fileIdentity, nodeID)
            } else if optimizedNode.isSymbolicLink || optimizedNode.isDirectory {
                XCTAssertEqual(optimizedNode.fileIdentity, foundationNode.fileIdentity, nodeID)
            }
        }
    }

    func testPackagesAreLeafNodesByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(packageNode.isPackage)
        XCTAssertTrue(packageNode.isDirectory)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertGreaterThanOrEqual(packageNode.logicalSize, Int64("binary".utf8.count))
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testPackageLeafNodesIncludeNestedPackageContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Host.app", directoryHint: .isDirectory)
        let nestedPackageURL = packageURL.appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
        let nestedBinaryURL = nestedPackageURL.appending(path: "Contents/MacOS/NestedBinary")

        try FileManager.default.createDirectory(at: nestedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: nestedBinaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Host.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertGreaterThanOrEqual(packageNode.logicalSize, 2_048)
    }

    func testPackageLeafSizesIgnoreNestedDirectoryEntries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Deep.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/Frameworks/A.framework/Resources/B.bundle/C.txt")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: 1_024).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Deep.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 1_024)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 1_024)
    }

    func testPackageRootHardLinksOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Linked.app", directoryHint: .isDirectory)
        let originalURL = packageURL.appending(path: "Contents/Resources/original.bin")
        let linkedURL = packageURL.appending(path: "Contents/Resources/linked.bin")

        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xCA, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: packageURL),
            options: ScanOptions()
        )

        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 8_192)
        XCTAssertGreaterThan(snapshot.root.allocatedSize, 0)
        XCTAssertLessThan(snapshot.root.allocatedSize, snapshot.root.logicalSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testHardLinkCrossingAtomicPackageAndVisibleFileUsesLexicographicOwner() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let visibleFileURL = rootURL.appending(path: "a-shared.bin")
        let packageURL = rootURL.appending(path: "z.app", directoryHint: .isDirectory)
        let packageLinkURL = packageURL.appending(path: "Contents/Resources/shared.bin")
        try FileManager.default.createDirectory(
            at: packageLinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xA6, count: 4_096).write(to: visibleFileURL)
        try FileManager.default.linkItem(at: visibleFileURL, to: packageLinkURL)

        let packageMinimumAllocatedSize = try ScanMetadataLoader().metadata(for: packageURL).allocatedSize
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let visibleNode = try XCTUnwrap(snapshot.treeStore.node(id: visibleFileURL.path))
        let packageNode = try XCTUnwrap(snapshot.treeStore.node(id: packageURL.path))

        XCTAssertGreaterThan(visibleNode.allocatedSize, 0)
        XCTAssertEqual(packageNode.allocatedSize, packageMinimumAllocatedSize)
        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 8_192)
        XCTAssertEqual(
            snapshot.root.allocatedSize,
            visibleNode.allocatedSize + packageNode.allocatedSize
        )
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testParallelPackageSummaryMatchesSerialSummary() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Parallel.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Parallel")
        let resourceURL = packageURL.appending(path: "Contents/Resources/Data/blob.dat")
        let hiddenURL = packageURL.appending(path: "Contents/Resources/.hidden")
        let nestedPackageBinaryURL = packageURL
            .appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Nested")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedPackageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: binaryURL)
        try Data(repeating: 0x2, count: 256).write(to: resourceURL)
        try Data(repeating: 0x3, count: 512).write(to: hiddenURL)
        try Data(repeating: 0x4, count: 1_024).write(to: nestedPackageBinaryURL)

        var serialOptions = ScanOptions()
        serialOptions.atomicSummaryWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.atomicSummaryWorkerLimit = 2

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)
        let serialPackageNode = try XCTUnwrap(rootChildren(in: serialSnapshot).first(where: { $0.name == "Parallel.app" }))
        let parallelPackageNode = try XCTUnwrap(rootChildren(in: parallelSnapshot).first(where: { $0.name == "Parallel.app" }))

        XCTAssertEqual(parallelPackageNode.descendantFileCount, serialPackageNode.descendantFileCount)
        XCTAssertEqual(parallelPackageNode.logicalSize, serialPackageNode.logicalSize)
        XCTAssertEqual(parallelPackageNode.allocatedSize, serialPackageNode.allocatedSize)
        XCTAssertEqual(parallelPackageNode.isAccessible, serialPackageNode.isAccessible)
        XCTAssertEqual(parallelPackageNode.isSelfAccessible, serialPackageNode.isSelfAccessible)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
    }

    func testScanWidePackageSummaryPoolMatchesSerialAcrossSiblingPackages() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var firstPayloadURL: URL?
        for packageIndex in 0..<24 {
            let resourcesURL = rootURL
                .appending(
                    path: String(format: "Sibling-%02d.app", packageIndex),
                    directoryHint: .isDirectory
                )
                .appending(path: "Contents/Resources", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
            for fileIndex in 0..<4 {
                let payloadURL = resourcesURL.appending(
                    path: String(format: "payload-%02d.dat", fileIndex)
                )
                try Data(repeating: UInt8(packageIndex), count: packageIndex + fileIndex + 1)
                    .write(to: payloadURL)
                if packageIndex == 0, fileIndex == 0 {
                    firstPayloadURL = payloadURL
                }
            }
            try Data(repeating: 0xFF, count: 128).write(
                to: resourcesURL.appending(path: ".hidden-payload")
            )
        }

        let sharedSourceURL = try XCTUnwrap(firstPayloadURL)
        let sharedLinkURL = rootURL
            .appending(path: "Sibling-01.app/Contents/Resources/shared-link.dat")
        try FileManager.default.linkItem(at: sharedSourceURL, to: sharedLinkURL)

        var serialOptions = ScanOptions()
        serialOptions.atomicSummaryWorkerLimit = 1
        var pooledOptions = ScanOptions()
        pooledOptions.atomicSummaryWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: serialOptions
        )
        let pooledSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: pooledOptions
        )
        let serialNodes = Dictionary(uniqueKeysWithValues: rootChildren(in: serialSnapshot).map {
            ($0.name, $0)
        })
        let pooledNodes = Dictionary(uniqueKeysWithValues: rootChildren(in: pooledSnapshot).map {
            ($0.name, $0)
        })

        XCTAssertEqual(pooledNodes.count, 24)
        XCTAssertEqual(Set(pooledNodes.keys), Set(serialNodes.keys))
        for name in serialNodes.keys {
            let serialNode = try XCTUnwrap(serialNodes[name])
            let pooledNode = try XCTUnwrap(pooledNodes[name])
            XCTAssertEqual(pooledNode.descendantFileCount, serialNode.descendantFileCount, name)
            XCTAssertEqual(pooledNode.logicalSize, serialNode.logicalSize, name)
            XCTAssertEqual(pooledNode.allocatedSize, serialNode.allocatedSize, name)
            XCTAssertEqual(pooledNode.isAccessible, serialNode.isAccessible, name)
        }
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.totalAllocatedSize,
            serialSnapshot.aggregateStats.totalAllocatedSize
        )
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.totalLogicalSize,
            serialSnapshot.aggregateStats.totalLogicalSize
        )
        XCTAssertEqual(pooledSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.directoryCount,
            serialSnapshot.aggregateStats.directoryCount
        )
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.accessibleItemCount,
            serialSnapshot.aggregateStats.accessibleItemCount
        )
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.inaccessibleItemCount,
            serialSnapshot.aggregateStats.inaccessibleItemCount
        )
        XCTAssertEqual(pooledSnapshot.scanWarnings, serialSnapshot.scanWarnings)
    }

    func testPackageSummariesShareScanWideBoundedWorkers() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for packageIndex in 0..<4 {
            let packageURL = rootURL.appending(
                path: String(format: "Package-%02d.app", packageIndex),
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            for fileIndex in 0..<3 {
                try Data(repeating: UInt8(packageIndex), count: fileIndex + 1).write(
                    to: packageURL.appending(path: "payload-\(fileIndex).dat")
                )
            }
        }

        let probe = BlockingAtomicSummaryWorkerProbe()
        let observer = AtomicSummaryWorkerObserver(
            didStart: probe.didStart,
            didFinish: probe.didFinish
        )
        let engine = ScanEngine(atomicSummaryWorkerObserver: observer)
        var options = ScanOptions()
        options.atomicSummaryWorkerLimit = 2
        options.directoryTraversalWorkerLimit = 1
        let scanTask = Task {
            try await finishedSnapshot(
                target: ScanTarget(url: rootURL),
                options: options,
                engine: engine
            )
        }
        defer {
            probe.releaseAll()
            scanTask.cancel()
        }

        XCTAssertTrue(probe.waitForDistinctActiveOwners(2, timeout: 2))
        XCTAssertEqual(probe.activeWorkerCount, 2)
        XCTAssertEqual(probe.peakActiveWorkerCount, 2)
        XCTAssertEqual(probe.activeOwnerCount, 2)
        probe.releaseAll()

        let snapshot = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }
        let packageNodes = rootChildren(in: snapshot)
        XCTAssertEqual(packageNodes.count, 4)
        XCTAssertTrue(packageNodes.allSatisfy { $0.descendantFileCount == 3 })
        XCTAssertTrue(packageNodes.allSatisfy { !containsChildren($0, in: snapshot) })
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 12)
        XCTAssertEqual(probe.seenOwnerCount, 4)
        XCTAssertGreaterThanOrEqual(probe.maximumDistinctActiveOwnerCount, 2)
        XCTAssertLessThanOrEqual(probe.peakActiveWorkerCount, 2)
        XCTAssertEqual(probe.activeWorkerCount, 0)
    }

    func testRecursiveBulkPackageSummaryMatchesSerialAcrossMultipleBatches() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Wide.app", directoryHint: .isDirectory)
        let wideDirectoryURL = packageURL.appending(
            path: "Contents/Resources/Wide",
            directoryHint: .isDirectory
        )
        let nestedPackageDirectoryURL = packageURL.appending(
            path: "Contents/PlugIns/Nested.bundle/Contents/Resources",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: wideDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedPackageDirectoryURL, withIntermediateDirectories: true)

        for index in 0..<700 {
            try Data([UInt8(index % 256)]).write(
                to: wideDirectoryURL.appending(path: String(format: "wide-payload-%06d-with-padding.dat", index))
            )
        }
        for index in 0..<50 {
            try Data(repeating: UInt8(index), count: 2).write(
                to: nestedPackageDirectoryURL.appending(path: String(format: "nested-%04d.dat", index))
            )
        }

        let originalURL = nestedPackageDirectoryURL.appending(path: "original.bin")
        let linkedURL = wideDirectoryURL.appending(path: "linked.bin")
        try Data(repeating: 0xA5, count: 64).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        var serialOptions = ScanOptions()
        serialOptions.atomicSummaryWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.atomicSummaryWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)
        let serialPackageNode = try XCTUnwrap(rootChildren(in: serialSnapshot).first { $0.name == "Wide.app" })
        let parallelPackageNode = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.name == "Wide.app" })

        XCTAssertEqual(serialPackageNode.descendantFileCount, 752)
        XCTAssertEqual(serialPackageNode.logicalSize, 928)
        XCTAssertEqual(parallelPackageNode.descendantFileCount, serialPackageNode.descendantFileCount)
        XCTAssertEqual(parallelPackageNode.logicalSize, serialPackageNode.logicalSize)
        XCTAssertEqual(parallelPackageNode.allocatedSize, serialPackageNode.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
    }

    func testRecursiveBulkPackageSummaryDoesNotFollowDirectorySymlinks() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let externalDirectoryURL = rootURL.appending(path: "External", directoryHint: .isDirectory)
        let externalFileURL = externalDirectoryURL.appending(path: "large.bin")
        let packageURL = rootURL.appending(path: "Links.app", directoryHint: .isDirectory)
        let resourcesURL = packageURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let localFileURL = resourcesURL.appending(path: "local.bin")
        let externalLinkURL = resourcesURL.appending(path: "ExternalLink")
        let cycleLinkURL = resourcesURL.appending(path: "PackageCycle")

        try FileManager.default.createDirectory(at: externalDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 32_768).write(to: externalFileURL)
        try Data(repeating: 0x11, count: 32).write(to: localFileURL)
        try FileManager.default.createSymbolicLink(at: externalLinkURL, withDestinationURL: externalDirectoryURL)
        try FileManager.default.createSymbolicLink(at: cycleLinkURL, withDestinationURL: packageURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first { $0.name == "Links.app" })

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertLessThan(packageNode.logicalSize, 32_768)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
    }

    func testPackagesCanBeExpandedWhenEnabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(treatPackagesAsDirectories: true)
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(containsChildren(packageNode, in: snapshot))
        XCTAssertEqual(packageNode.descendantFileCount, 1)
    }

    func testAtomicPackageAccessFailuresProduceWarnings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Locked.app", directoryHint: .isDirectory)
        let readableFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let unreadableDirectoryURL = packageURL.appending(path: "Contents/Private")
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "Secret.dat")

        try FileManager.default.createDirectory(at: readableFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: readableFileURL)
        try Data("secret".utf8).write(to: unreadableFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableDirectoryURL.path)
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked.app" }))

        XCTAssertFalse(packageNode.isAccessible)
        XCTAssertFalse(snapshot.scanWarnings.isEmpty)
        XCTAssertTrue(snapshot.scanWarnings.contains(where: { $0.path.contains("Locked.app") }))
    }

    func testUnreadableOrdinaryDirectoryProducesWarningAndContinuesScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableFileURL = rootURL.appending(path: "visible.txt")
        let unreadableDirectoryURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "secret.txt")

        try Data("visible".utf8).write(to: readableFileURL)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: unreadableFileURL)
        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url.lastPathComponent == "Locked" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )
        let lockedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let visibleNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let warning = try XCTUnwrap(snapshot.scanWarnings.first(where: { $0.path == lockedNode.url.path }))

        XCTAssertTrue(lockedNode.isDirectory)
        XCTAssertFalse(lockedNode.isPackage)
        XCTAssertFalse(lockedNode.isAccessible)
        XCTAssertEqual(lockedNode.allocatedSize, 0)
        XCTAssertEqual(lockedNode.logicalSize, 0)
        XCTAssertEqual(lockedNode.descendantFileCount, 0)
        XCTAssertFalse(containsChildren(lockedNode, in: snapshot))
        XCTAssertTrue(visibleNode.isAccessible)
        XCTAssertEqual(warning.category, .permissionDenied)
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testLocalizedChildEnumerationFailureKeepsReadableSiblings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableDirectoryURL = rootURL.appending(path: "Readable", directoryHint: .isDirectory)
        let readableFileURL = readableDirectoryURL.appending(path: "nested.txt")
        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let lockedURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: readableDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockedURL, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: readableFileURL)
        try Data("visible".utf8).write(to: visibleFileURL)

        let permissionError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let enumeratedLockedURL = lockedURL.withUnsafeFileSystemRepresentation { path -> URL? in
            guard let path, let resolvedPath = realpath(path, nil) else { return nil }
            defer { free(resolvedPath) }
            return URL(filePath: String(cString: resolvedPath), directoryHint: .isDirectory)
        } ?? lockedURL
        let engine = ScanEngine(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return ScanEngine.DirectoryEnumerationResult(
                    urls: [readableDirectoryURL, visibleFileURL],
                    localizedFailures: [
                        ScanEngine.DirectoryEnumerationFailure(
                            url: enumeratedLockedURL,
                            error: permissionError,
                            isDirectoryHint: true
                        )
                    ]
                )
            }

            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
            return ScanEngine.DirectoryEnumerationResult(urls: urls)
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )

        let rootChildNames = rootChildren(in: snapshot).map(\.name)
        let readableNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Readable" }))
        let visibleNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let lockedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let warning = try XCTUnwrap(snapshot.scanWarnings.first(where: { $0.path == lockedURL.path }))

        XCTAssertEqual(Set(rootChildNames), Set(["Locked", "Readable", "visible.txt"]))
        XCTAssertEqual(children(of: readableNode, in: snapshot).map(\.name), ["nested.txt"])
        XCTAssertTrue(visibleNode.isAccessible)
        XCTAssertTrue(lockedNode.isDirectory)
        XCTAssertFalse(lockedNode.isAccessible)
        XCTAssertFalse(containsChildren(lockedNode, in: snapshot))
        XCTAssertEqual(warning.category, .permissionDenied)
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
    }

    func testPackageLeafExcludesHiddenContentsWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let visibleFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let hiddenFileURL = packageURL.appending(path: "Contents/Resources/.secret")

        try FileManager.default.createDirectory(at: visibleFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 256).write(to: hiddenFileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(includeHiddenFiles: false)
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 128)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 128)
    }

    func testExcludesBasenameDirectoryLikeNodeModules() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let nodeModulesFileURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: "left-pad/index.js")

        try FileManager.default.createDirectory(at: nodeModulesFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 16).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 128).write(to: nodeModulesFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["visible.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 16)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testExcludesFilesByGlob() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 32)
            .write(to: rootURL.appending(path: "notes.txt"))
        try Data(repeating: 0x2, count: 256)
            .write(to: rootURL.appending(path: "debug.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["notes.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 32)
    }

    func testExcludesDirectoryOnlyPatternsWithoutExcludingSameNamedFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "nested", directoryHint: .isDirectory)
            .appending(path: "build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 256).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 32).write(to: rootURL.appending(path: "build"))

        var options = ScanOptions()
        options.exclusionPatterns = ["build/"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let nestedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "nested" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["build", "nested"])
        XCTAssertTrue(children(of: nestedNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 32)
    }

    func testExcludesPathGlobPatternsRelativeToScanRoot() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let libraryCacheFileURL = rootURL
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: "ignored.bin")
        let topLevelCacheFileURL = rootURL
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "kept.bin")

        try FileManager.default.createDirectory(at: libraryCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topLevelCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: libraryCacheFileURL)
        try Data(repeating: 0x2, count: 64).write(to: topLevelCacheFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["Library/Caches/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let cachesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Caches" }))
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        XCTAssertEqual(children(of: cachesNode, in: snapshot).map(\.name), ["kept.bin"])
        XCTAssertTrue(children(of: libraryNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 64)
    }

    func testExcludesDoubleStarPathGlobPatterns() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "project/build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        let keptFileURL = rootURL
            .appending(path: "project/Sources", directoryHint: .isDirectory)
            .appending(path: "main.swift")

        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 128).write(to: keptFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["**/build/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let projectNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "project" }))

        XCTAssertEqual(children(of: projectNode, in: snapshot).map(\.name), ["Sources"])
        XCTAssertEqual(projectNode.descendantFileCount, 1)
        XCTAssertEqual(projectNode.logicalSize, 128)
    }

    func testExcludesDSStoreEvenWhenHiddenFilesAreIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 24)
            .write(to: rootURL.appending(path: "visible.txt"))
        try Data(repeating: 0x2, count: 512)
            .write(to: rootURL.appending(path: ".DS_Store"))

        var options = ScanOptions(includeHiddenFiles: true)
        options.exclusionPatterns = [".DS_Store"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["visible.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 24)
    }

    func testSkipsCloudStorageFolderByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "GoogleDrive-example", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name).sorted(), ["Library", "local.txt"])
        XCTAssertTrue(children(of: libraryNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 64)
    }

    func testCloudStorageFolderCanBeIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "Dropbox", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.includeCloudStorage = true
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let cloudStorageNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "CloudStorage" }))
        let providerNode = try XCTUnwrap(children(of: cloudStorageNode, in: snapshot).first(where: { $0.name == "Dropbox" }))

        XCTAssertEqual(children(of: providerNode, in: snapshot).map(\.name), ["remote.bin"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 576)
    }

    func testSkipsICloudDriveFolderByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let iCloudDriveURL = rootURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let cloudFileURL = iCloudDriveURL
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.iCloudDriveRootPath = iCloudDriveURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name).sorted(), ["Library", "local.txt"])
        XCTAssertTrue(children(of: libraryNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 64)
    }

    func testICloudDriveFolderCanBeIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let iCloudDriveURL = rootURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let cloudFileURL = iCloudDriveURL
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.includeCloudStorage = true
        options.iCloudDriveRootPath = iCloudDriveURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let iCloudDriveNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Mobile Documents" }))
        let providerNode = try XCTUnwrap(children(of: iCloudDriveNode, in: snapshot).first(where: { $0.name == "com~apple~CloudDocs" }))

        XCTAssertEqual(children(of: providerNode, in: snapshot).map(\.name), ["remote.bin"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 576)
    }

    func testUsersCloudStorageWildcardIsSkippedByDefault() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage"
        )

        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage"), isDirectory: true))
        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"), isDirectory: false))
        XCTAssertFalse(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorageBackup"), isDirectory: true))

        let explicitMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users/alex/Library/CloudStorage",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage"
        )

        XCTAssertFalse(explicitMatcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"), isDirectory: false))
    }

    func testUsersICloudDriveWildcardIsSkippedByDefault() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents"), isDirectory: true))
        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false))
        XCTAssertFalse(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents Backup"), isDirectory: true))

        let includingMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: true,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertFalse(includingMatcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false))

        let explicitMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users/alex/Library/Mobile Documents",
            includeCloudStorage: false,
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertFalse(explicitMatcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false))
    }

    func testExplicitCloudStorageFolderScanIsAllowedByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "Dropbox", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: cloudStorageURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["Dropbox"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 512)
    }

    func testVolumeScanWithExclusionsDoesNotAddSystemUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 128)
            .write(to: rootURL.appending(path: "visible.txt"))

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options
        )

        XCTAssertFalse(rootChildren(in: snapshot).contains(where: \.isSynthetic))
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 128)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testVolumeScanWithCloudStorageExclusionDoesNotAddSystemUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")

        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options
        )

        XCTAssertFalse(rootChildren(in: snapshot).contains(where: \.isSynthetic))
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testExcludedFilesDoNotContributeToParentSizeTotals() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataURL = rootURL.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 10)
            .write(to: dataURL.appending(path: "keep.bin"))
        try Data(repeating: 0x2, count: 90)
            .write(to: dataURL.appending(path: "ignored.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let dataNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Data" }))

        XCTAssertEqual(children(of: dataNode, in: snapshot).map(\.name), ["keep.bin"])
        XCTAssertEqual(dataNode.descendantFileCount, 1)
        XCTAssertEqual(dataNode.logicalSize, 10)
        XCTAssertEqual(snapshot.root.logicalSize, 10)
    }

    func testExcludedFilesDoNotContributeThroughPackageSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let keptFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let excludedFileURL = packageURL.appending(path: "Contents/Resources/debug.log")

        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excludedFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: keptFileURL)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 128)
        XCTAssertEqual(snapshot.root.logicalSize, 128)
    }

    func testExcludedPackageContentsStillEmitSummaryProgress() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let excludedFileURL = packageURL.appending(path: "debug.log")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let engine = ScanEngine()
        var summaryProgress: [ScanMetrics] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                if metrics.atomicSummaryVisitedItems > 0 {
                    summaryProgress.append(metrics)
                }
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning:
                break
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 0)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
        XCTAssertTrue(summaryProgress.contains { $0.currentPath.contains("/Sample.app") })
        XCTAssertTrue(summaryProgress.contains { $0.atomicSummaryVisitedItems >= 1 })
    }

    func testPackageSummaryProgressTracksVisitedAndEstimatedRemainingWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Progress.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data([UInt8(index % 256)]).write(
                to: packageURL.appending(path: String(format: "payload-%04d.dat", index))
            )
        }

        let engine = ScanEngine(atomicSummaryProgressEmissionInterval: 0)
        var progressMetrics: [ScanMetrics] = []
        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressMetrics.append(metrics)
            }
        }

        let summaryMetrics = progressMetrics.filter { $0.atomicSummaryVisitedItems > 0 }
        XCTAssertGreaterThanOrEqual(summaryMetrics.count, 2)
        XCTAssertEqual(summaryMetrics.map(\.atomicSummaryVisitedItems).max(), 300)
        XCTAssertTrue(summaryMetrics.contains { $0.atomicSummaryEstimatedRemainingItems > 0 })
        XCTAssertTrue(summaryMetrics.contains { $0.activeAtomicSummaryCount == 1 })
        for pair in zip(progressMetrics, progressMetrics.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.progressFraction, pair.0.progressFraction)
        }
        XCTAssertEqual(try XCTUnwrap(progressMetrics.last).progressFraction, 1, accuracy: 0.0001)
    }

    func testExcludedFilesDoNotContributeThroughAutoSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<10 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "keep.tmp"))
            try Data(repeating: 0x7F, count: 4_096)
                .write(to: shardURL.appending(path: "ignored.log"))
        }

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 10)
        XCTAssertEqual(cacheNode.logicalSize, 10 * 32)
    }

    func testCancellingScanStopsPackageLeafSummaryWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let packageContentsURL = rootURL
            .appending(path: "Large.app", directoryHint: .isDirectory)
            .appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageContentsURL, withIntermediateDirectories: true)

        for index in 0..<8_000 {
            let fileURL = packageContentsURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await scanTask.value

        XCTAssertFalse(didFinishCancelledScan)

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(followUpFinished)
    }

    func testCancellingScanStopsWideDirectoryEnumerationWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        for index in 0..<10_000 {
            let fileURL = rootURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }

        XCTAssertFalse(didFinishCancelledScan)

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(followUpFinished)
    }

    func testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let probe = BlockingDirectoryContentsProbe(blockedURL: rootURL)
        let engine = ScanEngine(directoryContents: { url, _, _, _ in
            try probe.contents(for: url)
        })
        let blockedScanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
            return didFinish
        }
        defer {
            probe.release()
            blockedScanTask.cancel()
        }

        try await probe.waitUntilBlocked()
        blockedScanTask.cancel()

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        probe.release()
        let blockedScanFinished = await blockedScanTask.value

        XCTAssertTrue(followUpFinished)
        XCTAssertFalse(blockedScanFinished)
    }

    func testEnumeratedDirectoryContentsChecksCancellationBeforeMaterializingAllURLs() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cancellation = DirectoryEnumerationCancellation()
        let enumerator = SlowDirectoryObjectEnumerator(rootURL: rootURL, totalCount: 10_000)
        let enumerationTask = Task {
            try ScanEngine.enumeratedDirectoryContents(
                url: rootURL,
                keys: nil,
                options: [],
                cancellationCheck: { try cancellation.check() },
                makeEnumerator: { _, _, _ in enumerator }
            )
        }

        try await enumerator.waitUntilProduced(64)
        cancellation.cancel()

        do {
            _ = try await withTimeout(.seconds(1)) {
                try await enumerationTask.value
            }
            XCTFail("Expected directory enumeration to stop after cancellation.")
        } catch is CancellationError {
            XCTAssertLessThan(enumerator.producedCount, enumerator.totalCount)
        }
    }

    func testCancellingScanStopsInjectedDirectoryEnumerationBeforeMaterialization() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let probe = CancellableDirectoryContentsProbe(totalCount: 10_000)
        let engine = ScanEngine(directoryContents: { url, _, _, cancellationCheck in
            guard url == rootURL else { return [] }
            return try probe.contents(for: url, cancellationCheck: cancellationCheck)
        })
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await probe.waitUntilProduced(64)
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(1)) {
            try await scanTask.value
        }

        XCTAssertFalse(didFinishCancelledScan)
        XCTAssertLessThan(probe.producedCount, probe.totalCount)
    }

    func testSymbolicLinksAreNotTraversed() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let nestedFile = realDirectory.appending(path: "payload.txt")
        let symlinkURL = rootURL.appending(path: "Alias")

        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nestedFile)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let aliasNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alias" }))

        XCTAssertTrue(aliasNode.isSymbolicLink)
        XCTAssertFalse(containsChildren(aliasNode, in: snapshot))
        XCTAssertEqual(aliasNode.itemKind, "Alias")
        XCTAssertEqual(aliasNode.descendantFileCount, 0)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testHardLinkedFilesOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let linkedURL = rootURL.appending(path: "linked.bin")

        try Data(repeating: 0xA5, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)
        let allocatedSizes = children.map(\.allocatedSize)

        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
        XCTAssertEqual(children.map(\.logicalSize).reduce(0, +), 8_192)
        XCTAssertEqual(allocatedSizes.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(snapshot.root.allocatedSize, allocatedSizes.reduce(0, +))
        XCTAssertTrue(children.allSatisfy { $0.fileIdentity != nil })
        XCTAssertEqual(children.map(\.linkCount), [2, 2])
        XCTAssertEqual(children.filter { $0.allocatedSize == 0 }.map(\.unduplicatedAllocatedSize).count, 1)
        XCTAssertTrue(children.allSatisfy { $0.unduplicatedAllocatedSize > 0 })
    }

    func testAPFSClonedFilesOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let clonedURL = rootURL.appending(path: "cloned.bin")

        try Data(repeating: 0xC3, count: 4 * 1_024 * 1_024).write(to: originalURL)
        try cloneFileOrSkip(at: originalURL, to: clonedURL)

        let metadataLoader = ScanMetadataLoader()
        let originalMetadata = try metadataLoader.metadata(for: originalURL)
        let clonedMetadata = try metadataLoader.metadata(for: clonedURL)
        XCTAssertEqual(originalMetadata.linkCount, 1)
        XCTAssertEqual(clonedMetadata.linkCount, 1)
        XCTAssertNotEqual(originalMetadata.fileIdentity, clonedMetadata.fileIdentity)
        XCTAssertGreaterThan(originalMetadata.allocatedSize, 0)
        XCTAssertEqual(clonedMetadata.allocatedSize, originalMetadata.allocatedSize)
        XCTAssertNotNil(originalMetadata.cloneIdentity)
        XCTAssertEqual(clonedMetadata.cloneIdentity, originalMetadata.cloneIdentity)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)
        let allocatedSizes = children.map(\.allocatedSize)

        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
        XCTAssertEqual(children.map(\.logicalSize).reduce(0, +), 8 * 1_024 * 1_024)
        XCTAssertEqual(allocatedSizes.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(snapshot.root.allocatedSize, originalMetadata.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertEqual(children.filter { $0.allocatedSize == 0 }.map(\.unduplicatedAllocatedSize).count, 1)
        XCTAssertTrue(children.allSatisfy { $0.unduplicatedAllocatedSize > 0 })

        let owner = try XCTUnwrap(children.first(where: { $0.allocatedSize > 0 }))
        let snapshotWithoutOwner = try XCTUnwrap(snapshot.removingNode(id: owner.id))
        let remainingClone = try XCTUnwrap(rootChildren(in: snapshotWithoutOwner).first)
        XCTAssertEqual(remainingClone.allocatedSize, remainingClone.unduplicatedAllocatedSize)
        XCTAssertEqual(snapshotWithoutOwner.root.allocatedSize, remainingClone.allocatedSize)
    }

    func testAPFSClonePreservesUniqueResourceForkAllocation() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "a-original.bin")
        let clonedURL = rootURL.appending(path: "z-clone.bin")

        try Data(repeating: 0xC3, count: 4 * 1_024 * 1_024).write(to: originalURL)
        try cloneFileOrSkip(at: originalURL, to: clonedURL)
        try setExtendedAttribute(
            named: "com.apple.ResourceFork",
            data: Data(repeating: 0x5A, count: 256 * 1_024),
            at: clonedURL
        )

        let metadataLoader = ScanMetadataLoader()
        let originalMetadata = try metadataLoader.metadata(for: originalURL)
        let clonedMetadata = try metadataLoader.metadata(for: clonedURL)
        XCTAssertEqual(clonedMetadata.cloneIdentity, originalMetadata.cloneIdentity)
        XCTAssertGreaterThan(clonedMetadata.allocatedSize, clonedMetadata.dataAllocatedSize)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let cloneNode = try XCTUnwrap(
            rootChildren(in: snapshot).first(where: { $0.url == clonedURL })
        )
        let expectedCloneAllocation = clonedMetadata.allocatedSize - clonedMetadata.dataAllocatedSize
        let expectedTotal = originalMetadata.allocatedSize + expectedCloneAllocation

        XCTAssertEqual(cloneNode.allocatedSize, expectedCloneAllocation)
        XCTAssertGreaterThan(cloneNode.allocatedSize, 0)
        XCTAssertEqual(snapshot.root.allocatedSize, expectedTotal)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, expectedTotal)
    }

    func testModifiedAPFSCloneRetainsAllocatedStorage() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let clonedURL = rootURL.appending(path: "cloned.bin")

        try Data(repeating: 0x5D, count: 4 * 1_024 * 1_024).write(to: originalURL)
        try cloneFileOrSkip(at: originalURL, to: clonedURL)
        let clonedFile = try FileHandle(forWritingTo: clonedURL)
        defer { try? clonedFile.close() }
        try clonedFile.seek(toOffset: 2 * 1_024 * 1_024)
        try clonedFile.write(contentsOf: Data(repeating: 0xA7, count: 4_096))
        try clonedFile.synchronize()

        let metadataLoader = ScanMetadataLoader()
        XCTAssertNil(try metadataLoader.metadata(for: originalURL).cloneIdentity)
        XCTAssertNil(try metadataLoader.metadata(for: clonedURL).cloneIdentity)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)

        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
        XCTAssertTrue(children.allSatisfy { $0.allocatedSize > 0 })
        XCTAssertEqual(snapshot.root.allocatedSize, children.map(\.allocatedSize).reduce(0, +))
    }

    func testParallelTraversalAssignsHardLinkStorageDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alphaDirectoryURL = rootURL.appending(path: "Alpha", directoryHint: .isDirectory)
        let betaDirectoryURL = rootURL.appending(path: "Beta", directoryHint: .isDirectory)
        let alphaLinkURL = alphaDirectoryURL.appending(path: "linked.bin")
        let betaOriginalURL = betaDirectoryURL.appending(path: "original.bin")

        try FileManager.default.createDirectory(at: alphaDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaDirectoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x4B, count: 4_096).write(to: betaOriginalURL)
        try FileManager.default.linkItem(at: betaOriginalURL, to: alphaLinkURL)

        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return [alphaDirectoryURL, betaDirectoryURL]
            }
            if url == betaDirectoryURL {
                return [betaOriginalURL]
            }
            if url == alphaDirectoryURL {
                Thread.sleep(forTimeInterval: 0.04)
                try cancellationCheck()
                return [alphaLinkURL]
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 2
        options.directoryClassificationWorkerLimit = 1

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: engine
        )
        let alphaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alpha" }))
        let betaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Beta" }))
        let alphaFile = try XCTUnwrap(children(of: alphaNode, in: snapshot).first)
        let betaFile = try XCTUnwrap(children(of: betaNode, in: snapshot).first)

        XCTAssertGreaterThan(alphaFile.allocatedSize, 0)
        XCTAssertEqual(betaFile.allocatedSize, 0)
        XCTAssertEqual(alphaNode.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(betaNode.allocatedSize, 0)
        XCTAssertEqual(snapshot.root.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
    }

    func testParallelTraversalAssignsAPFSCloneStorageDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alphaDirectoryURL = rootURL.appending(path: "Alpha", directoryHint: .isDirectory)
        let betaDirectoryURL = rootURL.appending(path: "Beta", directoryHint: .isDirectory)
        let alphaCloneURL = alphaDirectoryURL.appending(path: "cloned.bin")
        let betaOriginalURL = betaDirectoryURL.appending(path: "original.bin")

        try FileManager.default.createDirectory(at: alphaDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaDirectoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x81, count: 4 * 1_024 * 1_024).write(to: betaOriginalURL)
        try cloneFileOrSkip(at: betaOriginalURL, to: alphaCloneURL)

        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return [alphaDirectoryURL, betaDirectoryURL]
            }
            if url == betaDirectoryURL {
                return [betaOriginalURL]
            }
            if url == alphaDirectoryURL {
                Thread.sleep(forTimeInterval: 0.04)
                try cancellationCheck()
                return [alphaCloneURL]
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 2
        options.directoryClassificationWorkerLimit = 1

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: engine
        )
        let alphaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alpha" }))
        let betaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Beta" }))
        let alphaFile = try XCTUnwrap(children(of: alphaNode, in: snapshot).first)
        let betaFile = try XCTUnwrap(children(of: betaNode, in: snapshot).first)

        XCTAssertGreaterThan(alphaFile.allocatedSize, 0)
        XCTAssertEqual(betaFile.allocatedSize, 0)
        XCTAssertEqual(alphaNode.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(betaNode.allocatedSize, 0)
        XCTAssertEqual(snapshot.root.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
    }

    func testScanTargetNormalizesSyntheticRootAliases() {
        let nofollowTarget = ScanTarget(url: URL(filePath: "/.nofollow/Users/example", directoryHint: .isDirectory))
        let resolveTarget = ScanTarget(url: URL(filePath: "/.resolve/System/Volumes/Data", directoryHint: .isDirectory))
        let rootAliasTarget = ScanTarget(url: URL(filePath: "/.nofollow", directoryHint: .isDirectory))

        XCTAssertEqual(nofollowTarget.url.path, "/Users/example")
        XCTAssertEqual(resolveTarget.url.path, "/System/Volumes/Data")
        XCTAssertEqual(rootAliasTarget.url.path, "/")
        XCTAssertEqual(rootAliasTarget.kind, .volume)
    }

    func testScanTargetResolvesSymlinkRoots() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let symlinkURL = rootURL.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let target = ScanTarget(url: symlinkURL)

        XCTAssertEqual(target.url.path, realDirectory.path)
        XCTAssertEqual(target.id, realDirectory.path)
    }

    func testStartupVolumeScanExcludesSyntheticAndDuplicateNamespaces() {
        let startupBehavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        let standardBehavior = ScanEngine.ScanBehavior.standard

        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.nofollow", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.resolve", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/System/Library", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
    }

    func testVolumeSnapshotAddsSystemAndUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")
        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let engine = ScanEngine(volumeFileSystemTypeProvider: { _ in "hfs" })
        let target = ScanTarget(url: rootURL, kind: .volume)
        var options = ScanOptions()
        options.includeCloudStorage = true
        options.cloudStorageRootPath = cloudStorageURL.path
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: target, options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let syntheticNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: \.isSynthetic))

        XCTAssertEqual(syntheticNode.name, "System & Unattributed")
        XCTAssertTrue(syntheticNode.isAccessible)
        XCTAssertTrue(snapshot.root.isAccessible)
        XCTAssertFalse(syntheticNode.supportsFileActions)
        XCTAssertEqual(syntheticNode.logicalSize, 0)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.totalAllocatedSize, rootChildren(in: snapshot).filter { !$0.isSynthetic }.reduce(0) { $0 + $1.allocatedSize })
    }

    func testVolumeSnapshotReconcilesWhenCloudStorageIsExcluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let engine = ScanEngine(volumeFileSystemTypeProvider: { _ in "hfs" })
        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options,
            engine: engine
        )
        let syntheticNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: \.isSynthetic))

        XCTAssertEqual(syntheticNode.name, "Excluded & Unattributed")
        XCTAssertNotNil(snapshot.volumeCapacity)
        XCTAssertGreaterThanOrEqual(snapshot.root.allocatedSize, snapshot.volumeCapacity?.usedCapacity ?? 0)
        XCTAssertNil(snapshot.treeStore.node(id: cloudFileURL.path))
    }

    func testRemovingVolumeNodeTransfersItsAllocationToUnattributedStorage() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: ScanOptions(),
            engine: ScanEngine(volumeFileSystemTypeProvider: { _ in "hfs" })
        )
        let originalUsedSize = snapshot.root.allocatedSize
        let originalRemainder = try XCTUnwrap(rootChildren(in: snapshot).first(where: \.isSynthetic))
        let fileNode = try XCTUnwrap(snapshot.treeStore.node(id: fileURL.path))

        let updated = try XCTUnwrap(snapshot.removingNode(id: fileURL.path))
        let updatedRemainder = try XCTUnwrap(rootChildren(in: updated).first(where: \.isSynthetic))

        XCTAssertEqual(updated.root.allocatedSize, originalUsedSize)
        XCTAssertEqual(updatedRemainder.allocatedSize, originalRemainder.allocatedSize + fileNode.allocatedSize)
        XCTAssertEqual(updatedRemainder.logicalSize, 0)
    }

    func testCapacityReconciliationPolicyExcludesAllAPFSVolumes() {
        XCTAssertFalse(
            ScanEngine.shouldReconcileVolumeCapacity(
                fileSystemType: " APFS "
            )
        )
        XCTAssertFalse(
            ScanEngine.shouldReconcileVolumeCapacity(
                fileSystemType: "apfs"
            )
        )
        XCTAssertTrue(
            ScanEngine.shouldReconcileVolumeCapacity(
                fileSystemType: "hfs"
            )
        )
    }

    func testStartupVolumeFirmlinksSkipDescriptorIdentityVerification() {
        let startupBehavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        let standardBehavior = ScanEngine.ScanBehavior.standard

        XCTAssertFalse(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/Applications", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/usr/local", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/Applications", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
    }

    func testAPFSVolumeSnapshotKeepsScannedAllocatedTotal() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x5A, count: 1_024).write(to: rootURL.appending(path: "payload.bin"))

        let engine = ScanEngine(volumeFileSystemTypeProvider: { _ in "apfs" })
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: ScanOptions(),
            engine: engine
        )
        let children = rootChildren(in: snapshot)

        XCTAssertFalse(children.contains(where: \.isSynthetic))
        XCTAssertEqual(snapshot.root.allocatedSize, children.reduce(0) { $0 + $1.allocatedSize })
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testDirectoryChildrenAreOrderedDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alpha = rootURL.appending(path: "alpha.txt")
        let zeta = rootURL.appending(path: "zeta.txt")

        try Data(repeating: 0x41, count: 16).write(to: zeta)
        try Data(repeating: 0x42, count: 16).write(to: alpha)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["alpha.txt", "zeta.txt"])
    }

    func testParallelDirectoryClassificationMatchesSerialClassification() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "file-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: (index % 7) + 1).write(to: fileURL)
        }

        for index in 0..<16 {
            let directoryURL = rootURL.appending(path: String(format: "folder-%03d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 9).write(to: directoryURL.appending(path: "payload.txt"))
        }

        try Data(repeating: 0xA, count: 64).write(to: rootURL.appending(path: "excluded.log"))

        var serialOptions = ScanOptions()
        serialOptions.exclusionPatterns = ["*.log"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.exclusionPatterns = ["*.log"]
        parallelOptions.directoryTraversalWorkerLimit = 1
        parallelOptions.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertFalse(rootChildren(in: parallelSnapshot).contains(where: { $0.name == "excluded.log" }))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.isAccessible, serialSnapshot.root.isAccessible)
        XCTAssertEqual(parallelSnapshot.root.isSelfAccessible, serialSnapshot.root.isSelfAccessible)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
    }

    func testParallelDirectoryTraversalAndClassificationMatchSerialScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "root-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: 8 + (index % 11)).write(to: fileURL)
        }

        for directoryIndex in 0..<8 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<160 {
                let fileURL = directoryURL.appending(path: String(format: "payload-%03d.bin", fileIndex))
                try Data(repeating: UInt8((directoryIndex + fileIndex) % 256), count: 4 + (fileIndex % 5)).write(to: fileURL)
            }

            try Data(repeating: 0xD, count: 32).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        serialOptions.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.directoryTraversalWorkerLimit = 4
        parallelOptions.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
        XCTAssertFalse(parallelSnapshot.treeStore.nodesByID.keys.contains { $0.hasSuffix("ignored.skip") })

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            XCTAssertEqual(children(of: parallelChild, in: parallelSnapshot).map(\.name), children(of: serialChild, in: serialSnapshot).map(\.name))
            XCTAssertEqual(parallelChild.isAccessible, serialChild.isAccessible)
            XCTAssertEqual(parallelChild.isSelfAccessible, serialChild.isSelfAccessible)
        }
    }

    func testParallelDirectoryTraversalMatchesSerialTraversal() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<12 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<6 {
                let fileURL = directoryURL.appending(path: String(format: "direct-%02d.dat", fileIndex))
                try Data(repeating: UInt8(directoryIndex + fileIndex), count: 32 + directoryIndex + fileIndex).write(to: fileURL)
            }

            for nestedIndex in 0..<4 {
                let nestedURL = directoryURL.appending(path: String(format: "nested-%02d", nestedIndex), directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

                for fileIndex in 0..<3 {
                    let fileURL = nestedURL.appending(path: String(format: "payload-%02d.bin", fileIndex))
                    try Data(repeating: UInt8(nestedIndex + fileIndex), count: 17 + nestedIndex + fileIndex).write(to: fileURL)
                }
            }

            try Data(repeating: 0xC, count: 128).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        serialOptions.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.directoryTraversalWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            XCTAssertEqual(children(of: parallelChild, in: parallelSnapshot).map(\.name), children(of: serialChild, in: serialSnapshot).map(\.name))
        }
        XCTAssertFalse(parallelSnapshot.treeStore.nodesByID.keys.contains { $0.hasSuffix("ignored.skip") })
    }

    func testDuplicateAssemblyChildrenAreCollapsedBeforeDirectoryTotals() {
        let kept = makeScanEngineFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeScanEngineFileNode(id: kept.id, name: "dropped.txt", size: 50)
        let sibling = makeScanEngineFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 7)

        let uniqueChildren = ScanEngine.uniqueNodesForAssembly([kept, dropped, sibling])
        let directory = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: uniqueChildren,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        XCTAssertEqual(uniqueChildren.map(\.name), ["kept.txt", "sibling.txt"])
        XCTAssertEqual(directory.allocatedSize, 12)
        XCTAssertEqual(directory.logicalSize, 12)
        XCTAssertEqual(directory.descendantFileCount, 2)
    }

    func testProgressFractionIsMonotonicAndCompletes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<3 {
            let directoryURL = rootURL.appending(path: "Folder-\(directoryIndex)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<4 {
                let fileURL = directoryURL.appending(path: "File-\(fileIndex).txt")
                try Data(repeating: UInt8(fileIndex), count: 1_024).write(to: fileURL)
            }
        }

        let engine = ScanEngine()
        var progressFractions: [Double] = []

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressFractions.append(metrics.progressFraction)
            }
        }

        XCTAssertFalse(progressFractions.isEmpty)
        XCTAssertEqual(try XCTUnwrap(progressFractions.last), 1, accuracy: 0.0001)

        for pair in zip(progressFractions, progressFractions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1, pair.0)
        }
    }

    func testInFlightAtomicSummaryWorkFoldsIntoTraversalProgress() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 1
        metrics.completedTraversalWeight = 0.2
        metrics.atomicSummaryCompletedTraversalWeight = 0.3
        metrics.atomicSummaryCompletedItems = 0.5

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, 0.5 * 0.95, accuracy: 0.0001)
    }

    func testCommittedSummaryWeightIsExemptFromCountCap() {
        var metrics = ScanMetrics()
        // A package-heavy root (like /Applications): the packages' contents never
        // enter the item counts, so the frontier extrapolation sees almost no item
        // completions. Weight committed by summarized leaves must bypass the cap or
        // progress pins near zero while nearly all of the real work finishes.
        metrics.filesVisited = 200_000
        metrics.discoveredItems = 46
        metrics.completedItems = 20
        metrics.enumeratedDirectoryCount = 1
        metrics.pendingDirectoryCount = 4
        metrics.discoveredDirectoryCount = 45
        metrics.completedTraversalWeight = 0.45
        metrics.completedSummaryTraversalWeight = 0.44
        metrics.atomicSummaryCompletedTraversalWeight = 0.1

        metrics.recalculateProgress()

        // Weight fraction 0.55 wins because the count cap is lifted by the 0.54 of
        // summary-carried weight; without the exemption the cap would pin this at ~2%.
        XCTAssertEqual(metrics.progressFraction, 0.55 * 0.95, accuracy: 0.0001)
    }

    func testCountCapStillBindsPlainTraversalWeight() {
        var metrics = ScanMetrics()
        // Same skewed tree as below, plus a sliver of committed summary weight: the
        // cap must still bind the plain traversal weight, shifted only by the
        // summary-carried share.
        metrics.filesVisited = 2_000
        metrics.discoveredItems = 2_001
        metrics.completedItems = 2_000
        metrics.enumeratedDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 2_000.0 / 2_008.0
        metrics.completedSummaryTraversalWeight = 0.05

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.40)
    }

    func testInFlightAtomicSummaryItemsParticipateInCountCap() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 10
        metrics.completedItems = 2
        metrics.enumeratedDirectoryCount = 1
        metrics.completedTraversalWeight = 0.9
        metrics.atomicSummaryCompletedItems = 0.5

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, 0.35 * 0.95, accuracy: 0.0001)
    }

    func testFinalizationProgressIsEmittedDuringAssembly() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<700 {
            let directoryURL = rootURL.appending(path: "Folder-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let engine = ScanEngine()
        var finalizingProgress: [ScanMetrics] = []
        var didFinish = false

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            switch event {
            case .progress(let metrics) where metrics.isFinalizing:
                finalizingProgress.append(metrics)
            case .finished:
                didFinish = true
            case .progress, .warning:
                break
            }
        }

        XCTAssertTrue(didFinish)
        XCTAssertGreaterThanOrEqual(finalizingProgress.count, 2)

        for pair in zip(finalizingProgress, finalizingProgress.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.progressFraction, pair.0.progressFraction)
        }
    }

    func testEmptyDirectoryScanProducesEmptyRootNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        XCTAssertTrue(snapshot.root.isDirectory)
        XCTAssertEqual(snapshot.root.url.path, rootURL.path)
        XCTAssertTrue(rootChildren(in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.aggregateStats.directoryCount, 1)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 0)
    }

    func testEmptySubdirectoryIsRetainedInTree() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let emptyDirectoryURL = rootURL.appending(path: "Empty", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.txt")

        try FileManager.default.createDirectory(at: emptyDirectoryURL, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let emptyNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Empty" }))
        XCTAssertTrue(emptyNode.isDirectory)
        XCTAssertTrue(children(of: emptyNode, in: snapshot).isEmpty)
        XCTAssertEqual(emptyNode.descendantFileCount, 0)
    }

    func testByteEstimatePreventsPrematureFinalizingProgress() {
        var metrics = ScanMetrics()
        metrics.estimatedTotalBytes = 10_000
        metrics.discoveredItems = 6
        metrics.completedItems = 5
        metrics.filesVisited = 500
        metrics.bytesDiscovered = 1_200

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.5)
        XCTAssertFalse(metrics.isFinalizing)
    }

    func testTraversalWeightDrivesProgressWithoutByteEstimate() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 10
        metrics.completedTraversalWeight = 0.5

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, 0.5 * 0.95, accuracy: 0.0001)
    }

    func testDirectoryScanProgressStaysLowWhenLittleWeightIsCompleted() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 5_000
        metrics.discoveredItems = 5_200
        metrics.completedItems = 5_000
        metrics.bytesDiscovered = 50_000_000_000
        metrics.completedTraversalWeight = 0.02

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.05)
    }

    func testFrontierExtrapolationCapsProgressInSkewedTrees() {
        var metrics = ScanMetrics()
        // 2,000 flat files completed; one giant unexplored sibling directory remains.
        // The weight model alone would report ~99% here.
        metrics.filesVisited = 2_000
        metrics.discoveredItems = 2_001
        metrics.completedItems = 2_000
        metrics.enumeratedDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 2_000.0 / 2_008.0

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.35)
    }

    func testItemCountCapAppliesWhenFrontierDrainsButFilesRemain() {
        var metrics = ScanMetrics()
        // 1,000 sibling files completed, then one directory was enumerated and yielded
        // 5,000 flat files (no subdirectories), draining the frontier to zero. Most of the
        // discovered files are still unprocessed, but the weight model alone reports ~94%
        // because the 1,000 completed files held nearly all of the root's split weight.
        metrics.filesVisited = 1_000
        metrics.discoveredItems = 6_001
        metrics.completedItems = 1_000
        metrics.enumeratedDirectoryCount = 2
        metrics.pendingDirectoryCount = 0
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 1_000.0 / 1_008.0

        metrics.recalculateProgress()

        // The item-count cap, (completed + enumerated) / discovered ≈ 0.167, must hold the
        // bar near the true ~17% rather than letting the weight estimate jump to ~94%.
        XCTAssertLessThan(metrics.progressFraction, 0.30)
    }

    func testVolumeByteEstimateBlendsWithTraversalWeight() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.estimatedTotalBytes = 1_000
        metrics.bytesDiscovered = 500
        metrics.completedTraversalWeight = 0.3

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, ((0.3 + 0.5) / 2) * 0.95, accuracy: 0.0001)
    }

    func testFinalizationProgressMapsAboveTraversalSpan() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.completedTraversalWeight = 1
        metrics.recalculateProgress()

        metrics.isFinalizing = true
        metrics.finalizationFraction = 0.5
        metrics.recalculateProgress()
        XCTAssertEqual(metrics.progressFraction, 0.97, accuracy: 0.0001)

        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        XCTAssertEqual(metrics.progressFraction, 0.99, accuracy: 0.0001)

        metrics.recalculateProgress(isComplete: true)
        XCTAssertEqual(metrics.progressFraction, 1, accuracy: 0.0001)
    }

    func testDirectoryBelowThresholdNotAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory with small files — well below the default 5,000-file threshold
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 100 small files — below the default 5,000 threshold
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)  // 64 bytes each
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        // The cache directory should NOT be auto-summarized (only 100 files, below threshold)
        // This test verifies the mechanism doesn't trigger at low file counts
        let cacheNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with only 100 files should not be auto-summarized")
        XCTAssertTrue(cacheNode.isDirectory)
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
    }

    func testAutoSummarizedDirectoryShowsFileCount() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a regular file for comparison
        let fileURL = rootURL.appending(path: "document.txt")
        try Data("Hello, World!".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let fileNode = try XCTUnwrap(rootChildren(in: snapshot).first)
        XCTAssertFalse(fileNode.isAutoSummarized)
        XCTAssertEqual(fileNode.itemKind, "File")
        XCTAssertNil(fileNode.secondaryStatusText)
    }

    func testAutoSummarizeCanBeDisabledViaOptions() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a deep directory structure
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create many small files
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)
        }

        // Scan with autoSummarize disabled
        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        // Even with many files, the directory should NOT be auto-summarized
        let cacheNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized)
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(children(of: cacheNode, in: snapshot).count, 100)
    }

    func testCoreSimulatorDirectoryIsAutoSummarizedDespiteSparseImmediateChildren() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let coreSimulatorURL = rootURL.appending(
            path: "Library/Developer/CoreSimulator",
            directoryHint: .isDirectory
        )
        let appDataURL = coreSimulatorURL
            .appending(path: "Devices/00000000-0000-0000-0000-000000000001/data/Containers/Data/Application")
            .appending(path: "Example.appdata", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)

        for index in 0..<3 {
            try Data(repeating: UInt8(index), count: 128)
                .write(to: appDataURL.appending(path: "payload-\(index).bin"))
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let developerNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Developer" }))
        let coreSimulatorNode = try XCTUnwrap(children(of: developerNode, in: snapshot).first(where: { $0.name == "CoreSimulator" }))

        XCTAssertTrue(coreSimulatorNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(coreSimulatorNode, in: snapshot))
        XCTAssertEqual(coreSimulatorNode.descendantFileCount, 3)
        XCTAssertGreaterThanOrEqual(coreSimulatorNode.logicalSize, 384)
    }

    func testDirectoryIsAutoSummarizedWithLowThresholds() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2: rootURL/projects/cache/
        // Depth 0 = rootURL, depth 1 = projects, depth 2 = cache
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 20 small files — enough to trigger with low thresholds
        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)  // 32 bytes each
        }

        // Use low thresholds: min 10 files, max 256 bytes average, min depth 2
        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized, "Directory should be auto-summarized with low thresholds")
        XCTAssertFalse(containsChildren(cacheNode, in: snapshot), "Auto-summarized directory should have no children")
        XCTAssertEqual(cacheNode.descendantFileCount, 20, "Should report correct file count")
        XCTAssertEqual(cacheNode.itemKind, "Summarized")
        XCTAssertEqual(cacheNode.secondaryStatusText, "Summarized (20 files)")
    }

    func testDeepTinyFileDirectoryIsAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(cacheNode.descendantFileCount, 12)
    }

    #if DEBUG
    func testSuccessfulAtomicProbeResumesTraversalState() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<12 {
            let shardURL = rootURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "payload.bin"))
        }

        let diagnostics = ScanDiagnostics(environment: [
            "RADIX_SCAN_DIAGNOSTICS_LIMIT": "20",
            "RADIX_SCAN_DIAGNOSTICS_SLOW_MS": "0"
        ])
        let metadataLoader = ScanMetadataLoader(diagnostics: diagnostics)
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let rootEntries = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )).entries
        let summarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            diagnostics: diagnostics
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: [],
            rootURL: rootURL,
            includeCloudStorage: true
        )
        var progressContinuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let progressStream = AsyncThrowingStream<ScanProgressEvent, Error> { continuation in
            progressContinuation = continuation
        }
        defer { progressContinuation.finish() }
        var metrics = ScanMetrics()
        var emissionState = ScanEmissionState()

        let summary = try await summarizer.summaryIfNeeded(
            url: rootURL,
            childEntries: rootEntries,
            metadata: rootMetadata,
            includeHiddenFiles: true,
            treatPackagesAsDirectories: false,
            isNodeDependencyLayout: false,
            minFileCount: 10,
            maxAverageFileSize: 256,
            workerLimit: 4,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: {},
            metrics: &metrics,
            continuation: progressContinuation,
            emissionState: &emissionState
        )
        _ = progressStream

        XCTAssertEqual(summary?.descendantFileCount, 12)
        XCTAssertEqual(summary?.logicalSize, 384)
        let report = diagnostics.makeReport(targetPath: rootURL.path, elapsedSeconds: 0)
        XCTAssertTrue(report.contains("atomic.summary.resumed_probe"))
        let cursorOpenLine = try XCTUnwrap(
            report.split(separator: "\n").first { $0.contains("bulk.cursor.open: ") }
        )
        XCTAssertTrue(cursorOpenLine.contains("count=13"))
    }
    #endif

    func testResumedAtomicProbeMatchesFullSummarySemantics() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var shardURLs: [URL] = []
        for index in 0..<14 {
            let shardURL = rootURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            shardURLs.append(shardURL)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "payload.bin"))
        }
        let originalURL = shardURLs[0].appending(path: "original.bin")
        let linkedURL = shardURLs[13].appending(path: "linked.bin")
        try Data(repeating: 0xA5, count: 64).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)
        try Data(repeating: 0xEE, count: 4_096).write(to: shardURLs[1].appending(path: "ignored.tmp"))
        try Data(repeating: 0xDD, count: 2_048).write(to: shardURLs[2].appending(path: ".hidden.bin"))
        try FileManager.default.createSymbolicLink(
            at: shardURLs[3].appending(path: "cycle"),
            withDestinationURL: rootURL
        )

        let metadataLoader = ScanMetadataLoader()
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let rootEntries = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: false,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )).entries
        let summarizer = AtomicDirectorySummarizer(metadataLoader: metadataLoader)
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: ["*.tmp"],
            rootURL: rootURL,
            includeCloudStorage: true
        )
        var progressContinuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let progressStream = AsyncThrowingStream<ScanProgressEvent, Error> { continuation in
            progressContinuation = continuation
        }
        defer { progressContinuation.finish() }
        var referenceMetrics = ScanMetrics()
        var referenceEmissionState = ScanEmissionState()
        var resumedSerialMetrics = ScanMetrics()
        var resumedSerialEmissionState = ScanEmissionState()
        var resumedMetrics = ScanMetrics()
        var resumedEmissionState = ScanEmissionState()

        let reference = try await summarizer.summarize(
            at: rootURL,
            includeHiddenFiles: false,
            treatPackagesAsDirectories: false,
            workerLimit: 1,
            ownerNodeID: rootURL.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: {},
            metrics: &referenceMetrics,
            continuation: progressContinuation,
            emissionState: &referenceEmissionState
        )
        let resumed = try await summarizer.summaryIfNeeded(
            url: rootURL,
            childEntries: rootEntries,
            metadata: rootMetadata,
            includeHiddenFiles: false,
            treatPackagesAsDirectories: false,
            isNodeDependencyLayout: false,
            minFileCount: 10,
            maxAverageFileSize: 256,
            workerLimit: 4,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: {},
            metrics: &resumedMetrics,
            continuation: progressContinuation,
            emissionState: &resumedEmissionState
        )
        let resumedSerial = try await summarizer.summaryIfNeeded(
            url: rootURL,
            childEntries: rootEntries,
            metadata: rootMetadata,
            includeHiddenFiles: false,
            treatPackagesAsDirectories: false,
            isNodeDependencyLayout: false,
            minFileCount: 10,
            maxAverageFileSize: 256,
            workerLimit: 1,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: {},
            metrics: &resumedSerialMetrics,
            continuation: progressContinuation,
            emissionState: &resumedSerialEmissionState
        )
        _ = progressStream

        XCTAssertEqual(resumed?.descendantFileCount, reference?.descendantFileCount)
        XCTAssertEqual(resumed?.logicalSize, reference?.logicalSize)
        XCTAssertEqual(resumed?.allocatedSize, reference?.allocatedSize)
        XCTAssertEqual(resumed?.isAccessible, reference?.isAccessible)
        XCTAssertEqual(resumed?.warnings.count, reference?.warnings.count)
        let hardLinkIdentity = try XCTUnwrap(metadataLoader.metadata(for: originalURL).fileIdentity)
        XCTAssertEqual(
            resumed?.hardLinkAccumulator.winner(for: hardLinkIdentity)?.path,
            reference?.hardLinkAccumulator.winner(for: hardLinkIdentity)?.path
        )
        XCTAssertEqual(
            resumed?.hardLinkAccumulator.duplicateAllocatedSizeByOwner,
            reference?.hardLinkAccumulator.duplicateAllocatedSizeByOwner
        )
        XCTAssertEqual(resumed?.hardLinkAccumulator.identityCount, 1)
        XCTAssertEqual(resumedSerial?.descendantFileCount, resumed?.descendantFileCount)
        XCTAssertEqual(resumedSerial?.logicalSize, resumed?.logicalSize)
        XCTAssertEqual(resumedSerial?.allocatedSize, resumed?.allocatedSize)
        XCTAssertEqual(
            resumedSerial?.hardLinkAccumulator.winner(for: hardLinkIdentity)?.path,
            resumed?.hardLinkAccumulator.winner(for: hardLinkIdentity)?.path
        )
        XCTAssertEqual(
            resumedSerial?.hardLinkAccumulator.duplicateAllocatedSizeByOwner,
            resumed?.hardLinkAccumulator.duplicateAllocatedSizeByOwner
        )
    }

    func testNodeModulesPnpmStoreAutoSummarizesAtShallowDepth() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/left-pad@1.3.0/node_modules/left-pad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: packageURL.appending(path: "file-\(index).js"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertTrue(nodeModulesNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(nodeModulesNode, in: snapshot))
        XCTAssertEqual(nodeModulesNode.descendantFileCount, 20)
    }

    func testScopedNodePackageContainerAutoSummarizesAtShallowDepth() async throws {
        let nodeModulesURL = try makeTemporaryDirectory().appending(path: "node_modules", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: nodeModulesURL.deletingLastPathComponent()) }

        let packageURL = nodeModulesURL
            .appending(path: "@radix-ui/colors/dist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 24)
                .write(to: packageURL.appending(path: "token-\(index).js"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: nodeModulesURL),
            options: options
        )

        let scopeNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "@radix-ui" }))
        XCTAssertTrue(scopeNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(scopeNode, in: snapshot))
        XCTAssertEqual(scopeNode.descendantFileCount, 20)
    }

    func testNestedNodeModulesForestAutoSummarizesThroughSparseParent() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nodeModulesURL = rootURL
            .appending(path: "workspace/packages/app/node_modules", directoryHint: .isDirectory)
        let packageURL = nodeModulesURL
            .appending(path: "vite/dist/client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 40)
                .write(to: packageURL.appending(path: "chunk-\(index).js"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let workspaceNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "workspace" }))
        let packagesNode = try XCTUnwrap(children(of: workspaceNode, in: snapshot).first(where: { $0.name == "packages" }))
        let appNode = try XCTUnwrap(children(of: packagesNode, in: snapshot).first(where: { $0.name == "app" }))
        let nodeModulesNode = try XCTUnwrap(children(of: appNode, in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertTrue(nodeModulesNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(nodeModulesNode, in: snapshot))
        XCTAssertEqual(nodeModulesNode.descendantFileCount, 20)
    }

    func testSparseAncestorDefersAutoSummarizationToDenseDescendant() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        let denseURL = cacheURL.appending(path: "dense", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: denseURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: denseURL.appending(path: "payload-\(index).tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        let denseNode = try XCTUnwrap(children(of: cacheNode, in: snapshot).first(where: { $0.name == "dense" }))

        XCTAssertFalse(cacheNode.isAutoSummarized)
        XCTAssertTrue(denseNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(denseNode, in: snapshot))
        XCTAssertEqual(denseNode.descendantFileCount, 20)
    }

    func testAutoSummarizedDirectoryIncludesPackageLeafContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        let packageBinaryURL = cacheURL
            .appending(path: "Tool.app", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Tool")
        try FileManager.default.createDirectory(at: packageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: packageBinaryURL)

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 13)
        XCTAssertGreaterThanOrEqual(cacheNode.logicalSize, (12 * 32) + 2_048)
    }

    func testAutoSummarizedDirectoryCountsAsSingleVisitedDirectory() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var finalMetrics = ScanMetrics()

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .progress(let metrics) = event {
                finalMetrics = metrics
            }
        }

        XCTAssertEqual(finalMetrics.directoriesVisited, 3)
        XCTAssertEqual(finalMetrics.filesVisited, 20)
    }

    func testAutoSummarizedDirectoryReleasesChildDirectoryDiscoveryCounts() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var progressSnapshots: [ScanMetrics] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                progressSnapshots.append(metrics)
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning:
                break
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let finalMetrics = try XCTUnwrap(progressSnapshots.last)
        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(finalMetrics.enumeratedDirectoryCount, 3)
        XCTAssertEqual(finalMetrics.discoveredDirectoryCount, 3)
        XCTAssertEqual(finalMetrics.pendingDirectoryCount, 0)
        XCTAssertEqual(finalMetrics.progressFraction, 1, accuracy: 0.0001)
    }

    func testDirectoryNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2 with 20 LARGE files
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).dat")
            try Data(repeating: UInt8(i % 256), count: 100_000).write(to: fileURL)  // 100 KB each
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 4_096  // 4 KB max average
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with large files should not be auto-summarized")
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(children(of: cacheNode, in: snapshot).count, 20)
    }

    func testNodeDependencyLayoutNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/large-payload@1.0.0/node_modules/large-payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 8_192)
                .write(to: packageURL.appending(path: "asset-\(index).dat"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertFalse(nodeModulesNode.isAutoSummarized)
        XCTAssertTrue(containsChildren(nodeModulesNode, in: snapshot))
    }

    func testAutoSummarizedDirectoryExcludesHiddenFilesWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        for i in 0..<3 {
            let hiddenFileURL = cacheURL.appending(path: ".hidden_\(i).tmp")
            try Data(repeating: 0x7F, count: 32).write(to: hiddenFileURL)
        }

        var options = ScanOptions(includeHiddenFiles: false)
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 12)
        XCTAssertEqual(cacheNode.logicalSize, 12 * 32)
    }
}

private final class BlockingLiveChildOpen: @unchecked Sendable {
    let didReachChildOpen = DispatchSemaphore(value: 0)
    private let allowChildOpen = DispatchSemaphore(value: 0)
    private let releaseLock = NSLock()
    private var isReleased = false

    var systemCalls: ScanDirectoryDescriptorPool.SystemCalls {
        let live = ScanDirectoryDescriptorPool.SystemCalls.live
        return ScanDirectoryDescriptorPool.SystemCalls(
            openRoot: live.openRoot,
            openChild: { [didReachChildOpen, allowChildOpen] parentDescriptor, name in
                didReachChildOpen.signal()
                allowChildOpen.wait()
                return live.openChild(parentDescriptor, name)
            },
            fileIdentity: live.fileIdentity,
            close: live.close
        )
    }

    func release() {
        releaseLock.lock()
        guard !isReleased else {
            releaseLock.unlock()
            return
        }
        isReleased = true
        releaseLock.unlock()
        allowChildOpen.signal()
    }
}

private func finishedSnapshot(
    target: ScanTarget,
    options: ScanOptions,
    engine: ScanEngine = ScanEngine()
) async throws -> ScanSnapshot {
    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }

    XCTFail("Expected scan to produce a final snapshot")
    throw CancellationError()
}

private func rootChildren(in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: snapshot.root.id)
}

private func children(of node: FileNodeRecord, in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: node.id)
}

private func containsChildren(_ node: FileNodeRecord, in snapshot: ScanSnapshot) -> Bool {
    snapshot.treeStore.containsChildren(id: node.id)
}

private func cloneFileOrSkip(at sourceURL: URL, to destinationURL: URL) throws {
    let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
        destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
            guard let sourcePath, let destinationPath else {
                errno = EINVAL
                return Int32(-1)
            }
            return clonefile(sourcePath, destinationPath, 0)
        }
    }
    guard result == 0 else {
        let errorCode = errno
        if errorCode == ENOTSUP || errorCode == EXDEV {
            throw XCTSkip("APFS file cloning is unavailable in the test environment")
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
    }
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

private func makeScanEngineFileNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private enum AsyncTestTimeout: Error {
    case timedOut
}

private final class DirectoryEnumerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = isCancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

private final class BlockingAtomicSummaryWorkerProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeOwners: Set<String> = []
    private var seenOwners: Set<String> = []
    private var activeWorkers = 0
    private var peakWorkers = 0
    private var maximumDistinctOwners = 0
    private var isReleased = false

    var activeWorkerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeWorkers
    }

    var peakActiveWorkerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return peakWorkers
    }

    var activeOwnerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeOwners.count
    }

    var seenOwnerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return seenOwners.count
    }

    var maximumDistinctActiveOwnerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumDistinctOwners
    }

    func didStart(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        condition.lock()
        activeWorkers += 1
        peakWorkers = max(peakWorkers, activeWorkers)
        activeOwners.insert(ownerNodeID)
        seenOwners.insert(ownerNodeID)
        maximumDistinctOwners = max(maximumDistinctOwners, activeOwners.count)
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func didFinish(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        condition.lock()
        activeWorkers = max(activeWorkers - 1, 0)
        activeOwners.remove(ownerNodeID)
        condition.broadcast()
        condition.unlock()
    }

    func waitForDistinctActiveOwners(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while activeOwners.count < count, Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        return activeOwners.count >= count
    }

    func releaseAll() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class CancellationAfterChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingChecks: Int

    init(_ remainingChecks: Int) {
        self.remainingChecks = remainingChecks
    }

    func check() throws {
        lock.lock()
        remainingChecks -= 1
        let shouldCancel = remainingChecks == 0
        lock.unlock()
        if shouldCancel {
            throw CancellationError()
        }
    }
}

private final class SlowDirectoryObjectEnumerator: ScanEngine.DirectoryObjectEnumerating, @unchecked Sendable {
    let totalCount: Int
    private let rootURL: URL
    private let lock = NSLock()
    private var nextIndex = 0

    init(rootURL: URL, totalCount: Int) {
        self.rootURL = rootURL
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func nextObject() -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < totalCount else { return nil }
        let childURL = rootURL.appending(path: "payload-\(nextIndex).tmp")
        nextIndex += 1
        Thread.sleep(forTimeInterval: 0.0005)
        return childURL
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory object enumeration.", file: file, line: line)
    }
}

private final class CancellableDirectoryContentsProbe: @unchecked Sendable {
    let totalCount: Int
    private let lock = NSLock()
    private var produced = 0

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return produced
    }

    func contents(
        for url: URL,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(totalCount)

        for index in 0..<totalCount {
            if index.isMultiple(of: 8) {
                try cancellationCheck()
            }
            recordProducedChild()
            Thread.sleep(forTimeInterval: 0.0005)
            urls.append(url.appending(path: "payload-\(index).tmp"))
        }

        return urls
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory contents production.", file: file, line: line)
    }

    private func recordProducedChild() {
        lock.lock()
        produced += 1
        lock.unlock()
    }
}

private final class BlockingDirectoryContentsProbe: @unchecked Sendable {
    private let blockedURL: URL
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    init(blockedURL: URL) {
        self.blockedURL = blockedURL
    }

    func contents(for url: URL) throws -> [URL] {
        guard url == blockedURL else { return [] }

        condition.lock()
        defer { condition.unlock() }
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        return []
    }

    func waitUntilBlocked(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if blocked {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory contents blocking.", file: file, line: line)
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    private var blocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }
}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: duration)
            throw AsyncTestTimeout.timedOut
        }

        guard let result = try await group.next() else {
            throw AsyncTestTimeout.timedOut
        }
        group.cancelAll()
        return result
    }
}
