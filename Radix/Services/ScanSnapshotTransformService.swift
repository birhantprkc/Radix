//
//  ScanSnapshotTransformService.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated enum ScanSnapshotTransformError: Error, Sendable {
    case sharedAllocationRequiresFullScan
}

private nonisolated enum SubtreeRescanAllocationValidator {
    static func validate(
        baseline: FileTreeStore,
        targetID: String,
        replacement: FileTreeStore,
        cancellationCheck: () throws -> Void
    ) throws {
        if try baseline.subtreeContainsSharedAllocationMetadata(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ) || replacement.subtreeContainsSharedAllocationMetadata(
            rootedAt: replacement.rootID,
            cancellationCheck: cancellationCheck
        ) {
            throw ScanSnapshotTransformError.sharedAllocationRequiresFullScan
        }
    }
}

protocol ScanSnapshotTransforming: Sendable {
    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot?

    func replacingSubtrees(
        in snapshot: ScanSnapshot,
        replacements: [String: FileTreeStore],
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot?

    func replacingNodeForSubtreeRescan(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning],
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) async throws -> ScanSnapshot?

    func removingNode(
        in snapshot: ScanSnapshot,
        id targetID: String
    ) async throws -> ScanSnapshot?

    func removingNodes(
        in snapshot: ScanSnapshot,
        ids targetIDs: [String]
    ) async throws -> ScanSnapshot?

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot?
}

extension ScanSnapshotTransforming {
    func replacingNodeForSubtreeRescan(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning],
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) async throws -> ScanSnapshot? {
        try SubtreeRescanAllocationValidator.validate(
            baseline: snapshot.treeStore,
            targetID: targetID,
            replacement: replacement,
            cancellationCheck: { try Task.checkCancellation() }
        )
        return try await replacingNode(
            in: snapshot,
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings
        )?.updatedAfterSubtreeRescan(
            finishedAt: Date(),
            volumeCapacity: volumeCapacity,
            reconcilesVolumeCapacity: reconcilesVolumeCapacity
        )
    }

    func replacingSubtrees(
        in snapshot: ScanSnapshot,
        replacements: [String: FileTreeStore],
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot? {
        try snapshot.replacingSubtrees(
            replacements,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func removingNodes(
        in snapshot: ScanSnapshot,
        ids targetIDs: [String]
    ) async throws -> ScanSnapshot? {
        try snapshot.removingNodes(
            ids: targetIDs,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func removingNode(
        in snapshot: ScanSnapshot,
        id targetID: String
    ) async throws -> ScanSnapshot? {
        try await removingNodes(in: snapshot, ids: [targetID])
    }
}

actor ScanSnapshotTransformService {
    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = []
    ) async throws -> ScanSnapshot? {
        return try snapshot.replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func replacingSubtrees(
        in snapshot: ScanSnapshot,
        replacements: [String: FileTreeStore],
        additionalWarnings: [ScanWarning] = []
    ) async throws -> ScanSnapshot? {
        try snapshot.replacingSubtrees(
            replacements,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func replacingNodeForSubtreeRescan(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = [],
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) async throws -> ScanSnapshot? {
        try SubtreeRescanAllocationValidator.validate(
            baseline: snapshot.treeStore,
            targetID: targetID,
            replacement: replacement,
            cancellationCheck: { try Task.checkCancellation() }
        )
        return try snapshot.replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )?.updatedAfterSubtreeRescan(
            finishedAt: Date(),
            volumeCapacity: volumeCapacity,
            reconcilesVolumeCapacity: reconcilesVolumeCapacity
        )
    }

    func removingNodes(
        in snapshot: ScanSnapshot,
        ids targetIDs: [String]
    ) async throws -> ScanSnapshot? {
        try snapshot.removingNodes(
            ids: targetIDs,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot? {
        try snapshot.scoped(
            to: target,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }
}

extension ScanSnapshotTransformService: ScanSnapshotTransforming {}
