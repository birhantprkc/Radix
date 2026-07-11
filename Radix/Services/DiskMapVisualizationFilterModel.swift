//
//  DiskMapVisualizationFilterModel.swift
//  Radix
//

import Combine
import Foundation

@MainActor
final class DiskMapVisualizationFilterModel: ObservableObject {
    @Published private var cachedResult: DiskMapVisualizationFilterResult?

    private var pendingKey: DiskMapVisualizationFilterKey?
    private var filterTask: Task<Void, Never>?

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

        if cachedResult?.key == key {
            return cachedResult?.input ?? baseInput
        }

        return baseInput
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

        filterTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let filteredStore = try baseInput.treeStore.removingSubtrees(
                    rootedAt: key.hiddenNodeIDs,
                    cancellationCheck: Task.checkCancellation
                )
                return DiskMapVisualizationInput(
                    rootNode: filteredStore.node(id: baseInput.rootNode.id) ?? filteredStore.root,
                    treeStore: filteredStore,
                    treeContentID: filteredStore.contentID,
                    layoutIDComponent: [
                        baseInput.layoutIDComponent,
                        key.discardPileLayoutComponent
                    ].joined(separator: "|")
                )
            }

            do {
                let input = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                self?.cache(input, for: key)
            } catch is CancellationError {
                return
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
    }

    private func clearPendingFilter(for key: DiskMapVisualizationFilterKey) {
        guard pendingKey == key else { return }
        pendingKey = nil
        filterTask = nil
    }

    private func clearFilter() {
        guard filterTask != nil || pendingKey != nil || cachedResult != nil else { return }
        filterTask?.cancel()
        filterTask = nil
        pendingKey = nil
        cachedResult = nil
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
}
