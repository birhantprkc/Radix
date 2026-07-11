import Foundation

/// Sorts comparison evidence independently from the service that constructs it.
nonisolated struct ScanComparisonRowComparator: Equatable, SortComparator, Sendable {
    enum Field: Equatable, Sendable {
        case changeKind
        case relativePath
        case beforeAllocatedSize
        case afterAllocatedSize
        case allocatedDelta
        case absoluteAllocatedDelta
        case itemKind
    }

    static let defaultOrder = ScanComparisonRowComparator(field: .absoluteAllocatedDelta, order: .reverse)

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: ScanComparisonRow, _ rhs: ScanComparisonRow) -> ComparisonResult {
        let result: ComparisonResult = switch field {
        case .changeKind:
            FileNodeSortComparison.compare(lhs.kind.sortRank, rhs.kind.sortRank)
        case .relativePath:
            lhs.relativePath.localizedStandardCompare(rhs.relativePath)
        case .beforeAllocatedSize:
            FileNodeSortComparison.compareOptional(lhs.beforeAllocatedSize, rhs.beforeAllocatedSize)
        case .afterAllocatedSize:
            FileNodeSortComparison.compareOptional(lhs.afterAllocatedSize, rhs.afterAllocatedSize)
        case .allocatedDelta:
            FileNodeSortComparison.compare(lhs.allocatedDelta, rhs.allocatedDelta)
        case .absoluteAllocatedDelta:
            FileNodeSortComparison.compare(lhs.absoluteAllocatedDelta, rhs.absoluteAllocatedDelta)
        case .itemKind:
            lhs.itemKind.localizedStandardCompare(rhs.itemKind)
        }

        let orderedResult = FileNodeSortComparison.applying(order, to: result)
        switch orderedResult {
        case .orderedSame:
            return FileNodeSortComparison.fallback(
                lhsName: lhs.name,
                lhsID: lhs.relativePath,
                rhsName: rhs.name,
                rhsID: rhs.relativePath
            )
        default:
            return orderedResult
        }
    }
}

/// Filters and orders comparison evidence for table presentation.
nonisolated struct ScanComparisonRowQuery: Equatable, Sendable {
    let changeKinds: Set<ScanComparisonChangeKind>
    let searchText: String
    let sortOrder: [ScanComparisonRowComparator]
    /// Limits evidence to one top-level contributor while retaining its full descendant rows.
    let pathPrefix: String?

    init(
        changeKinds: Set<ScanComparisonChangeKind> = Set(ScanComparisonChangeKind.allCases),
        searchText: String,
        sortOrder: [ScanComparisonRowComparator],
        pathPrefix: String? = nil
    ) {
        self.changeKinds = changeKinds
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.pathPrefix = pathPrefix
    }

    func applying(to rows: [ScanComparisonRow]) -> [ScanComparisonRow] {
        let query = SearchNormalizer.normalize(
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let filteredRows = rows.filter { row in
            guard changeKinds.contains(row.kind) else { return false }
            if let pathPrefix, !pathPrefix.isEmpty {
                guard row.relativePath == pathPrefix || row.relativePath.hasPrefix(pathPrefix + "/") else {
                    return false
                }
            }
            guard !query.isEmpty else { return true }
            return SearchNormalizer.normalize(row.name).contains(query)
                || SearchNormalizer.normalize(row.relativePath).contains(query)
        }

        guard !sortOrder.isEmpty else { return filteredRows }
        return filteredRows.sorted { lhs, rhs in
            for comparator in sortOrder {
                switch comparator.compare(lhs, rhs) {
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
            return false
        }
    }
}
