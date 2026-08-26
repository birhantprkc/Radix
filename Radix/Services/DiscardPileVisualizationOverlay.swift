import Foundation

nonisolated struct DiscardPileVisualizationPresentation: Sendable {
    let visualizationInput: DiskMapVisualizationInput
    let layoutID: String
    let queuedNodeIDs: Set<FileNodeRecord.ID>

    init(
        snapshot: ScanSnapshot,
        focusNode: FileNodeRecord,
        showFreeSpace: Bool,
        availableCapacity: Int64?,
        maxRenderedDepth: Int,
        queuedNodeIDs: Set<FileNodeRecord.ID>
    ) {
        let visualizationInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: focusNode,
            showFreeSpace: showFreeSpace,
            availableCapacity: availableCapacity
        )
        self.visualizationInput = visualizationInput
        layoutID = [
            snapshot.id.uuidString,
            focusNode.id,
            visualizationInput.rootNode.id,
            visualizationInput.treeContentID.uuidString,
            String(maxRenderedDepth),
            visualizationInput.layoutIDComponent,
        ].joined(separator: "|")
        self.queuedNodeIDs = queuedNodeIDs
    }
}

nonisolated enum DiscardPileVisualizationOverlayRole: Equatable, Sendable {
    case queuedRoot
    case queuedDescendant
    case containsQueuedItem
}

/// Presentation-only state for queued Discard Pile items. It deliberately
/// derives marks from the rendered node IDs without rebuilding the scan tree or
/// chart geometry.
nonisolated struct DiscardPileVisualizationOverlay: Equatable, Sendable {
    static let empty = DiscardPileVisualizationOverlay()

    let queuedNodeIDs: Set<FileNodeRecord.ID>
    let queuedRootNodeIDs: Set<FileNodeRecord.ID>
    let containingNodeIDs: Set<FileNodeRecord.ID>

    init(
        renderedNodeIDs: Set<FileNodeRecord.ID> = [],
        renderedAggregateContainerNodeIDs: Set<FileNodeRecord.ID> = [],
        queuedRootNodeIDs: Set<FileNodeRecord.ID> = [],
        treeStore: (any DiskMapTreeReading)? = nil
    ) {
        guard !renderedNodeIDs.isEmpty || !renderedAggregateContainerNodeIDs.isEmpty,
              !queuedRootNodeIDs.isEmpty,
              let treeStore else {
            queuedNodeIDs = []
            self.queuedRootNodeIDs = []
            containingNodeIDs = []
            return
        }

        var queuedNodeIDs = Set<FileNodeRecord.ID>()
        queuedNodeIDs.reserveCapacity(min(renderedNodeIDs.count, queuedRootNodeIDs.count * 2))
        for renderedNodeID in renderedNodeIDs {
            var candidateID: FileNodeRecord.ID? = renderedNodeID
            while let currentID = candidateID {
                if queuedRootNodeIDs.contains(currentID) {
                    queuedNodeIDs.insert(renderedNodeID)
                    break
                }
                candidateID = treeStore.parentID(of: currentID)
            }
        }

        var renderedQueuedRootNodeIDs = Set<FileNodeRecord.ID>()
        renderedQueuedRootNodeIDs.reserveCapacity(queuedRootNodeIDs.count)
        for queuedNodeID in queuedNodeIDs {
            var candidateID = treeStore.parentID(of: queuedNodeID)
            var hasRenderedQueuedAncestor = false
            while let currentID = candidateID {
                if renderedNodeIDs.contains(currentID) {
                    hasRenderedQueuedAncestor = queuedNodeIDs.contains(currentID)
                    break
                }
                candidateID = treeStore.parentID(of: currentID)
            }
            if !hasRenderedQueuedAncestor {
                renderedQueuedRootNodeIDs.insert(queuedNodeID)
            }
        }

        var containingNodeIDs = Set<FileNodeRecord.ID>()
        containingNodeIDs.reserveCapacity(queuedRootNodeIDs.count)
        for queuedRootNodeID in queuedRootNodeIDs {
            guard treeStore.node(id: queuedRootNodeID) != nil,
                  !renderedNodeIDs.contains(queuedRootNodeID) else {
                continue
            }

            var candidateID = treeStore.parentID(of: queuedRootNodeID)
            while let currentID = candidateID {
                if renderedNodeIDs.contains(currentID)
                    || renderedAggregateContainerNodeIDs.contains(currentID) {
                    if !queuedNodeIDs.contains(currentID) {
                        containingNodeIDs.insert(currentID)
                    }
                    break
                }
                candidateID = treeStore.parentID(of: currentID)
            }
        }

        self.queuedNodeIDs = queuedNodeIDs
        self.queuedRootNodeIDs = renderedQueuedRootNodeIDs
        self.containingNodeIDs = containingNodeIDs
    }

    func role(for nodeID: FileNodeRecord.ID?) -> DiscardPileVisualizationOverlayRole? {
        guard let nodeID else { return nil }
        if queuedRootNodeIDs.contains(nodeID) {
            return .queuedRoot
        }
        if queuedNodeIDs.contains(nodeID) {
            return .queuedDescendant
        }
        if containingNodeIDs.contains(nodeID) {
            return .containsQueuedItem
        }
        return nil
    }

    func role(
        for nodeID: FileNodeRecord.ID?,
        aggregateContainerNodeID: FileNodeRecord.ID?
    ) -> DiscardPileVisualizationOverlayRole? {
        role(for: nodeID) ?? role(for: aggregateContainerNodeID)
    }

    func isQueued(_ nodeID: FileNodeRecord.ID?) -> Bool {
        guard let nodeID else { return false }
        return queuedNodeIDs.contains(nodeID)
    }

    func allowsChartNodeAction(for nodeID: FileNodeRecord.ID?) -> Bool {
        !isQueued(nodeID)
    }
}

nonisolated struct DiscardPileVisualizationOverlayCache {
    private struct Key: Equatable {
        let treeContentID: UUID
        let renderedLayoutVersion: Int
        let queuedRootNodeIDs: Set<FileNodeRecord.ID>
    }

    private var cached: (key: Key, overlay: DiscardPileVisualizationOverlay)?

    mutating func overlay(
        renderedLayoutVersion: Int,
        queuedRootNodeIDs: Set<FileNodeRecord.ID>,
        treeStore: DiskMapTreeStore,
        renderedNodeIDs: () -> Set<FileNodeRecord.ID>,
        renderedAggregateContainerNodeIDs: () -> Set<FileNodeRecord.ID> = { [] }
    ) -> DiscardPileVisualizationOverlay {
        let key = Key(
            treeContentID: treeStore.contentID,
            renderedLayoutVersion: renderedLayoutVersion,
            queuedRootNodeIDs: queuedRootNodeIDs
        )
        if let cached, cached.key == key {
            return cached.overlay
        }

        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: renderedNodeIDs(),
            renderedAggregateContainerNodeIDs: renderedAggregateContainerNodeIDs(),
            queuedRootNodeIDs: queuedRootNodeIDs,
            treeStore: treeStore
        )
        cached = (key, overlay)
        return overlay
    }
}
