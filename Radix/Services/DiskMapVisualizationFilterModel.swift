//
//  DiskMapVisualizationFilterModel.swift
//  Radix
//

import Combine
import Foundation

typealias DiskMapVisualizationFilterOperation = @Sendable (
    _ baseInput: DiskMapVisualizationInput,
    _ hiddenNodeIDs: [FileNodeRecord.ID],
    _ layoutIDComponent: String
) async throws -> DiskMapVisualizationInput

@MainActor
final class DiskMapVisualizationFilterModel: ObservableObject {
    @Published private var cachedResult: DiskMapVisualizationFilterResult?
    @Published private(set) var isFiltering = false

    private let filterOperation: DiskMapVisualizationFilterOperation
    private var pendingRequest: DiskMapVisualizationFilterRequest?
    private var filterTask: Task<Void, Never>?

    init(
        filterOperation: @escaping DiskMapVisualizationFilterOperation = DiskMapVisualizationFilterModel.filteredInput
    ) {
        self.filterOperation = filterOperation
    }

    deinit {
        filterTask?.cancel()
    }

    func input(
        baseInput: DiskMapVisualizationInput,
        request: DiskMapVisualizationFilterRequest
    ) -> DiskMapVisualizationInput {
        guard request.requiresFiltering else {
            return baseInput
        }

        if let cachedResult,
           cachedResult.request == request || cachedResult.request.hasSameBase(as: request) {
            return cachedResult.input
        }

        return baseInput
    }

    func isInputPending(for request: DiskMapVisualizationFilterRequest) -> Bool {
        request.requiresFiltering && cachedResult?.request != request
    }

    func update(
        baseInput: DiskMapVisualizationInput,
        request: DiskMapVisualizationFilterRequest
    ) {
        guard request.requiresFiltering else {
            clearFilter()
            return
        }

        if cachedResult?.request == request {
            cancelPendingFilter()
            return
        }

        if pendingRequest != request {
            startFiltering(baseInput: baseInput, request: request)
        }
    }

    private func startFiltering(
        baseInput: DiskMapVisualizationInput,
        request: DiskMapVisualizationFilterRequest
    ) {
        let previousTask = filterTask
        previousTask?.cancel()
        pendingRequest = request
        setIsFiltering(true)

        filterTask = Task { [weak self, filterOperation] in
            do {
                await previousTask?.value
                try Task.checkCancellation()
                let input = try await filterOperation(
                    baseInput,
                    request.hiddenNodeIDs,
                    request.discardPileLayoutComponent
                )
                self?.cache(input, for: request)
            } catch is CancellationError {
                self?.clearPendingFilter(for: request)
            } catch {
                self?.clearPendingFilter(for: request)
            }
        }
    }

    private func cache(
        _ input: DiskMapVisualizationInput,
        for request: DiskMapVisualizationFilterRequest
    ) {
        guard pendingRequest == request else { return }
        cachedResult = DiskMapVisualizationFilterResult(request: request, input: input)
        pendingRequest = nil
        filterTask = nil
        setIsFiltering(false)
    }

    private func clearPendingFilter(for request: DiskMapVisualizationFilterRequest) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
        filterTask = nil
        setIsFiltering(false)
    }

    private func clearFilter() {
        guard pendingRequest != nil || cachedResult != nil || isFiltering else { return }
        cancelPendingFilter()
        cachedResult = nil
    }

    private func cancelPendingFilter() {
        guard pendingRequest != nil || isFiltering else { return }
        filterTask?.cancel()
        // Keep the cancelled task as a drain barrier for the next request.
        pendingRequest = nil
        setIsFiltering(false)
    }

    private func setIsFiltering(_ isFiltering: Bool) {
        guard self.isFiltering != isFiltering else { return }
        self.isFiltering = isFiltering
    }

    private nonisolated static func filteredInput(
        baseInput: DiskMapVisualizationInput,
        hiddenNodeIDs: [FileNodeRecord.ID],
        layoutIDComponent: String
    ) async throws -> DiskMapVisualizationInput {
        let worker = Task.detached(priority: .userInitiated) {
            let filteredStore = try baseInput.treeStore.removingSubtrees(
                rootedAt: hiddenNodeIDs,
                cancellationCheck: Task.checkCancellation
            )
            return DiskMapVisualizationInput(
                rootNode: filteredStore.node(id: baseInput.rootNode.id) ?? filteredStore.root,
                treeStore: filteredStore,
                treeContentID: filteredStore.contentID,
                layoutIDComponent: [
                    baseInput.layoutIDComponent,
                    layoutIDComponent,
                ].joined(separator: "|")
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private nonisolated struct DiskMapVisualizationFilterResult {
    let request: DiskMapVisualizationFilterRequest
    let input: DiskMapVisualizationInput
}

nonisolated struct DiskMapVisualizationFilterRequest: Equatable, Sendable {
    let snapshotID: UUID
    let focusNodeID: FileNodeRecord.ID
    let rootNodeID: FileNodeRecord.ID
    let baseTreeContentID: UUID
    let baseLayoutIDComponent: String
    let hiddenNodeIDs: [FileNodeRecord.ID]

    init(
        baseInput: DiskMapVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>
    ) {
        self.snapshotID = snapshotID
        self.focusNodeID = focusNodeID
        rootNodeID = baseInput.rootNode.id
        baseTreeContentID = baseInput.treeContentID
        baseLayoutIDComponent = baseInput.layoutIDComponent
        self.hiddenNodeIDs = hiddenNodeIDs.sorted()
    }

    nonisolated var requiresFiltering: Bool {
        !hiddenNodeIDs.isEmpty
    }

    nonisolated var discardPileLayoutComponent: String {
        hiddenNodeIDs.reduce("discard-pile:\(hiddenNodeIDs.count)") { component, id in
            component + ":\(id.count):\(id)"
        }
    }

    nonisolated func hasSameBase(as other: Self) -> Bool {
        snapshotID == other.snapshotID
            && focusNodeID == other.focusNodeID
            && rootNodeID == other.rootNodeID
            && baseTreeContentID == other.baseTreeContentID
            && baseLayoutIDComponent == other.baseLayoutIDComponent
    }
}
