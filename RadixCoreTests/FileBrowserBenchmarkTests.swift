import Combine
import Darwin
import Foundation
import XCTest
@testable import RadixCore

final class FileBrowserBenchmarkTests: XCTestCase {
    func testMillionNodeFileBrowserBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_FILE_BROWSER"] == "1" else {
            throw XCTSkip(
                "Set RADIX_BENCH_FILE_BROWSER=1 to run the million-node File Browser benchmark."
            )
        }

        let directoryCount = environment["RADIX_BENCH_FILE_BROWSER_DIRECTORIES"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 1_000
        let filesPerDirectory = environment["RADIX_BENCH_FILE_BROWSER_FILES_PER_DIRECTORY"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 1_000
        let warmIterationCount = environment["RADIX_BENCH_FILE_BROWSER_WARM_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3

        let initialPeakRSS = Self.peakResidentBytes()
        let fixtureMeasurement = Self.measure {
            Self.makeFixture(
                directoryCount: directoryCount,
                filesPerDirectory: filesPerDirectory
            )
        }
        let fixture = fixtureMeasurement.value
        let fixturePeakRSS = Self.peakResidentBytes()

        XCTAssertEqual(
            fixture.store.nodeCount,
            (directoryCount * filesPerDirectory) + directoryCount + 1
        )
        Self.report(
            phase: "fixture",
            seconds: fixtureMeasurement.seconds,
            count: fixture.store.nodeCount,
            peakRSS: fixturePeakRSS,
            extra: "rss_delta=\(Self.byteDelta(from: initialPeakRSS, to: fixturePeakRSS))"
        )

        let snapshotID = UUID()
        let searchService = await FileSearchService()
        let noMatchQuery = FileBrowserQuery(text: "__radix_no_match__")
        let coldMeasurement = try await Self.measureAsync {
            try await searchService.search(
                snapshotID: snapshotID,
                treeStore: fixture.store,
                query: noMatchQuery,
                sortOrder: []
            )
        }
        XCTAssertTrue(coldMeasurement.value.isEmpty)

        let warmNoMatchSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: noMatchQuery,
            sortOrder: []
        )
        let warmNoMatchMedian = Self.median(warmNoMatchSamples.map(\.seconds))
        let estimatedIndexSeconds = max(coldMeasurement.seconds - warmNoMatchMedian, 0)
        let indexedPeakRSS = Self.peakResidentBytes()
        Self.report(
            phase: "cold_index",
            seconds: estimatedIndexSeconds,
            count: fixture.store.nodeCount - 1,
            peakRSS: indexedPeakRSS,
            extra: "cold_total=\(Self.format(coldMeasurement.seconds)) " +
                "warm_scan_median=\(Self.format(warmNoMatchMedian)) " +
                "rss_delta=\(Self.byteDelta(from: fixturePeakRSS, to: indexedPeakRSS))"
        )

        let textSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: FileBrowserQuery(text: "needle"),
            sortOrder: []
        )
        let expectedNeedleCount = filesPerDirectory > 777
            ? ((directoryCount - 1) / 100) + 1
            : 0
        XCTAssertTrue(textSamples.allSatisfy { $0.resultCount == expectedNeedleCount })
        Self.reportSamples(
            phase: "warm_text",
            samples: textSamples,
            count: expectedNeedleCount
        )

        let pathDirectoryOffset = directoryCount / 2
        let pathQuery = FileBrowserQuery(
            text: String(format: "/benchmark/directory-%04d/", pathDirectoryOffset)
        )
        let firstPathMeasurement = try await Self.measureAsync {
            try await searchService.search(
                snapshotID: snapshotID,
                treeStore: fixture.store,
                query: pathQuery,
                sortOrder: []
            )
        }
        XCTAssertEqual(firstPathMeasurement.value.count, filesPerDirectory)
        let warmPathSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: pathQuery,
            sortOrder: []
        )
        XCTAssertTrue(warmPathSamples.allSatisfy { $0.resultCount == filesPerDirectory })
        Self.report(
            phase: "path_first",
            seconds: firstPathMeasurement.seconds,
            count: filesPerDirectory,
            peakRSS: Self.peakResidentBytes()
        )
        Self.reportSamples(
            phase: "path_warm",
            samples: warmPathSamples,
            count: filesPerDirectory
        )

        let filterQuery = FileBrowserQuery(itemKind: .file)
        let filterSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: filterQuery,
            sortOrder: []
        )
        XCTAssertTrue(filterSamples.allSatisfy { $0.resultCount == fixture.fileCount })
        let largeResults = try await searchService.search(
            snapshotID: snapshotID,
            treeStore: fixture.store,
            query: filterQuery,
            sortOrder: []
        )
        Self.reportSamples(
            phase: "filter_large",
            samples: filterSamples,
            count: largeResults.count
        )

        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        let sortingMeasurement = try Self.measure {
            try FileBrowserResults.sorted(
                largeResults,
                sortOrder: sortOrder,
                fileTreeStore: fixture.store,
                cancellationCheck: {}
            )
        }
        let sortedResults = sortingMeasurement.value
        let sortingPeakRSS = Self.peakResidentBytes()
        XCTAssertEqual(sortedResults.count, fixture.fileCount)
        Self.assertSorted(
            sortedResults,
            using: sortOrder,
            fileTreeStore: fixture.store
        )
        let sortFingerprint = Self.fingerprint(sortedResults)
        Self.report(
            phase: "sorting",
            seconds: sortingMeasurement.seconds,
            count: sortedResults.count,
            peakRSS: sortingPeakRSS,
            extra: "fingerprint=\(sortFingerprint)"
        )

        let publicationMeasurement = await Self.measurePublication(sortedResults)
        Self.report(
            phase: "main_actor_publication",
            seconds: publicationMeasurement,
            count: sortedResults.count,
            peakRSS: Self.peakResidentBytes()
        )

        let coldCancellation = try await Self.measureColdSearchCancellation(
            store: fixture.store,
            query: noMatchQuery
        )
        XCTAssertTrue(
            coldCancellation.wasCancelled || coldCancellation.completedBeforeCancellation,
            "Cold search returned normally after cancellation was requested."
        )
        Self.report(
            phase: "cancel_cold_search",
            seconds: coldCancellation.seconds,
            count: fixture.store.nodeCount - 1,
            peakRSS: Self.peakResidentBytes(),
            extra: "cancelled=\(coldCancellation.wasCancelled) " +
                "completed_before_cancel=\(coldCancellation.completedBeforeCancellation)"
        )

        let sortCancellation = try await Self.measureSortCancellation(
            nodes: largeResults,
            sortOrder: sortOrder,
            store: fixture.store,
            baselineSortSeconds: sortingMeasurement.seconds
        )
        XCTAssertTrue(
            sortCancellation.wasCancelled || sortCancellation.completedBeforeCancellation,
            "Sort returned normally after cancellation was requested."
        )
        Self.report(
            phase: "cancel_sort",
            seconds: sortCancellation.seconds,
            count: largeResults.count,
            peakRSS: Self.peakResidentBytes(),
            extra: "cancelled=\(sortCancellation.wasCancelled) " +
                "completed_before_cancel=\(sortCancellation.completedBeforeCancellation)"
        )

        let endToEndSeconds = try await Self.measureEndToEnd(
            fixture: fixture,
            service: searchService,
            query: filterQuery
        )
        Self.report(
            phase: "end_to_end",
            seconds: endToEndSeconds,
            count: fixture.fileCount,
            peakRSS: Self.peakResidentBytes()
        )

        Self.report(
            phase: "suite_peak_rss",
            seconds: 0,
            count: fixture.store.nodeCount,
            peakRSS: Self.peakResidentBytes(),
            extra: "rss_delta=\(Self.byteDelta(from: initialPeakRSS, to: Self.peakResidentBytes()))"
        )
    }

    private static func measureSearchSamples(
        count: Int,
        service: FileSearchService,
        snapshotID: UUID,
        store: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [SearchSample] {
        var samples: [SearchSample] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let measurement = try await measureAsync {
                try await service.search(
                    snapshotID: snapshotID,
                    treeStore: store,
                    query: query,
                    sortOrder: sortOrder
                )
            }
            samples.append(SearchSample(
                seconds: measurement.seconds,
                resultCount: measurement.value.count
            ))
        }
        return samples
    }

    @MainActor
    private static func measurePublication(_ nodes: [FileNodeRecord]) -> Double {
        let publisher = FileBrowserPublicationProbe()
        var publicationCount = 0
        let cancellable = publisher.objectWillChange.sink {
            publicationCount += 1
        }

        let startedAt = ContinuousClock.now
        publisher.publish(nodes)
        let seconds = durationSeconds(startedAt.duration(to: .now))

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(publisher.nodeCount, nodes.count)
        XCTAssertEqual(publisher.node(id: nodes[0].id)?.id, nodes[0].id)
        XCTAssertEqual(publisher.node(id: nodes[nodes.count - 1].id)?.id, nodes[nodes.count - 1].id)
        withExtendedLifetime(cancellable) {}
        return seconds
    }

    @MainActor
    private static func measureEndToEnd(
        fixture: Fixture,
        service: FileSearchService,
        query: FileBrowserQuery
    ) async throws -> Double {
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: fixture.store.root.url),
            treeStore: fixture.store,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 1),
            scanWarnings: [],
            aggregateStats: fixture.store.aggregateStats,
            isComplete: true
        )
        let model = FileBrowserModel(
            searchService: service,
            searchDebounceDuration: .zero,
            currentContentsAsyncThreshold: .max
        )
        model.updateContent(
            nodes: fixture.store.children(of: fixture.store.root.id),
            contentID: "\(snapshot.id.uuidString)|\(snapshot.root.id)",
            snapshot: snapshot,
            fileTreeStore: fixture.store
        )
        model.setSearchScope(.entireScan)

        let startedAt = ContinuousClock.now
        model.setActiveQuery(query)
        while model.isSearchingEntireScan {
            try await Task.sleep(for: .milliseconds(1))
        }
        let seconds = durationSeconds(startedAt.duration(to: .now))

        XCTAssertTrue(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.count, fixture.fileCount)
        model.cleanup()
        return seconds
    }

    private static func measureColdSearchCancellation(
        store: FileTreeStore,
        query: FileBrowserQuery
    ) async throws -> CancellationMeasurement {
        let service = await FileSearchService()
        let task = Task {
            _ = try await service.search(
                snapshotID: UUID(),
                treeStore: store,
                query: query,
                sortOrder: []
            )
            return ContinuousClock.now
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(2))

        let cancellationRequestedAt = ContinuousClock.now
        task.cancel()
        do {
            let completedAt = try await task.value
            return CancellationMeasurement(
                seconds: durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: false,
                completedBeforeCancellation: completedAt <= cancellationRequestedAt
            )
        } catch is CancellationError {
            return CancellationMeasurement(
                seconds: durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: true,
                completedBeforeCancellation: false
            )
        }
    }

    private static func measureSortCancellation(
        nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        store: FileTreeStore,
        baselineSortSeconds: Double
    ) async throws -> CancellationMeasurement {
        let task = Task.detached {
            _ = try FileBrowserResults.sorted(
                nodes,
                sortOrder: sortOrder,
                fileTreeStore: store,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
            return ContinuousClock.now
        }
        let delaySeconds = min(max(baselineSortSeconds * 0.5, 0.01), 1.5)
        try await Task.sleep(for: .seconds(delaySeconds))

        let cancellationRequestedAt = ContinuousClock.now
        task.cancel()
        do {
            let completedAt = try await task.value
            return CancellationMeasurement(
                seconds: durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: false,
                completedBeforeCancellation: completedAt <= cancellationRequestedAt
            )
        } catch is CancellationError {
            return CancellationMeasurement(
                seconds: durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: true,
                completedBeforeCancellation: false
            )
        }
    }

    private static func makeFixture(
        directoryCount: Int,
        filesPerDirectory: Int
    ) -> Fixture {
        let fileCount = directoryCount * filesPerDirectory
        let nodeCount = fileCount + directoryCount + 1
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let rootID = "/benchmark"
        var nodes = [FileNodeRecord(
            id: rootID,
            url: URL(filePath: rootID, directoryHint: .isDirectory),
            name: "benchmark",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: Int64(fileCount),
            logicalSize: Int64(fileCount),
            descendantFileCount: fileCount,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )]
        nodes.reserveCapacity(nodeCount)
        var childIndicesByIndex = Array(repeating: [FileTreeNodeIndex](), count: nodeCount)
        var parentIndices = Array<FileTreeNodeIndex?>(repeating: nil, count: nodeCount)
        var rootChildren: [FileTreeNodeIndex] = []
        rootChildren.reserveCapacity(directoryCount)

        for directoryOffset in 0..<directoryCount {
            let directoryID = String(format: "%@/directory-%04d", rootID, directoryOffset)
            let directoryIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(FileNodeRecord(
                id: directoryID,
                url: URL(filePath: directoryID, directoryHint: .isDirectory),
                name: URL(filePath: directoryID).lastPathComponent,
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: Int64(filesPerDirectory),
                logicalSize: Int64(filesPerDirectory),
                descendantFileCount: filesPerDirectory,
                lastModified: nil,
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            ))
            parentIndices[Int(directoryIndex.rawValue)] = rootIndex
            rootChildren.append(directoryIndex)

            var directoryChildren: [FileTreeNodeIndex] = []
            directoryChildren.reserveCapacity(filesPerDirectory)
            for fileOffset in 0..<filesPerDirectory {
                let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
                let name = directoryOffset.isMultiple(of: 100) && fileOffset == 777
                    ? String(format: "needle-%06d.dat", directoryOffset)
                    : String(format: "item-%04d.dat", fileOffset)
                let fileID = directoryID + "/" + name
                let sequence = (directoryOffset * filesPerDirectory) + fileOffset
                let allocatedSize = Int64(((sequence * 37) % 16_384) + 1)
                nodes.append(FileNodeRecord(
                    id: fileID,
                    url: URL(filePath: fileID),
                    name: name,
                    isDirectory: false,
                    isSymbolicLink: false,
                    allocatedSize: allocatedSize,
                    logicalSize: allocatedSize,
                    descendantFileCount: 1,
                    lastModified: Date(timeIntervalSinceReferenceDate: Double(sequence % 10_000)),
                    isPackage: false,
                    isAccessible: true,
                    isSelfAccessible: true,
                    isSynthetic: false,
                    isAutoSummarized: false
                ))
                parentIndices[Int(fileIndex.rawValue)] = directoryIndex
                directoryChildren.append(fileIndex)
            }
            childIndicesByIndex[Int(directoryIndex.rawValue)] = directoryChildren
        }
        childIndicesByIndex[0] = rootChildren

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(fileCount),
                totalLogicalSize: Int64(fileCount),
                fileCount: fileCount,
                directoryCount: directoryCount + 1,
                accessibleItemCount: nodeCount,
                inaccessibleItemCount: 0
            )
        )
        return Fixture(store: store, fileCount: fileCount)
    }

    private static func assertSorted(
        _ nodes: [FileNodeRecord],
        using sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for offset in 1..<nodes.count {
            let lhs = nodes[offset - 1]
            let rhs = nodes[offset]
            var result = ComparisonResult.orderedSame
            for comparator in sortOrder {
                result = comparator.compare(lhs, rhs, fileTreeStore: fileTreeStore)
                if result != .orderedSame {
                    break
                }
            }
            if result == .orderedSame {
                result = FileNodeSortComparison.fallback(
                    lhsName: lhs.name,
                    lhsID: lhs.id,
                    rhsName: rhs.name,
                    rhsID: rhs.id
                )
            }
            XCTAssertNotEqual(result, .orderedDescending, file: file, line: line)
        }
    }

    private static func fingerprint(_ nodes: [FileNodeRecord]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for node in nodes {
            for byte in node.id.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= UInt64(bitPattern: node.allocatedSize)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func measure<Value>(_ operation: () throws -> Value) rethrows -> Measurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try operation()
        return Measurement(
            value: value,
            seconds: durationSeconds(startedAt.duration(to: .now))
        )
    }

    private static func measureAsync<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> Measurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try await operation()
        return Measurement(
            value: value,
            seconds: durationSeconds(startedAt.duration(to: .now))
        )
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) +
            (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    private static func median(_ values: [Double]) -> Double {
        let sortedValues = values.sorted()
        let midpoint = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2
        }
        return sortedValues[midpoint]
    }

    private static func reportSamples(
        phase: String,
        samples: [SearchSample],
        count: Int
    ) {
        let seconds = samples.map(\.seconds)
        report(
            phase: phase,
            seconds: median(seconds),
            count: count,
            peakRSS: peakResidentBytes(),
            extra: "samples=\(seconds.map(format).joined(separator: ","))"
        )
    }

    private static func report(
        phase: String,
        seconds: Double,
        count: Int,
        peakRSS: UInt64,
        extra: String = ""
    ) {
        print(
            "RADIX_FILE_BROWSER_BENCH_RESULT phase=\(phase) " +
                "seconds=\(format(seconds)) count=\(count) " +
                "peak_rss=\(peakRSS) \(extra)"
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(usage.ru_maxrss, 0))
    }

    private static func byteDelta(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

@MainActor
private final class FileBrowserPublicationProbe: ObservableObject {
    @Published private var displayState = FileBrowserDisplayState()

    var nodeCount: Int {
        displayState.nodes.count
    }

    func node(id: FileNodeRecord.ID) -> FileNodeRecord? {
        displayState.node(id: id)
    }

    func publish(_ nodes: [FileNodeRecord]) {
        displayState = FileBrowserDisplayState(nodes: nodes, context: .empty)
    }
}

private struct Fixture: Sendable {
    let store: FileTreeStore
    let fileCount: Int
}

private struct Measurement<Value> {
    let value: Value
    let seconds: Double
}

private struct SearchSample {
    let seconds: Double
    let resultCount: Int
}

private struct CancellationMeasurement {
    let seconds: Double
    let wasCancelled: Bool
    let completedBeforeCancellation: Bool
}
