import Foundation

nonisolated enum ScanComparisonCandidateSource: Equatable, Sendable {
    case archive(URL)
    case currentSnapshot(UUID)

    static func == (
        lhs: ScanComparisonCandidateSource,
        rhs: ScanComparisonCandidateSource
    ) -> Bool {
        switch (lhs, rhs) {
        case (.archive(let lhsURL), .archive(let rhsURL)):
            return lhsURL == rhsURL
        case (.currentSnapshot(let lhsID), .currentSnapshot(let rhsID)):
            return lhsID == rhsID
        default:
            return false
        }
    }
}

nonisolated enum ScanComparisonSlot: String, CaseIterable, Identifiable, Sendable {
    case before
    case after

    var id: String { rawValue }

    var title: String {
        switch self {
        case .before:
            return "Earlier Scan"
        case .after:
            return "Later Scan"
        }
    }
}

nonisolated struct ScanComparisonCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: ScanComparisonCandidateSource
    let displayName: String
    let path: String
    let targetKind: ScanTargetKind
    let scanDate: Date
    let totalAllocatedSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let warningCount: Int
    let scanOptions: ScanOptions?

    init(preview: ScanArchivePreview) {
        self.id = UUID()
        self.source = .archive(preview.archiveURL)
        self.displayName = preview.target.displayName
        self.path = preview.target.path
        self.targetKind = preview.target.kind
        self.scanDate = preview.finishedAt ?? preview.startedAt
        self.totalAllocatedSize = preview.totalAllocatedSize
        self.fileCount = preview.fileCount
        self.directoryCount = preview.directoryCount
        self.warningCount = preview.warningCount
        self.scanOptions = preview.scanOptions
    }

    init(snapshot: ScanSnapshot) {
        self.init(snapshot: snapshot, source: .currentSnapshot(snapshot.id))
    }

    private init(snapshot: ScanSnapshot, source: ScanComparisonCandidateSource) {
        self.id = snapshot.id
        self.source = source
        self.displayName = snapshot.target.displayName
        self.path = snapshot.target.url.path
        self.targetKind = snapshot.target.kind
        self.scanDate = snapshot.finishedAt ?? snapshot.startedAt
        self.totalAllocatedSize = snapshot.aggregateStats.totalAllocatedSize
        self.fileCount = snapshot.aggregateStats.fileCount
        self.directoryCount = snapshot.aggregateStats.directoryCount
        self.warningCount = snapshot.scanWarnings.count
        self.scanOptions = snapshot.scanOptions
    }

    var isCurrentScan: Bool {
        if case .currentSnapshot = source {
            return true
        }
        return false
    }
}

/// Pure setup state and compatibility validation for a two-snapshot comparison.
nonisolated struct ScanComparisonSetup: Identifiable, Equatable, Sendable {
    let id: UUID
    var before: ScanComparisonCandidate?
    var after: ScanComparisonCandidate?
    var loadingSlot: ScanComparisonSlot?
    var errorMessage: String?

    init(
        before: ScanComparisonCandidate? = nil,
        after: ScanComparisonCandidate? = nil,
        loadingSlot: ScanComparisonSlot? = nil,
        errorMessage: String? = nil
    ) {
        self.id = UUID()
        self.before = before
        self.after = after
        self.loadingSlot = loadingSlot
        self.errorMessage = errorMessage
    }

    var canCompare: Bool {
        guard loadingSlot == nil,
              let before,
              let after else {
            return false
        }
        return before.source != after.source && validationMessage == nil
    }

    var validationMessage: String? {
        guard let before,
              let after else {
            return nil
        }
        if before.source == after.source {
            return "Choose two different scans."
        }
        guard before.targetKind == after.targetKind,
              Self.normalizedRootPath(before.path) == Self.normalizedRootPath(after.path) else {
            return "Choose scans of the same location."
        }
        if before.scanDate > after.scanDate {
            return "The earlier scan must precede the later scan."
        }
        if let beforeOptions = before.scanOptions,
           let afterOptions = after.scanOptions,
           beforeOptions != afterOptions {
            return "Choose scans made with the same scan settings."
        }
        if (before.scanOptions == nil) != (after.scanOptions == nil) {
            return "One scan is missing its settings, so these scans cannot be compared safely."
        }
        return nil
    }

    var resolvedCandidates: (before: ScanComparisonCandidate, after: ScanComparisonCandidate)? {
        guard let before,
              let after else {
            return nil
        }
        return (before, after)
    }

    var currentSnapshotID: UUID? {
        if case .currentSnapshot(let id)? = before?.source {
            return id
        }
        if case .currentSnapshot(let id)? = after?.source {
            return id
        }
        return nil
    }

    func candidate(for slot: ScanComparisonSlot) -> ScanComparisonCandidate? {
        switch slot {
        case .before:
            return before
        case .after:
            return after
        }
    }

    func canAssignCurrentScan(to slot: ScanComparisonSlot) -> Bool {
        let otherCandidate = switch slot {
        case .before:
            after
        case .after:
            before
        }
        return otherCandidate?.isCurrentScan != true
    }

    mutating func setCandidate(_ candidate: ScanComparisonCandidate?, for slot: ScanComparisonSlot) {
        switch slot {
        case .before:
            before = candidate
        case .after:
            after = candidate
        }
    }

    mutating func swap() {
        Swift.swap(&before, &after)
    }

    private static func normalizedRootPath(_ path: String) -> String {
        URL(filePath: path, directoryHint: .isDirectory)
            .standardizedFileURL
            .path
    }
}
