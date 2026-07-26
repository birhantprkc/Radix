import Foundation

nonisolated struct FileBrowserQuery: Hashable, Sendable {
    var text = ""
    var itemKind: FileBrowserItemKindFilter?
    var allocatedSize: FileBrowserAllocatedSizeFilter?

    var isActive: Bool {
        hasText || itemKind != nil || allocatedSize != nil
    }

    var hasText: Bool {
        !trimmedText.isEmpty
    }

    var hasStructuredFilters: Bool {
        itemKind != nil || allocatedSize != nil
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func prepared() -> PreparedFileBrowserQuery {
        let normalizedText = SearchNormalizer.normalize(trimmedText)
        return PreparedFileBrowserQuery(
            normalizedText: normalizedText,
            normalizedPathText: normalizedText.replacingOccurrences(of: "\\", with: "/"),
            includesPath: SearchNormalizer.queryIncludesPath(trimmedText),
            itemKind: itemKind,
            allocatedSize: allocatedSize
        )
    }
}

nonisolated enum FileBrowserItemKindFilter: Hashable, Sendable {
    case file
    case folder
    case package

    static func classification(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isPackage: Bool,
        isSynthetic: Bool
    ) -> Self? {
        guard !isSymbolicLink, !isSynthetic else { return nil }
        if isPackage {
            return .package
        }
        return isDirectory ? .folder : .file
    }
}

nonisolated struct FileBrowserAllocatedSizeFilter: Hashable, Sendable {
    var relation: FileBrowserSizeRelation
    var bytes: Int64

    func matches(_ allocatedSize: Int64) -> Bool {
        switch relation {
        case .greaterThan:
            allocatedSize > bytes
        case .atLeast:
            allocatedSize >= bytes
        case .lessThan:
            allocatedSize < bytes
        case .atMost:
            allocatedSize <= bytes
        }
    }
}

nonisolated enum FileBrowserSizeRelation: Hashable, Sendable {
    case greaterThan
    case atLeast
    case lessThan
    case atMost
}

nonisolated enum FileBrowserSizeUnit: CaseIterable, Hashable, Identifiable, Sendable {
    case kilobytes
    case megabytes
    case gigabytes
    case terabytes

    var id: Self { self }

    var title: String {
        switch self {
        case .kilobytes: "KB"
        case .megabytes: "MB"
        case .gigabytes: "GB"
        case .terabytes: "TB"
        }
    }

    var bytes: Int64 {
        switch self {
        case .kilobytes: 1_000
        case .megabytes: 1_000_000
        case .gigabytes: 1_000_000_000
        case .terabytes: 1_000_000_000_000
        }
    }

    func byteCount(for value: Double) -> Int64? {
        guard value.isFinite, value >= 0 else { return nil }
        return Int64(exactly: (value * Double(bytes)).rounded())
    }

    func value(for bytes: Int64) -> Double {
        Double(bytes) / Double(self.bytes)
    }

    static func bestUnit(for bytes: Int64) -> Self {
        guard bytes > 0 else { return .megabytes }

        // Keep the threshold exact when the editor displays at most two fraction digits.
        for unit in allCases.reversed()
        where bytes >= unit.bytes &&
            bytes.isMultiple(of: unit.bytes / 100) {
            return unit
        }
        return .kilobytes
    }
}

nonisolated struct PreparedFileBrowserQuery: Sendable {
    let normalizedText: String
    let normalizedPathText: String
    let includesPath: Bool
    let itemKind: FileBrowserItemKindFilter?
    let allocatedSize: FileBrowserAllocatedSizeFilter?

    var hasText: Bool {
        !normalizedText.isEmpty
    }

    func matchesMetadata(
        allocatedSize: Int64,
        itemKind: FileBrowserItemKindFilter?
    ) -> Bool {
        if let requiredItemKind = self.itemKind,
           requiredItemKind != itemKind {
            return false
        }

        return self.allocatedSize?.matches(allocatedSize) ?? true
    }

    func matches(_ node: FileNodeRecord) -> Bool {
        guard matchesMetadata(
            allocatedSize: node.allocatedSize,
            itemKind: FileBrowserItemKindFilter.classification(
                isDirectory: node.isDirectory,
                isSymbolicLink: node.isSymbolicLink,
                isPackage: node.isPackage,
                isSynthetic: node.isSynthetic
            )
        ) else {
            return false
        }

        return !hasText || SearchNormalizer.nodeMatches(
            node,
            normalizedQuery: normalizedText,
            normalizedPathQuery: normalizedPathText,
            includesPath: includesPath
        )
    }
}
