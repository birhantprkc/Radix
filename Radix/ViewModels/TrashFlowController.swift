//
//  TrashFlowController.swift
//  Radix
//

import Combine
import Foundation

/// Owns the state machines behind trash moves and the discard pile: pending
/// confirmations, optimistic visibility during moves, post-trash snapshot
/// removal bookkeeping, and the in-flight confirmed-move task. AppModel wires
/// `onChange` to refresh dependent presentations and publish object changes.
@MainActor
final class TrashFlowController {
    struct PostTrashRemovalRequest: Sendable {
        let nodeIDs: [FileNodeRecord.ID]
        let fallbackFocusID: FileNodeRecord.ID?
    }

    struct OptimisticTrashVisibilityState: Equatable, Sendable {
        let nodeIDs: Set<FileNodeRecord.ID>
        let snapshotID: UUID?

        init(
            nodeIDs: Set<FileNodeRecord.ID> = [],
            snapshotID: UUID? = nil
        ) {
            self.nodeIDs = nodeIDs.isEmpty ? [] : nodeIDs
            self.snapshotID = nodeIDs.isEmpty ? nil : snapshotID
        }
    }

    struct PendingTrashSelection {
        let nodes: [FileNodeRecord]
        let allowsHiddenNodes: Bool

        init(
            nodes: [FileNodeRecord],
            allowsHiddenNodes: Bool = false
        ) {
            self.nodes = nodes
            self.allowsHiddenNodes = allowsHiddenNodes
        }
    }

    struct PendingCloudFileAction {
        enum Kind: Equatable {
            case addToDiscardPile
            case moveToTrash(allowsHiddenNodes: Bool)
        }

        let kind: Kind
        let nodes: [FileNodeRecord]
        let cloudImpact: CloudStorageLocation.Impact
    }

    /// Invoked on the main actor after every mutating assignment below.
    var onChange: (() -> Void)?

    var pendingTrashSelection: PendingTrashSelection? {
        didSet { notifyChanged() }
    }

    var pendingCloudFileAction: PendingCloudFileAction? {
        didSet { notifyChanged() }
    }

    @Published var discardPile: DiscardPileState {
        didSet { notifyChanged() }
    }

    var optimisticTrashVisibility = OptimisticTrashVisibilityState()

    var confirmedTrashMoveTask: Task<Void, Never>?
    var postTrashRemovalTask: Task<Void, Never>?
    var postTrashRemovalRequests: [PostTrashRemovalRequest] = []

    init(
        pendingTrashSelection: PendingTrashSelection? = nil,
        pendingCloudFileAction: PendingCloudFileAction? = nil,
        discardPile: DiscardPileState = DiscardPileState()
    ) {
        self.pendingTrashSelection = pendingTrashSelection
        self.pendingCloudFileAction = pendingCloudFileAction
        self.discardPile = discardPile
    }

    var pendingTrashNode: FileNodeRecord? {
        get {
            guard let nodes = pendingTrashSelection?.nodes, nodes.count == 1 else {
                return nil
            }
            return nodes.first
        }
        set {
            if let node = newValue {
                pendingTrashSelection = PendingTrashSelection(nodes: [node])
            } else {
                pendingTrashSelection = nil
            }
        }
    }

    func cancelConfirmedTrashMove() {
        confirmedTrashMoveTask?.cancel()
        confirmedTrashMoveTask = nil
    }

    func cancelPostTrashSnapshotRemoval() {
        postTrashRemovalRequests.removeAll()
        postTrashRemovalTask?.cancel()
        postTrashRemovalTask = nil
    }

    /// Validates trash support, reduces nodes to top-level items, and stages
    /// the pending confirmation. Throws when any node cannot be trashed.
    func stageTrashRequest(
        for nodes: [FileNodeRecord],
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        fileTreeStore: FileTreeStore?,
        allowingHiddenNodes: Bool = false
    ) throws {
        guard nodes.allSatisfy({ node in
            node.supportsMoveToTrash(
                activeTarget: activeTarget,
                trashSafetyPolicy: trashSafetyPolicy
            )
        }) else {
            throw FileActionError.unsupported
        }

        let trashNodes = Self.topLevelTrashNodes(from: nodes, fileTreeStore: fileTreeStore)
        pendingTrashSelection = PendingTrashSelection(
            nodes: trashNodes,
            allowsHiddenNodes: allowingHiddenNodes
        )
    }

    func removeDiscardPileNode(id nodeID: FileNodeRecord.ID) {
        guard discardPile.nodeIDs.contains(nodeID) else { return }
        let remainingIDs = discardPile.nodeIDs.filter { $0 != nodeID }
        discardPile = DiscardPileState(
            nodeIDs: remainingIDs,
            snapshotID: discardPile.snapshotID
        )
    }

    func clearDiscardPile() {
        guard !discardPile.isEmpty else { return }
        discardPile = DiscardPileState()
    }

    static func topLevelTrashNodes(
        from nodes: [FileNodeRecord],
        fileTreeStore: FileTreeStore?
    ) -> [FileNodeRecord] {
        guard let fileTreeStore else { return nodes }
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fileTreeStore.topLevelNodeIDs(from: nodes.map(\.id)).compactMap { nodesByID[$0] }
    }

    private func notifyChanged() {
        onChange?()
    }
}
