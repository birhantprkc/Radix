import Foundation
import XCTest
@testable import RadixCore

@MainActor
func waitUntil(
    _ description: String = "asynchronous test condition",
    timeout: TimeInterval = 1,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while !(await condition()) {
        try Task.checkCancellation()
        if clock.now >= deadline {
            XCTFail("Timed out waiting for \(description).", file: file, line: line)
            return
        }

        await Task.yield()
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class TestAppPreferencesStore: AppPreferencesPersisting {
    var preferences: AppPreferences

    init(preferences: AppPreferences = .defaults) {
        self.preferences = preferences
    }

    func loadPreferences() -> AppPreferences {
        preferences
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        self.preferences.scan = preferences
    }

    func markOnboardingComplete() {
        preferences.didCompleteOnboarding = true
    }

    func markOnboardingIncomplete() {
        preferences.didCompleteOnboarding = false
    }
}

final class TestRecentTargetPersistence: RecentTargetPersisting {
    var targets: [ScanTarget]

    init(targets: [ScanTarget] = []) {
        self.targets = targets
    }

    func loadRecentTargets() -> [ScanTarget] {
        targets
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {
        self.targets = targets
    }

    func clearRecentTargets() {
        targets = []
    }
}

func makeTestTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

func makeTestFileNode(
    id: String,
    name: String,
    size: Int64 = 1,
    unduplicatedAllocatedSize: Int64? = nil,
    dataAllocatedSize: Int64? = nil,
    lastModified: Date? = nil,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1,
    cloneIdentity: CloneIdentity? = nil,
    mayShareDataBlocks: Bool = false,
    isSymbolicLink: Bool = false,
    isAccessible: Bool = true,
    isSynthetic: Bool = false
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: isSymbolicLink,
        allocatedSize: size,
        unduplicatedAllocatedSize: unduplicatedAllocatedSize,
        dataAllocatedSize: dataAllocatedSize,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: lastModified,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        cloneIdentity: cloneIdentity,
        mayShareDataBlocks: mayShareDataBlocks,
        isPackage: false,
        isAccessible: isAccessible,
        isSelfAccessible: isAccessible,
        isSynthetic: isSynthetic,
        isAutoSummarized: false
    )
}

func makeTestDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isPackage: Bool = false,
    isAccessible: Bool = true,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: isPackage,
        isAccessible: isAccessible
    )
}

/// A directory the scan engine collapsed into a single leaf node (an auto-summarized
/// subtree). Its children are never indexed, so it must be placed in a store without a
/// `childrenByID` entry for its own id.
func makeTestSummarizedDirectoryNode(
    id: String,
    name: String,
    size: Int64,
    descendantFileCount: Int = 100
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: size,
        unduplicatedAllocatedSize: nil,
        logicalSize: size,
        descendantFileCount: descendantFileCount,
        lastModified: nil,
        fileIdentity: nil,
        linkCount: 1,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: true
    )
}

func makeTestSnapshot(
    target: ScanTarget? = nil,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = [],
    scanOptions: ScanOptions? = nil,
    incrementalCheckpoint: ScanIncrementalCheckpoint? = nil
) -> ScanSnapshot {
    ScanSnapshot(
        target: target ?? ScanTarget(url: root.url),
        treeStore: store,
        startedAt: Date(),
        finishedAt: Date(),
        scanWarnings: warnings,
        aggregateStats: store.aggregateStats,
        isComplete: true,
        scanOptions: scanOptions,
        incrementalCheckpoint: incrementalCheckpoint
    )
}

func makeComparisonSnapshot(
    rootPath: String,
    fileSize: Int64,
    startedAt: Date = Date(timeIntervalSince1970: 1),
    finishedAt: Date? = Date(timeIntervalSince1970: 2),
    sourceURL: URL? = nil,
    scanOptions: ScanOptions? = nil,
    targetKind: ScanTargetKind = .folder
) -> ScanSnapshot {
    let file = makeTestFileNode(id: "\(rootPath)/shared.bin", name: "shared.bin", size: fileSize)
    let root = makeTestDirectoryNode(
        id: rootPath,
        name: URL(filePath: rootPath).lastPathComponent,
        children: [file]
    )
    let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
    let source: ScanSnapshotSource
    if let sourceURL {
        source = .imported(ImportedSnapshotContext(
            sourceURL: sourceURL,
            pathMode: .absolute,
            liveActionCapability: .pathValidation
        ))
    } else {
        source = .live
    }

    return ScanSnapshot(
        target: ScanTarget(id: root.id, url: root.url, displayName: root.name, kind: targetKind),
        treeStore: store,
        startedAt: startedAt,
        finishedAt: finishedAt,
        scanWarnings: [],
        aggregateStats: store.aggregateStats,
        isComplete: true,
        scanOptions: scanOptions,
        source: source
    )
}
