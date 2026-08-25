import Foundation

nonisolated struct InspectorSelectionSummary: Equatable, Sendable {
    let selectedNodes: [FileNodeRecord]
    let topLevelSelectedNodes: [FileNodeRecord]
    let allocatedSize: Int64
    let containsOverlappingSelections: Bool
    let missingSelectedNodeCount: Int

    init(selectedNodes: [FileNodeRecord], fileTreeStore: FileTreeStore?) {
        self.selectedNodes = selectedNodes

        if let fileTreeStore {
            let presentNodeIDs = selectedNodes.map(\.id).filter { fileTreeStore.node(id: $0) != nil }
            let selectedNodesByID = Dictionary(
                uniqueKeysWithValues: selectedNodes.map { ($0.id, $0) }
            )
            topLevelSelectedNodes = fileTreeStore
                .topLevelNodeIDs(from: presentNodeIDs)
                .compactMap { selectedNodesByID[$0] }
            containsOverlappingSelections = topLevelSelectedNodes.count != presentNodeIDs.count
            missingSelectedNodeCount = selectedNodes.count - presentNodeIDs.count
        } else {
            topLevelSelectedNodes = selectedNodes
            containsOverlappingSelections = false
            missingSelectedNodeCount = 0
        }

        allocatedSize = Self.total(\.allocatedSize, in: topLevelSelectedNodes)
    }

    var selectedCount: Int {
        selectedNodes.count
    }

    var topLevelSelectedCount: Int {
        topLevelSelectedNodes.count
    }

    var selectedNodesByAllocatedSize: [FileNodeRecord] {
        selectedNodes.sorted(by: Self.isOrderedBefore)
    }

    func largestSelectedNodes(limit: Int) -> [FileNodeRecord] {
        guard limit > 0 else { return [] }
        guard selectedNodes.count > limit else {
            return selectedNodesByAllocatedSize
        }

        var largest: [FileNodeRecord] = []
        largest.reserveCapacity(limit)
        for node in selectedNodes {
            let insertionIndex = largest.firstIndex { existing in
                Self.isOrderedBefore(node, existing)
            } ?? largest.endIndex
            largest.insert(node, at: insertionIndex)
            if largest.count > limit {
                largest.removeLast()
            }
        }
        return largest
    }

    var selectedFolderCount: Int {
        selectedNodes.count { $0.isDirectory && !$0.isPackage && !$0.isSynthetic }
    }

    var selectedPackageCount: Int {
        selectedNodes.count { $0.isPackage && !$0.isSynthetic }
    }

    var selectedFileCount: Int {
        selectedNodes.count { !$0.isDirectory && !$0.isPackage && !$0.isSynthetic }
    }

    var selectedStorageCategoryCount: Int {
        selectedNodes.count(where: \.isSynthetic)
    }

    var containsSharedStorageItems: Bool {
        selectedNodes.contains { $0.cloneIdentity != nil || $0.mayShareDataBlocks }
    }

    var containsKnownClones: Bool {
        selectedNodes.contains { $0.cloneIdentity != nil }
    }

    private static func total(
        _ keyPath: KeyPath<FileNodeRecord, Int64>,
        in nodes: [FileNodeRecord]
    ) -> Int64 {
        nodes.reduce(0) { total, node in
            ScanIntegerMath.addingClamped(total, node[keyPath: keyPath])
        }
    }

    private static func isOrderedBefore(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord) -> Bool {
        if lhs.allocatedSize != rhs.allocatedSize {
            return lhs.allocatedSize > rhs.allocatedSize
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
