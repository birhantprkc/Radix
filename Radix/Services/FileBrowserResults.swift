//
//  FileBrowserResults.swift
//  Radix
//

import Foundation

enum FileBrowserResults {
    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil
    ) -> [FileNodeRecord] {
        (try? filteredAndSortedCurrentContents(
            nodes,
            query: query,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )) ?? []
    }

    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [FileNodeRecord] {
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
        (try? sorted(
            nodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )) ?? nodes
    }

    nonisolated static func sorted(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [FileNodeRecord] {
        try cancellationCheck()
        guard !sortOrder.isEmpty else { return nodes }

        var preparedNodes = try preparedSortNodes(
            nodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()

        let sortedNodes = try cancellablySorted(
            &preparedNodes,
            sortOrder: sortOrder,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        return sortedNodes.map(\.node)
    }

    private nonisolated static func cancellablySorted(
        _ nodes: inout [PreparedSortNode],
        sortOrder: [FileNodeTableComparator],
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [PreparedSortNode] {
        let chunkSize = 16_384
        guard nodes.count > chunkSize else {
            return nodes.sorted { lhs, rhs in
                lhs.isOrderedBefore(rhs, using: sortOrder)
            }
        }

        var source: [PreparedSortNode] = []
        source.reserveCapacity(nodes.count)

        for start in stride(from: 0, to: nodes.count, by: chunkSize) {
            try cancellationCheck()
            let end = min(start + chunkSize, nodes.count)
            source.append(contentsOf: nodes[start..<end].sorted { lhs, rhs in
                lhs.isOrderedBefore(rhs, using: sortOrder)
            })
        }
        nodes.removeAll(keepingCapacity: false)
        try cancellationCheck()
        var destination = source
        var runSize = chunkSize
        while runSize < source.count {
            let combinedRunSize = runSize * 2
            for start in stride(from: 0, to: source.count, by: combinedRunSize) {
                try mergeSortedRuns(
                    from: source,
                    into: &destination,
                    start: start,
                    middle: min(start + runSize, source.count),
                    end: min(start + combinedRunSize, source.count),
                    sortOrder: sortOrder,
                    cancellationCheck: cancellationCheck
                )
            }
            swap(&source, &destination)
            runSize = combinedRunSize
        }
        return source
    }

    private nonisolated static func mergeSortedRuns(
        from source: [PreparedSortNode],
        into destination: inout [PreparedSortNode],
        start: Int,
        middle: Int,
        end: Int,
        sortOrder: [FileNodeTableComparator],
        cancellationCheck: @Sendable () throws -> Void
    ) throws {
        var lhsIndex = start
        var rhsIndex = middle

        for writeIndex in start..<end {
            if (writeIndex - start).isMultiple(of: 256) {
                try cancellationCheck()
            }
            if lhsIndex == middle {
                destination[writeIndex] = source[rhsIndex]
                rhsIndex += 1
            } else if rhsIndex == end ||
                        !source[rhsIndex].isOrderedBefore(source[lhsIndex], using: sortOrder) {
                destination[writeIndex] = source[lhsIndex]
                lhsIndex += 1
            } else {
                destination[writeIndex] = source[rhsIndex]
                rhsIndex += 1
            }
        }
    }

    private nonisolated static func preparedSortNodes(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore?,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [PreparedSortNode] {
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
