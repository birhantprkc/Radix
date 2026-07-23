//
//  FileBrowserSearch.swift
//  Radix
//

import Foundation

protocol FileSearching: Sendable {
    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord]

    func pruneIndexes(keeping snapshotID: UUID?) async
}

extension FileSearching {
    func pruneIndexes(keeping snapshotID: UUID?) async {}
}

actor CurrentContentsSearchService {
    func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore?,
        debounceDuration: Duration
    ) async throws -> [FileNodeRecord] {
        try await Task.sleep(for: debounceDuration)
        return try FileBrowserResults.filteredAndSortedCurrentContents(
            nodes,
            query: query,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }
}

actor FileSearchService: FileSearching {
    private var cachedIndex: CachedFileSearchIndex?

    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord] {
        guard query.isActive else { return [] }
        let preparedQuery = query.prepared()

        let indexKey = FileSearchIndexKey(
            snapshotID: snapshotID,
            treeContentID: treeStore.contentID
        )
        if cachedIndex?.key != indexKey {
            cachedIndex = CachedFileSearchIndex(
                key: indexKey,
                index: try makeIndex(treeStore: treeStore)
            )
        }
        guard let entries = cachedIndex?.index.entries else { return [] }

        var matchedNodes: [FileNodeRecord] = []
        matchedNodes.reserveCapacity(min(entries.count, 256))

        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            guard preparedQuery.matchesMetadata(
                allocatedSize: entry.allocatedSize,
                itemKind: entry.itemKind
            ) else {
                continue
            }

            if !preparedQuery.hasText ||
                entry.normalizedNameKindHaystack.contains(preparedQuery.normalizedText) {
                if let node = treeStore.node(id: entry.id) {
                    matchedNodes.append(node)
                }
                continue
            }

            guard preparedQuery.includesPath else { continue }

            let normalizedPath: String
            if let cachedPath = cachedIndex?.index.normalizedPathsByID[entry.id] {
                normalizedPath = cachedPath
            } else {
                normalizedPath = SearchNormalizer.normalize(treeStore.node(id: entry.id)?.url.path ?? "")
                cachedIndex?.index.normalizedPathsByID[entry.id] = normalizedPath
            }

            if normalizedPath.contains(preparedQuery.normalizedText) {
                if let node = treeStore.node(id: entry.id) {
                    matchedNodes.append(node)
                }
            }
        }
        try Task.checkCancellation()
        let sortedNodes = try FileBrowserResults.sorted(
            matchedNodes,
            sortOrder: sortOrder,
            fileTreeStore: treeStore,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
        try Task.checkCancellation()
        return sortedNodes
    }

    func pruneIndexes(keeping snapshotID: UUID?) {
        guard let snapshotID else {
            cachedIndex = nil
            return
        }

        if cachedIndex?.key.snapshotID != snapshotID {
            cachedIndex = nil
        }
    }

    private func makeIndex(treeStore: FileTreeStore) throws -> FileSearchIndex {
        var entries: [FileSearchEntry] = []
        entries.reserveCapacity(max(treeStore.nodeCount - 1, 0))

        var offset = 0
        try treeStore.forEachIndexedNodeID(excludingRoot: true) { id in
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            offset += 1

            guard let node = treeStore.node(id: id) else { return }
            entries.append(FileSearchEntry(
                id: id,
                normalizedNameKindHaystack: SearchNormalizer.normalizedNameKindHaystack(for: node),
                allocatedSize: node.allocatedSize,
                itemKind: FileBrowserItemKindFilter.classification(
                    isDirectory: node.isDirectory,
                    isSymbolicLink: node.isSymbolicLink,
                    isPackage: node.isPackage,
                    isSynthetic: node.isSynthetic
                )
            ))
        }

        return FileSearchIndex(
            entries: entries,
            normalizedPathsByID: [:]
        )
    }
}

enum SearchNormalizer {
    nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    nonisolated static func queryIncludesPath(_ query: String) -> Bool {
        query.contains("/") || query.contains("\\")
    }

    nonisolated static func nodeMatches(
        _ node: FileNodeRecord,
        normalizedQuery: String,
        includesPath: Bool
    ) -> Bool {
        if normalizedNameKindHaystack(for: node).contains(normalizedQuery) {
            return true
        }

        guard includesPath else { return false }
        return normalize(node.url.path).contains(normalizedQuery)
    }

    nonisolated static func normalizedNameKindHaystack(for node: FileNodeRecord) -> String {
        normalize([node.name, node.itemKind].joined(separator: "\n"))
    }
}

private struct FileSearchIndex {
    let entries: [FileSearchEntry]
    var normalizedPathsByID: [FileNodeRecord.ID: String]
}

private struct CachedFileSearchIndex {
    let key: FileSearchIndexKey
    var index: FileSearchIndex
}

private nonisolated struct FileSearchIndexKey: Hashable, Sendable {
    let snapshotID: UUID
    let treeContentID: UUID
}

private struct FileSearchEntry {
    let id: FileNodeRecord.ID
    let normalizedNameKindHaystack: String
    let allocatedSize: Int64
    let itemKind: FileBrowserItemKindFilter?
}
