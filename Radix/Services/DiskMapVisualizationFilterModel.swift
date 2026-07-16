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
    private var pendingKey: DiskMapVisualizationFilterKey?
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
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>
    ) -> DiskMapVisualizationInput {
        guard let key = filterKey(
            baseInput: baseInput,
            snapshotID: snapshotID,
            focusNodeID: focusNodeID,
            hiddenNodeIDs: hiddenNodeIDs
        ) else {
            return baseInput
        }

        if let cachedResult,
           cachedResult.key == key || cachedResult.key.hasSameBase(as: key) {
            return cachedResult.input
        }

        return baseInput
    }

    func isInputPending(
        baseInput: DiskMapVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>
    ) -> Bool {
        guard let key = filterKey(
            baseInput: baseInput,
            snapshotID: snapshotID,
            focusNodeID: focusNodeID,
            hiddenNodeIDs: hiddenNodeIDs
        ) else {
            return false
        }

        return cachedResult?.key != key
    }

    func update(
        baseInput: DiskMapVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>
    ) {
        guard let key = filterKey(
            baseInput: baseInput,
            snapshotID: snapshotID,
            focusNodeID: focusNodeID,
            hiddenNodeIDs: hiddenNodeIDs
        ) else {
            clearFilter()
            return
        }

        if cachedResult?.key == key {
            cancelPendingFilter()
            return
        }

        if pendingKey != key {
            startFiltering(baseInput: baseInput, key: key)
        }
    }

    private func filterKey(
        baseInput: DiskMapVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>
    ) -> DiskMapVisualizationFilterKey? {
        guard !hiddenNodeIDs.isEmpty else { return nil }

        return DiskMapVisualizationFilterKey(
            snapshotID: snapshotID,
            focusNodeID: focusNodeID,
            rootNodeID: baseInput.rootNode.id,
            baseTreeContentID: baseInput.treeContentID,
            baseLayoutIDComponent: baseInput.layoutIDComponent,
            hiddenNodeIDs: hiddenNodeIDs.sorted()
        )
    }

    private func startFiltering(
        baseInput: DiskMapVisualizationInput,
        key: DiskMapVisualizationFilterKey
    ) {
        filterTask?.cancel()
        pendingKey = key
        setIsFiltering(true)

        filterTask = Task { [weak self, filterOperation] in
            do {
                let input = try await filterOperation(
                    baseInput,
                    key.hiddenNodeIDs,
                    key.discardPileLayoutComponent
                )
                self?.cache(input, for: key)
            } catch is CancellationError {
                self?.clearPendingFilter(for: key)
            } catch {
                self?.clearPendingFilter(for: key)
            }
        }
    }

    private func cache(_ input: DiskMapVisualizationInput, for key: DiskMapVisualizationFilterKey) {
        guard pendingKey == key else { return }
        cachedResult = DiskMapVisualizationFilterResult(key: key, input: input)
        pendingKey = nil
        filterTask = nil
        setIsFiltering(false)
    }

    private func clearPendingFilter(for key: DiskMapVisualizationFilterKey) {
        guard pendingKey == key else { return }
        pendingKey = nil
        filterTask = nil
        setIsFiltering(false)
    }

    private func clearFilter() {
        guard filterTask != nil || pendingKey != nil || cachedResult != nil else { return }
        cancelPendingFilter()
        cachedResult = nil
    }

    private func cancelPendingFilter() {
        guard filterTask != nil || pendingKey != nil || isFiltering else { return }
        filterTask?.cancel()
        filterTask = nil
        pendingKey = nil
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
    let key: DiskMapVisualizationFilterKey
    let input: DiskMapVisualizationInput
}

private nonisolated struct DiskMapVisualizationFilterKey: Hashable, Sendable {
    let snapshotID: UUID
    let focusNodeID: FileNodeRecord.ID
    let rootNodeID: FileNodeRecord.ID
    let baseTreeContentID: UUID
    let baseLayoutIDComponent: String
    let hiddenNodeIDs: [FileNodeRecord.ID]

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
