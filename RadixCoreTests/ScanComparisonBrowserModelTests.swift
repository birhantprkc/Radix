import XCTest
@testable import RadixCore

@MainActor
final class ScanComparisonBrowserModelTests: XCTestCase {
    func testRefreshPreservesPublishedRowsThenReconcilesSelection() async throws {
        let gate = ComparisonProcessorGate()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 0,
            processor: { input in
                await gate.process(input)
            }
        )
        let rows = [makeRow("first.txt"), makeRow("second.txt")]
        let comparisonID = UUID()

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("first"),
            changeKinds: allKinds
        )
        try await waitUntil { await gate.requestCount == 1 }
        await gate.resumeRequest(at: 0)
        try await waitUntil { model.displayedRows.map(\.name) == ["first.txt"] }

        model.selection = [rows[0].id]
        model.aggregateSelection = ["stale-aggregate-id"]
        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("second"),
            changeKinds: allKinds
        )
        try await waitUntil { await gate.requestCount == 2 }

        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.displayedRows.map(\.name), ["first.txt"])
        XCTAssertEqual(model.selection, [rows[0].id])

        await gate.resumeRequest(at: 1)
        try await waitUntil { model.displayedRows.map(\.name) == ["second.txt"] }
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.aggregateSelection.isEmpty)
    }

    func testOlderCancelledRefreshCannotOverwriteNewerResult() async throws {
        let gate = ComparisonProcessorGate()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 0,
            processor: { input in
                await gate.process(input)
            }
        )
        let rows = [makeRow("first.txt"), makeRow("second.txt")]
        let comparisonID = UUID()

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("first"),
            changeKinds: allKinds
        )
        try await waitUntil { await gate.requestCount == 1 }
        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("second"),
            changeKinds: allKinds
        )
        try await waitUntil { await gate.requestCount == 2 }

        await gate.resumeRequest(at: 1)
        try await waitUntil { model.displayedRows.map(\.name) == ["second.txt"] }
        await gate.resumeRequest(at: 0)
        await Task.yield()

        XCTAssertEqual(model.displayedRows.map(\.name), ["second.txt"])
        XCTAssertFalse(model.isRefreshing)
    }

    func testDefaultProcessorFiltersRowsAndBuildsProjection() async throws {
        let model = ScanComparisonBrowserModel(searchDebounceNanoseconds: 0)
        let rows = [makeRow("first.txt"), makeRow("second.txt")]

        model.refresh(
            comparisonID: UUID(),
            rows: rows,
            changeTree: .empty,
            query: query("second"),
            changeKinds: allKinds
        )

        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.displayedRows.map(\.name), ["second.txt"])
        XCTAssertTrue(model.projection.roots.isEmpty)
    }

    func testRapidSearchChangesDebounceSupersededQuery() async throws {
        let recorder = ComparisonProcessorRecorder()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 1,
            processor: { input in
                await recorder.process(input)
            },
            sleeper: { _ in
                await Task.yield()
                try Task.checkCancellation()
            }
        )
        let rows = [makeRow("first.txt"), makeRow("second.txt")]
        let comparisonID = UUID()

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query(""),
            changeKinds: allKinds
        )
        try await waitUntil { await recorder.searchTexts.count == 1 }

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("first"),
            changeKinds: allKinds
        )
        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("second"),
            changeKinds: allKinds
        )

        try await waitUntil { await recorder.searchTexts.count == 2 }
        let processedSearchTexts = await recorder.searchTexts
        XCTAssertEqual(processedSearchTexts, ["", "second"])
    }

    private var allKinds: Set<ScanComparisonChangeKind> {
        Set(ScanComparisonChangeKind.allCases)
    }

    private func query(_ searchText: String) -> ScanComparisonRowQuery {
        ScanComparisonRowQuery(
            searchText: searchText,
            sortOrder: [ScanComparisonRowComparator.defaultOrder]
        )
    }

    private func makeRow(_ name: String) -> ScanComparisonRow {
        let relativePath = "folder/\(name)"
        let url = URL(filePath: "/root/\(relativePath)", directoryHint: .notDirectory)
        let node = FileNodeRecord(
            id: url.path,
            url: url,
            name: name,
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
        return ScanComparisonRow(
            relativePath: relativePath,
            kind: .added,
            beforeNode: nil,
            afterNode: node
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for comparison browser state")
    }
}

private actor ComparisonProcessorGate {
    private var inputs: [ScanComparisonBrowserModel.WorkInput] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    var requestCount: Int { inputs.count }

    func process(
        _ input: ScanComparisonBrowserModel.WorkInput
    ) async -> ScanComparisonBrowserModel.WorkOutput {
        let index = inputs.count
        inputs.append(input)
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
        return ScanComparisonBrowserModel.WorkOutput(
            rows: input.query.applying(to: input.rows),
            projection: input.changeTree.significantProjection(changeKinds: input.changeKinds)
        )
    }

    func resumeRequest(at index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }
}

private actor ComparisonProcessorRecorder {
    private(set) var searchTexts: [String] = []

    func process(
        _ input: ScanComparisonBrowserModel.WorkInput
    ) -> ScanComparisonBrowserModel.WorkOutput {
        searchTexts.append(input.query.searchText)
        return ScanComparisonBrowserModel.WorkOutput(
            rows: input.query.applying(to: input.rows),
            projection: input.changeTree.significantProjection(changeKinds: input.changeKinds)
        )
    }
}
