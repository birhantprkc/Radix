//
//  HardLinkIdentityOwnerAccumulator.swift
//  Radix
//
//  Created by Codex on 7/10/26.
//

import Foundation

/// Incrementally assigns each hard-link identity's allocated storage to one owner.
///
/// The lexicographically smallest `(path, ownerNodeID)` claim wins. All other
/// claims contribute an allocated-size correction to their owning tree node.
/// Keeping only the current winner makes memory proportional to unique hard-link
/// identities and corrected owners rather than the total number of claims.
nonisolated struct HardLinkIdentityOwnerAccumulator: Sendable {
    private var winnerByIdentity: [FileIdentity: HardLinkClaim] = [:]
    private(set) var duplicateAllocatedSizeByOwner: [String: Int64] = [:]

    nonisolated init() {}

    nonisolated init<S: Sequence>(_ claims: S) where S.Element == HardLinkClaim {
        record(contentsOf: claims)
    }

    nonisolated var identityCount: Int {
        winnerByIdentity.count
    }

    nonisolated var isEmpty: Bool {
        winnerByIdentity.isEmpty
    }

    nonisolated func winner(for identity: FileIdentity) -> HardLinkClaim? {
        winnerByIdentity[identity]
    }

    nonisolated mutating func record(_ claim: HardLinkClaim) {
        guard claim.allocatedSize > 0 else { return }

        guard let currentWinner = winnerByIdentity[claim.identity] else {
            winnerByIdentity[claim.identity] = claim
            return
        }

        if Self.precedes(claim, currentWinner) {
            addDuplicate(currentWinner)
            winnerByIdentity[claim.identity] = claim
        } else {
            addDuplicate(claim)
        }
    }

    nonisolated mutating func record<S: Sequence>(contentsOf claims: S) where S.Element == HardLinkClaim {
        for claim in claims {
            record(claim)
        }
    }

    /// Merges a package-local accumulator without reconstructing its original claims.
    nonisolated mutating func merge(_ other: Self) {
        for (ownerNodeID, allocatedSize) in other.duplicateAllocatedSizeByOwner {
            duplicateAllocatedSizeByOwner[ownerNodeID, default: 0] += allocatedSize
        }
        for winner in other.winnerByIdentity.values {
            record(winner)
        }
    }

    private nonisolated static func precedes(_ lhs: HardLinkClaim, _ rhs: HardLinkClaim) -> Bool {
        if lhs.path == rhs.path {
            return lhs.ownerNodeID < rhs.ownerNodeID
        }
        return lhs.path < rhs.path
    }

    private nonisolated mutating func addDuplicate(_ claim: HardLinkClaim) {
        duplicateAllocatedSizeByOwner[claim.ownerNodeID, default: 0] += claim.allocatedSize
    }
}
