import Foundation

nonisolated struct TreemapTooltipContent: Equatable, Sendable {
    let systemImageName: String
    let title: String
    let sizeAndSignificance: String
    let location: String
    let metadata: String

    var accessibilityDescription: String {
        [title, sizeAndSignificance, location, metadata].joined(separator: ", ")
    }

    static func content(
        for segment: TreemapSegment,
        rootNode: FileNodeRecord,
        treeStore: FileTreeStore
    ) -> TreemapTooltipContent {
        guard let nodeID = segment.nodeID,
              let node = treeStore.node(id: nodeID) else {
            return aggregateContent(for: segment, rootNode: rootNode, treeStore: treeStore)
        }

        let metadata: String
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            metadata = "APFS available capacity"
        } else if node.isDirectory {
            metadata = fileCountDescription(node.descendantFileCount)
        } else if let lastModified = node.lastModified {
            metadata = "Modified \(RadixFormatters.date(lastModified))"
        } else {
            metadata = "Modification date unavailable"
        }

        return TreemapTooltipContent(
            systemImageName: node.systemImageName,
            title: node.name,
            sizeAndSignificance: sizeAndSignificance(
                size: node.allocatedSize,
                rootNode: rootNode
            ),
            location: pathDescription(
                to: treeStore.parentID(of: node.id) ?? rootNode.id,
                relativeTo: rootNode,
                treeStore: treeStore
            ),
            metadata: metadata
        )
    }

    private static func aggregateContent(
        for segment: TreemapSegment,
        rootNode: FileNodeRecord,
        treeStore: FileTreeStore
    ) -> TreemapTooltipContent {
        let itemCount = segment.groupedItemCount ?? 0
        return TreemapTooltipContent(
            systemImageName: "square.grid.3x3.fill",
            title: segment.label,
            sizeAndSignificance: sizeAndSignificance(
                size: segment.totalSize,
                rootNode: rootNode
            ),
            location: pathDescription(
                to: segment.containerNodeID,
                relativeTo: rootNode,
                treeStore: treeStore
            ),
            metadata: itemCount == 1
                ? "1 grouped item"
                : "\(itemCount.formatted(.number)) grouped items"
        )
    }

    private static func sizeAndSignificance(
        size: Int64,
        rootNode: FileNodeRecord
    ) -> String {
        let formattedSize = RadixFormatters.size(size)
        guard let percentage = RadixFormatters.percentage(
            part: size,
            total: rootNode.allocatedSize
        ) else {
            return formattedSize
        }
        return "\(formattedSize) · \(percentage) of \(rootNode.name)"
    }

    private static func pathDescription(
        to nodeID: String,
        relativeTo rootNode: FileNodeRecord,
        treeStore: FileTreeStore
    ) -> String {
        let path = treeStore.path(to: nodeID)
        let relativePath: ArraySlice<FileNodeRecord>
        if let rootIndex = path.firstIndex(where: { $0.id == rootNode.id }) {
            relativePath = path[rootIndex...]
        } else {
            relativePath = path[...]
        }

        let names = relativePath.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? rootNode.name : names.joined(separator: " › ")
    }

    private static func fileCountDescription(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count.formatted(.number)) files"
    }
}
