//
//  ScanSnapshotTransformService.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

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

    func removingNode(
        in snapshot: ScanSnapshot,
        id targetID: String
    ) async throws -> ScanSnapshot?

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot?
}

extension ScanSnapshotTransforming {
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
}

actor ScanSnapshotTransformService {
    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = []
    ) async throws -> ScanSnapshot? {
        try snapshot.replacingNode(
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

    func removingNode(
        in snapshot: ScanSnapshot,
        id targetID: String
    ) async throws -> ScanSnapshot? {
        try snapshot.removingNode(
            id: targetID,
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
