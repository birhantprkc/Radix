//
//  FileBrowserResults.swift
//  Radix
//

import Foundation

enum FileBrowserResults {
    nonisolated static func visibleNodes(
        _ nodes: [FileNodeRecord],
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore?
    ) -> [FileNodeRecord] {
        visibleNodes(
            nodes,
            hiddenNodeIDs: hiddenNodeIDs,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )
    }

    nonisolated static func visibleNodes(
        _ nodes: [FileNodeRecord],
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore?,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FileNodeRecord] {
        guard !hiddenNodeIDs.isEmpty,
              let fileTreeStore else {
            try cancellationCheck()
            return nodes
        }

        let hiddenNodes = fileTreeStore.preparedNodeSet(for: hiddenNodeIDs)
        var visibleNodes: [FileNodeRecord] = []
        visibleNodes.reserveCapacity(nodes.count)

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if !fileTreeStore.isNodeOrDescendant(node.id, of: hiddenNodes) {
                visibleNodes.append(node)
            }
        }
        try cancellationCheck()
        return visibleNodes
    }

    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil
    ) -> [FileNodeRecord] {
        filteredAndSortedCurrentContents(
            nodes,
            query: query,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )
    }

    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FileNodeRecord] {
        guard query.isActive else {
            try cancellationCheck()
            return try sorted(
                nodes,
                sortOrder: sortOrder,
                fileTreeStore: fileTreeStore,
                cancellationCheck: cancellationCheck
            )
        }

        let preparedQuery = query.prepared()
        var filteredNodes: [FileNodeRecord] = []
        filteredNodes.reserveCapacity(min(nodes.count, 256))

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }

            if preparedQuery.matches(node) {
                filteredNodes.append(node)
            }
        }

        try cancellationCheck()
        return try sorted(
            filteredNodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated static func sorted(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil
    ) -> [FileNodeRecord] {
        sorted(
            nodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )
    }

    nonisolated static func sorted(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FileNodeRecord] {
        try cancellationCheck()
        guard !sortOrder.isEmpty else { return nodes }

        var preparedNodes = try preparedSortNodes(
            nodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()

        let sortedNodes = try CancellableSort.sorted(
            &preparedNodes,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            lhs.isOrderedBefore(rhs, using: sortOrder)
        }
        try cancellationCheck()
        var result: [FileNodeRecord] = []
        result.reserveCapacity(sortedNodes.count)
        var start = 0
        while start < sortedNodes.count {
            let end = min(start + 256, sortedNodes.count)
            while start < end {
                result.append(sortedNodes[start].node)
                start += 1
            }
            try cancellationCheck()
        }
        return result
    }

    private nonisolated static func preparedSortNodes(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore?,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [PreparedSortNode] {
        let preparesItemKind = sortOrder.contains { $0.field == .itemKind }
        let preparesDescendantFileCount = sortOrder.contains { $0.field == .descendantFileCount }
        var preparedNodes: [PreparedSortNode] = []
        preparedNodes.reserveCapacity(nodes.count)

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            preparedNodes.append(PreparedSortNode(
                node: node,
                itemKind: preparesItemKind ? node.itemKind : nil,
                descendantFileCount: preparesDescendantFileCount
                    ? (FileBrowserPackageContents.areHidden(for: node, fileTreeStore: fileTreeStore)
                        ? 0
                        : node.descendantFileCount)
                    : nil
            ))
        }

        return preparedNodes
    }

    private struct PreparedSortNode {
        let node: FileNodeRecord
        let itemKind: String?
        let descendantFileCount: Int?

        nonisolated func compare(_ rhs: PreparedSortNode, using comparator: FileNodeTableComparator) -> ComparisonResult {
            let result: ComparisonResult = switch comparator.field {
            case .name:
                node.name.localizedStandardCompare(rhs.node.name)
            case .allocatedSize:
                FileNodeSortComparison.compare(node.allocatedSize, rhs.node.allocatedSize)
            case .itemKind:
                itemKind!.localizedStandardCompare(rhs.itemKind!)
            case .descendantFileCount:
                FileNodeSortComparison.compare(descendantFileCount!, rhs.descendantFileCount!)
            case .lastModified:
                FileNodeSortComparison.compareOptional(node.lastModified, rhs.node.lastModified)
            }

            return FileNodeSortComparison.applying(comparator.order, to: result)
        }

        nonisolated func isOrderedBefore(
            _ rhs: PreparedSortNode,
            using sortOrder: [FileNodeTableComparator]
        ) -> Bool {
            for comparator in sortOrder {
                switch compare(rhs, using: comparator) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    continue
                @unknown default:
                    continue
                }
            }
            return FileNodeSortComparison.fallback(
                lhsName: node.name,
                lhsID: node.id,
                rhsName: rhs.node.name,
                rhsID: rhs.node.id
            ) == .orderedAscending
        }
    }
}
