import Foundation

nonisolated struct InspectorSelectionSummary: Equatable, Sendable {
    let selectedNodes: [FileNodeRecord]
    let countedNodes: [FileNodeRecord]
    let allocatedSize: Int64
    let logicalSize: Int64

    init(selectedNodes: [FileNodeRecord], fileTreeStore: FileTreeStore?) {
        self.selectedNodes = selectedNodes

        if let fileTreeStore {
            let selectedNodesByID = Dictionary(
                uniqueKeysWithValues: selectedNodes.map { ($0.id, $0) }
            )
            countedNodes = fileTreeStore
                .topLevelNodeIDs(from: selectedNodes.map(\.id))
                .compactMap { selectedNodesByID[$0] }
        } else {
            countedNodes = selectedNodes
        }

        allocatedSize = Self.total(\.allocatedSize, in: countedNodes)
        logicalSize = Self.total(\.logicalSize, in: countedNodes)
    }

    var selectedCount: Int {
        selectedNodes.count
    }

    var containsOverlappingSelections: Bool {
        countedNodes.count != selectedNodes.count
    }

    private static func total(
        _ keyPath: KeyPath<FileNodeRecord, Int64>,
        in nodes: [FileNodeRecord]
    ) -> Int64 {
        nodes.reduce(0) { total, node in
            ScanIntegerMath.addingClamped(total, node[keyPath: keyPath])
        }
    }
}
