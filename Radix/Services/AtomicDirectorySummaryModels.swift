//
//  AtomicDirectorySummaryModels.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

typealias CancellationCheck = @Sendable () throws -> Void

/// A child discovered during directory enumeration.
/// Directory enumeration prefetches resource values, so carrying decoded metadata forward
/// avoids asking each URL for the same values again when the child is scanned.
nonisolated struct DirectoryEntry: Sendable {
    let url: URL
    let metadata: NodeMetadata?
    let localizedEnumerationError: Error?
    let isDirectoryHint: Bool?
    /// Exact validated child-name bytes from native bulk enumeration.
    /// Foundation/fallback enumeration leaves this unavailable.
    let nativeName: BulkDirectoryEnumerator.NativeName?

    init(
        url: URL,
        metadata: NodeMetadata?,
        localizedEnumerationError: Error? = nil,
        isDirectoryHint: Bool? = nil,
        nativeName: BulkDirectoryEnumerator.NativeName? = nil
    ) {
        self.url = url
        self.metadata = metadata
        self.localizedEnumerationError = localizedEnumerationError
        self.isDirectoryHint = isDirectoryHint
        self.nativeName = nativeName
    }
}

nonisolated struct AtomicDirectorySummary: Sendable {
    let allocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let isAccessible: Bool
    let warnings: [ScanWarning]
    let hardLinkAccumulator: HardLinkIdentityOwnerAccumulator
}

nonisolated struct AtomicDirectorySummaryPartial: Sendable {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var descendantFileCount = 0
    var isAccessible = true
    var warnings: [ScanWarning] = []
    var hardLinkAccumulator = HardLinkIdentityOwnerAccumulator()

    mutating func updateAccessibility(_ readable: Bool) {
        isAccessible = isAccessible && readable
    }

    mutating func recordWarning(for url: URL, error: Error) {
        isAccessible = false
        warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
    }

    mutating func accumulateFile(_ metadata: NodeMetadata, url: URL, ownerNodeID: String) {
        allocatedSize = ScanIntegerMath.addingClamped(allocatedSize, metadata.allocatedSize)
        logicalSize = ScanIntegerMath.addingClamped(logicalSize, metadata.logicalSize)
        if !metadata.isSymbolicLink {
            descendantFileCount = ScanIntegerMath.addingClamped(descendantFileCount, 1)
        }
        if let claim = HardLinkDeduplicator.claim(
            for: metadata,
            ownerNodeID: ownerNodeID,
            path: url.path
        ) {
            hardLinkAccumulator.record(claim)
        }
    }
}

nonisolated struct AtomicSummaryWorkResult: Sendable {
    var partial: AtomicDirectorySummaryPartial
    var pendingItems: [AtomicSummaryWorkItem]
}

nonisolated struct AtomicSummaryWorkItem: @unchecked Sendable {
    let url: URL
    let treatPackagesAsDirectories: Bool
    let ownerNodeID: String
    var bufferedEntries: [DirectoryEntry]
    var nextEntryIndex: Int
    var cursor: BulkDirectoryEnumerator.Cursor?
    var needsCursor: Bool
    var requiresRootRestartOnFallback: Bool

    init(
        url: URL,
        treatPackagesAsDirectories: Bool,
        ownerNodeID: String,
        bufferedEntries: [DirectoryEntry] = [],
        nextEntryIndex: Int = 0,
        cursor: BulkDirectoryEnumerator.Cursor? = nil,
        needsCursor: Bool = true,
        requiresRootRestartOnFallback: Bool = false
    ) {
        self.url = url
        self.treatPackagesAsDirectories = treatPackagesAsDirectories
        self.ownerNodeID = ownerNodeID
        self.bufferedEntries = bufferedEntries
        self.nextEntryIndex = nextEntryIndex
        self.cursor = cursor
        self.needsCursor = needsCursor
        self.requiresRootRestartOnFallback = requiresRootRestartOnFallback
    }
}

nonisolated struct AtomicDirectoryProbeResumeState: @unchecked Sendable {
    var partial: AtomicDirectorySummaryPartial
    var workItems: [AtomicSummaryWorkItem]
    let visitedItemCount: Int

    func invalidateCursors() {
        for workItem in workItems {
            workItem.cursor?.invalidate()
        }
    }
}

nonisolated struct AtomicDirectoryProbeOutcome: @unchecked Sendable {
    var profile: AtomicDirectoryProbeProfile
    var resumeState: AtomicDirectoryProbeResumeState?
}

nonisolated final class AtomicDirectorySummaryState {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var descendantFileCount = 0
    var isAccessible = true
    var warnings: [ScanWarning] = []
    var hardLinkAccumulator = HardLinkIdentityOwnerAccumulator()
    let ownerNodeID: String

    init(ownerNodeID: String) {
        self.ownerNodeID = ownerNodeID
    }
}

nonisolated struct AtomicDirectoryProbeProfile: Sendable {
    var observedFileCount = 0
    var observedDirectoryCount = 0
    var totalSampledLogicalSize: Int64 = 0
    var observedNodeDependencyLayout = false

    func suggestsAtomicDirectory(minFileCount: Int, maxAverageFileSize: Int64) -> Bool {
        guard observedFileCount > 0, observedFileCount >= minFileCount else { return false }
        return (totalSampledLogicalSize / Int64(observedFileCount)) <= maxAverageFileSize
    }
}
