//
//  ScanIncrementalModels.swift
//  Radix
//

import Foundation

/// A persistent position in one volume's FSEvents journal.
///
/// The event ID is meaningful only while `volumeUUID` still identifies the
/// device containing the scan target. `capturedAt` is informational; event IDs,
/// rather than wall-clock time, define the history boundary.
nonisolated struct ScanIncrementalCheckpoint: Codable, Hashable, Sendable {
    let volumeUUID: String
    let eventID: UInt64
    let capturedAt: Date

    init(volumeUUID: String, eventID: UInt64, capturedAt: Date = Date()) {
        self.volumeUUID = volumeUUID.lowercased()
        self.eventID = eventID
        self.capturedAt = capturedAt
    }
}

/// Filesystem-independent flags consumed by the incremental rescan planner.
/// The Darwin provider translates FSEvents constants into these values so the
/// planner and its tests do not depend on CoreServices numeric constants.
nonisolated struct FileSystemEventFlags: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let mustScanSubdirectories = Self(rawValue: 1 << 0)
    static let userDropped = Self(rawValue: 1 << 1)
    static let kernelDropped = Self(rawValue: 1 << 2)
    static let eventIDsWrapped = Self(rawValue: 1 << 3)
    static let rootChanged = Self(rawValue: 1 << 4)
    static let volumeMounted = Self(rawValue: 1 << 5)
    static let volumeUnmounted = Self(rawValue: 1 << 6)

    static let itemCreated = Self(rawValue: 1 << 7)
    static let itemRemoved = Self(rawValue: 1 << 8)
    static let itemRenamed = Self(rawValue: 1 << 9)
    static let itemModified = Self(rawValue: 1 << 10)
    static let itemMetadataModified = Self(rawValue: 1 << 11)
    static let itemIsFile = Self(rawValue: 1 << 12)
    static let itemIsDirectory = Self(rawValue: 1 << 13)
    static let itemIsSymbolicLink = Self(rawValue: 1 << 14)

}

nonisolated struct FileSystemEventRecord: Codable, Hashable, Sendable {
    let path: String
    let eventID: UInt64
    let flags: FileSystemEventFlags

    init(path: String, eventID: UInt64, flags: FileSystemEventFlags) {
        self.path = URL(filePath: path).standardizedFileURL.path
        self.eventID = eventID
        self.flags = flags
    }
}

nonisolated struct FileSystemEventHistory: Sendable {
    let since: ScanIncrementalCheckpoint
    let through: ScanIncrementalCheckpoint
    let events: [FileSystemEventRecord]

    init(
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint,
        events: [FileSystemEventRecord]
    ) {
        self.since = since
        self.through = through
        self.events = events
    }
}

nonisolated enum IncrementalRescanFallbackReason: String, Codable, Hashable, Sendable {
    case userDroppedEvents
    case kernelDroppedEvents
    case eventIDsWrapped
    case watchedRootChanged
    case nestedVolumeChanged
    case changedScanRoot
    case eventOutsideTarget
    case noMaterializedAncestor
    case autoSummarizedBoundary
}

nonisolated enum IncrementalRescanPlan: Equatable, Sendable {
    case noChanges
    case rescanSubtrees(nodeIDs: [String])
    case fullScan(reason: IncrementalRescanFallbackReason)
}

nonisolated enum FileSystemEventHistoryError: LocalizedError, Sendable {
    case targetUnavailable(String)
    case targetIsNotDirectory(String)
    case nonLocalVolume(String)
    case volumeUUIDUnavailable(String)
    case eventIDUnavailable(String)
    case volumeChanged
    case eventIDRolledBack
    case invalidCheckpointRange
    case streamCreationFailed
    case streamStartFailed
    case historyEndedWithoutSentinel

    var errorDescription: String? {
        switch self {
        case .targetUnavailable(let path):
            return "The incremental scan target is unavailable: \(path)."
        case .targetIsNotDirectory(let path):
            return "The incremental scan target is not a directory: \(path)."
        case .nonLocalVolume(let path):
            return "Incremental scans are unavailable for the non-local volume containing \(path)."
        case .volumeUUIDUnavailable(let path):
            return "The volume containing \(path) does not expose an FSEvents UUID."
        case .eventIDUnavailable(let path):
            return "The volume containing \(path) does not expose an FSEvents checkpoint."
        case .volumeChanged:
            return "The scan target is now on a different volume."
        case .eventIDRolledBack:
            return "The volume's FSEvents history is older than the saved checkpoint."
        case .invalidCheckpointRange:
            return "The requested FSEvents checkpoint range is invalid."
        case .streamCreationFailed:
            return "Radix could not create an FSEvents history stream."
        case .streamStartFailed:
            return "Radix could not start the FSEvents history stream."
        case .historyEndedWithoutSentinel:
            return "The FSEvents history stream ended before reporting HistoryDone."
        }
    }
}
