import Foundation

nonisolated struct InspectorSelectionSummary: Equatable, Sendable {
    let selectedNodes: [FileNodeRecord]
    let topLevelSelectedNodes: [FileNodeRecord]
    let allocatedSize: Int64
    let containsOverlappingSelections: Bool
    let missingSelectedNodeCount: Int
    let selectedFolderCount: Int
    let selectedPackageCount: Int
    let selectedFileCount: Int
    let selectedStorageCategoryCount: Int
    let containsSharedStorageItems: Bool
    let containsKnownClones: Bool

    init(selectedNodes: [FileNodeRecord], fileTreeStore: FileTreeStore?) {
        self.selectedNodes = selectedNodes

        var presentNodeIDs: [String] = []
        var selectedNodesByID: [String: FileNodeRecord] = [:]
        if fileTreeStore != nil {
            presentNodeIDs.reserveCapacity(selectedNodes.count)
            selectedNodesByID.reserveCapacity(selectedNodes.count)
        }
        var selectedFolderCount = 0
        var selectedPackageCount = 0
        var selectedFileCount = 0
        var selectedStorageCategoryCount = 0
        var containsSharedStorageItems = false
        var containsKnownClones = false

        for node in selectedNodes {
            if node.isSynthetic {
                selectedStorageCategoryCount += 1
            } else if node.isPackage {
                selectedPackageCount += 1
            } else if node.isDirectory {
                selectedFolderCount += 1
            } else {
                selectedFileCount += 1
            }

            if node.cloneIdentity != nil {
                containsKnownClones = true
                containsSharedStorageItems = true
            } else if node.mayShareDataBlocks {
                containsSharedStorageItems = true
            }

            if let fileTreeStore {
                precondition(
                    selectedNodesByID.updateValue(node, forKey: node.id) == nil,
                    "Inspector selection contains duplicate node IDs"
                )
                if fileTreeStore.node(id: node.id) != nil {
                    presentNodeIDs.append(node.id)
                }
            }
        }

        if let fileTreeStore {
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
        self.selectedFolderCount = selectedFolderCount
        self.selectedPackageCount = selectedPackageCount
        self.selectedFileCount = selectedFileCount
        self.selectedStorageCategoryCount = selectedStorageCategoryCount
        self.containsSharedStorageItems = containsSharedStorageItems
        self.containsKnownClones = containsKnownClones
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
