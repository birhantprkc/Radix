import Combine
import Foundation

/// Owns the derived state used by the comparison browser. Expensive filtering,
/// sorting, and significant-tree projection happen away from the main actor;
/// only the latest completed request is allowed to publish.
@MainActor
final class ScanComparisonBrowserModel: ObservableObject {
    nonisolated struct WorkInput: Equatable, Sendable {
        let comparisonID: UUID
        let rows: [ScanComparisonRow]
        let changeTree: ScanComparisonChangeTree
        let query: ScanComparisonRowQuery
        let changeKinds: Set<ScanComparisonChangeKind>
    }

    nonisolated struct WorkOutput: Equatable, Sendable {
        let rows: [ScanComparisonRow]
        let projection: ScanComparisonChangeTreeProjection
    }

    typealias Processor = @Sendable (WorkInput) async throws -> WorkOutput
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    @Published private(set) var displayedRows: [ScanComparisonRow] = []
    @Published private(set) var projection = ScanComparisonChangeTreeProjection(
        roots: [],
        changeKinds: [],
        namedRootCount: 0,
        hiddenRootCount: 0,
        representedImpact: 0,
        totalImpact: 0,
        groupedAffectedCount: 0
    )
    @Published private(set) var isRefreshing = false
    @Published var selection = Set<ScanComparisonRow.ID>()
    @Published var aggregateSelection = Set<ScanComparisonChangeTreeNode.ID>()

    private let searchDebounceNanoseconds: UInt64
    private let processor: Processor
    private let sleeper: Sleeper
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var latestComparisonID: UUID?
    private var latestQuery: ScanComparisonRowQuery?
    private var latestChangeKinds: Set<ScanComparisonChangeKind>?

    init(
        searchDebounceNanoseconds: UInt64 = 200_000_000,
        processor: @escaping Processor = ScanComparisonBrowserModel.process,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
        self.processor = processor
        self.sleeper = sleeper
    }

    func refresh(
        comparisonID: UUID,
        rows: [ScanComparisonRow],
        changeTree: ScanComparisonChangeTree,
        query: ScanComparisonRowQuery,
        changeKinds: Set<ScanComparisonChangeKind>
    ) {
        guard latestComparisonID != comparisonID ||
                latestQuery != query ||
                latestChangeKinds != changeKinds else {
            return
        }

        let shouldDebounceSearch = latestComparisonID == comparisonID &&
            latestQuery?.searchText != query.searchText
        latestComparisonID = comparisonID
        latestQuery = query
        latestChangeKinds = changeKinds

        refreshTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let input = WorkInput(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: changeTree,
            query: query,
            changeKinds: changeKinds
        )
        let processor = self.processor
        let sleeper = self.sleeper
        let debounceNanoseconds = shouldDebounceSearch ? searchDebounceNanoseconds : 0
        isRefreshing = true

        refreshTask = Task { [weak self] in
            do {
                if debounceNanoseconds > 0 {
                    try await sleeper(debounceNanoseconds)
                }
                let output = try await processor(input)
                try Task.checkCancellation()
                guard let self, generation == requestGeneration else { return }

                displayedRows = output.rows
                projection = output.projection
                selection.formIntersection(output.rows.lazy.map(\.id))
                aggregateSelection = aggregateSelection.filter {
                    output.projection.node(withID: $0) != nil
                }
                isRefreshing = false
                refreshTask = nil
            } catch {
                guard let self, generation == requestGeneration else { return }
                isRefreshing = false
                refreshTask = nil
            }
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        generation &+= 1
        isRefreshing = false
    }

    private nonisolated static func process(_ input: WorkInput) async throws -> WorkOutput {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let rows = input.query.applying(to: input.rows)
            try Task.checkCancellation()
            let projection = input.changeTree.significantProjection(changeKinds: input.changeKinds)
            try Task.checkCancellation()
            return WorkOutput(rows: rows, projection: projection)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
