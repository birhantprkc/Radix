import Foundation

/// Shared by explicit file actions and Quick Look's asynchronous selection updates.
nonisolated enum FileActionValidation {
    static func validateLivePath(
        _ node: FileNodeRecord,
        source: ScanSnapshotSource,
        fileExists: (URL) -> Bool,
        verifyIdentity: (FileNodeRecord) -> TrashIdentityVerificationResult
    ) throws {
        guard source.allowsLivePathActions else { throw FileActionError.unsupported }
        guard node.url.isFileURL, fileExists(node.url) else {
            throw FileActionError.unavailable(path: node.url.path)
        }
        guard source.isImported, node.fileIdentity != nil else { return }

        switch verifyIdentity(node) {
        case .matches, .missingScannedIdentity:
            return
        case .missingCurrentItem:
            throw FileActionError.unavailable(path: node.url.path)
        case .mismatch:
            throw FileActionError.changedSinceScan(path: node.url.path)
        case .metadataUnavailable(let reason):
            throw FileActionError.currentIdentityUnavailable(path: node.url.path, reason: reason)
        }
    }
}
