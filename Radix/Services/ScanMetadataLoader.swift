//
//  ScanMetadataLoader.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Darwin
import Foundation

nonisolated final class LinkCountCapabilityCache: @unchecked Sendable {
    nonisolated struct ProbeResult: Sendable {
        let volumeRootPath: String?
        let supportsHardLinks: Bool?
        #if DEBUG
        let errorDescription: String?
        #endif

        init(
            volumeRootPath: String?,
            supportsHardLinks: Bool?,
            errorDescription: String? = nil
        ) {
            self.volumeRootPath = volumeRootPath
            self.supportsHardLinks = supportsHardLinks
            #if DEBUG
            self.errorDescription = errorDescription
            #endif
        }
    }

    typealias ProbeProvider = @Sendable (URL) -> ProbeResult

    private let lock = NSLock()
    private let probeProvider: ProbeProvider
    private var requiresFileSystemInfoByRootPath: [String: Bool] = [:]

    init(probeProvider: @escaping ProbeProvider = LinkCountCapabilityCache.defaultProbe) {
        self.probeProvider = probeProvider
    }

    func requiresFileSystemInfoWhenLinkCountMissing(for url: URL, diagnostics: ScanDiagnosticsContext?) -> Bool {
        let path = Self.standardizedPath(for: url)
        lock.lock()
        if let cachedRequirement = cachedRequirementLocked(for: path) {
            lock.unlock()
            return cachedRequirement
        }
        lock.unlock()

        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let probe = probeProvider(url)
        let requiresFileSystemInfo = probe.supportsHardLinks != false
        if let rootPath = Self.cacheRootPath(for: probe, path: path) {
            lock.lock()
            requiresFileSystemInfoByRootPath[rootPath] = requiresFileSystemInfo
            lock.unlock()
        }

        #if DEBUG
        diagnostics?.record(
            operation: "metadata.link_count_capability_probe",
            url: url,
            startedAt: start,
            detail: Self.diagnosticDetail(for: probe, requiresFileSystemInfo: requiresFileSystemInfo)
        )
        #endif
        return requiresFileSystemInfo
    }

    private func cachedRequirementLocked(for path: String) -> Bool? {
        var bestMatch: (rootLength: Int, requiresFileSystemInfo: Bool)?
        for (rootPath, requiresFileSystemInfo) in requiresFileSystemInfoByRootPath
        where Self.path(path, isUnder: rootPath) {
            if bestMatch == nil || rootPath.count > bestMatch!.rootLength {
                bestMatch = (rootPath.count, requiresFileSystemInfo)
            }
        }
        return bestMatch?.requiresFileSystemInfo
    }

    private static func defaultProbe(for url: URL) -> ProbeResult {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeURLKey,
                .volumeSupportsHardLinksKey
            ])
            return ProbeResult(
                volumeRootPath: values.volume?.standardizedFileURL.path,
                supportsHardLinks: values.volumeSupportsHardLinks
            )
        } catch {
            #if DEBUG
            return ProbeResult(
                volumeRootPath: nil,
                supportsHardLinks: nil,
                errorDescription: ScanWarningFactory.diagnosticErrorDescription(error)
            )
            #else
            return ProbeResult(
                volumeRootPath: nil,
                supportsHardLinks: nil
            )
            #endif
        }
    }

    #if DEBUG
    private static func diagnosticDetail(
        for probe: ProbeResult,
        requiresFileSystemInfo: Bool
    ) -> String {
        var fields = [
            "supports_hard_links=\(probe.supportsHardLinks.map(String.init) ?? "unknown")",
            "fallback_lstat=\(requiresFileSystemInfo)"
        ]
        if let volumeRootPath = probe.volumeRootPath {
            fields.append("volume=\(volumeRootPath)")
        }
        if let errorDescription = probe.errorDescription {
            fields.append("error=\(errorDescription)")
        }
        return fields.joined(separator: " ")
    }
    #endif

    private static func path(_ path: String, isUnder rootPath: String) -> Bool {
        guard rootPath != "/" else {
            return path.hasPrefix("/")
        }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func standardizedPath(for url: URL) -> String {
        normalizedRootPath(url.standardizedFileURL.path)
    }

    private static func normalizedRootPath(_ path: String) -> String {
        var normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return normalizedPath
    }

    private static func cacheRootPath(for probe: ProbeResult, path: String) -> String? {
        if let volumeRootPath = probe.volumeRootPath {
            return normalizedRootPath(volumeRootPath)
        }
        return inferredMountedVolumeRootPath(for: path)
    }

    private static func inferredMountedVolumeRootPath(for path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Volumes" {
            return "/Volumes/\(components[1])"
        }
        return nil
    }
}

nonisolated struct ScanMetadataLoader: Sendable {
    typealias FileSystemInfoProvider = @Sendable (
        URL,
        ScanDiagnosticsContext?
    ) -> (identity: FileIdentity?, linkCount: UInt64)
    typealias FileAllocatedSizeProvider = @Sendable (URL) -> Int64?

    static let scanResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .totalFileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]
    static let rootResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .totalFileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey,
        .volumeAvailableCapacityKey,
        .volumeTotalCapacityKey
    ]
    static let atomicSummaryResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .totalFileSizeKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]
    static let atomicSummaryResourceKeySet = Set(atomicSummaryResourceKeys)
    static let atomicProbeResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileSizeKey
    ]
    static let atomicProbeResourceKeySet = Set(atomicProbeResourceKeys)

    let diagnostics: ScanDiagnosticsContext?
    private let linkCountCapabilityCache: LinkCountCapabilityCache
    private let fileSystemInfoProvider: FileSystemInfoProvider
    private let fileAllocatedSizeProvider: FileAllocatedSizeProvider
    private let packageClassifier: PackageClassifier

    init(
        diagnostics: ScanDiagnosticsContext? = nil,
        linkCountCapabilityCache: LinkCountCapabilityCache = LinkCountCapabilityCache(),
        fileSystemInfoProvider: @escaping FileSystemInfoProvider = ScanMetadataLoader.defaultFileSystemInfo,
        fileAllocatedSizeProvider: @escaping FileAllocatedSizeProvider = ScanMetadataLoader.defaultFileAllocatedSize,
        packageClassifier: PackageClassifier = PackageClassifier()
    ) {
        self.diagnostics = diagnostics
        self.linkCountCapabilityCache = linkCountCapabilityCache
        self.fileSystemInfoProvider = fileSystemInfoProvider
        self.fileAllocatedSizeProvider = fileAllocatedSizeProvider
        self.packageClassifier = packageClassifier
    }

    func metadata(for url: URL, includeVolumeDetails: Bool = false) throws -> NodeMetadata {
        let keys = includeVolumeDetails ? Self.rootResourceKeys : Self.scanResourceKeys
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
            #if DEBUG
            diagnostics?.record(operation: "metadata.resource_values", url: url, startedAt: start)
            #endif
        } catch {
            #if DEBUG
            diagnostics?.record(
                operation: "metadata.resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            #endif
            throw error
        }
        return metadata(for: url, prefetchedResourceValues: values, includeVolumeDetails: includeVolumeDetails)
    }

    func atomicSummaryMetadata(for url: URL) throws -> NodeMetadata {
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.atomicSummaryResourceKeySet)
            #if DEBUG
            diagnostics?.record(operation: "metadata.atomic_resource_values", url: url, startedAt: start)
            #endif
        } catch {
            #if DEBUG
            diagnostics?.record(
                operation: "metadata.atomic_resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            #endif
            throw error
        }
        return atomicSummaryMetadata(for: url, prefetchedResourceValues: values)
    }

    func isPackageDirectory(
        at url: URL,
        hasFinderPackageFlag: Bool? = nil
    ) -> Bool {
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let classification = packageClassifier.classification(
            for: url,
            hasFinderPackageFlag: hasFinderPackageFlag
        )
        #if DEBUG
        switch classification.source {
        case .foundation:
            diagnostics?.record(operation: "metadata.package", url: url, startedAt: start)
        case .fastNegative:
            diagnostics?.record(operation: "metadata.package.fast_negative", url: url, startedAt: start)
        case .finderInfo:
            diagnostics?.record(operation: "metadata.package.finder_info", url: url, startedAt: start)
        case .extensionCache:
            diagnostics?.record(operation: "metadata.package.extension_cache", url: url, startedAt: start)
        }
        #endif
        return classification.isPackage
    }

    nonisolated func metadata(
        for url: URL,
        prefetchedResourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        loadsSymbolicLinkFileSystemInfo: Bool = true
    ) -> NodeMetadata {
        Self.nodeMetadata(
            for: url,
            resourceValues: values,
            includeVolumeDetails: includeVolumeDetails,
            loadsSymbolicLinkFileSystemInfo: loadsSymbolicLinkFileSystemInfo,
            diagnostics: diagnostics,
            linkCountCapabilityCache: linkCountCapabilityCache,
            fileSystemInfoProvider: fileSystemInfoProvider,
            fileAllocatedSizeProvider: fileAllocatedSizeProvider
        )
    }

    nonisolated func atomicSummaryMetadata(
        for url: URL,
        prefetchedResourceValues values: URLResourceValues
    ) -> NodeMetadata {
        metadata(
            for: url,
            prefetchedResourceValues: values,
            loadsSymbolicLinkFileSystemInfo: false
        )
    }

    private nonisolated static func nodeMetadata(
        for url: URL,
        resourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        loadsSymbolicLinkFileSystemInfo: Bool,
        diagnostics: ScanDiagnosticsContext? = nil,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        fileSystemInfoProvider: FileSystemInfoProvider,
        fileAllocatedSizeProvider: FileAllocatedSizeProvider
    ) -> NodeMetadata {
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        let logicalSize = Int64(values.totalFileSize ?? values.fileSize ?? 0)
        let allocatedSize = values.totalFileAllocatedSize.map(Int64.init)
            ?? values.fileAllocatedSize.map(Int64.init)
            ?? fileAllocatedSizeProvider(url)
            ?? 0
        let isReadable = values.isReadable ?? false
        var fileIdentity = Self.fileIdentity(from: values.fileResourceIdentifier)
        var linkCount = values.linkCount.map(UInt64.init) ?? 1
        if isSymbolicLink && loadsSymbolicLinkFileSystemInfo {
            let fileSystemInfo = fileSystemInfoProvider(url, diagnostics)
            fileIdentity = fileSystemInfo.identity
            linkCount = fileSystemInfo.linkCount
        } else if isDirectory && loadsSymbolicLinkFileSystemInfo {
            let fileSystemInfo = fileSystemInfoProvider(url, diagnostics)
            fileIdentity = fileSystemInfo.identity ?? fileIdentity
        } else if shouldReadFileSystemIdentity(
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            url: url,
            fileIdentity: fileIdentity,
            linkCount: values.linkCount,
            linkCountCapabilityCache: linkCountCapabilityCache,
            diagnostics: diagnostics
        ) {
            let fileSystemInfo = fileSystemInfoProvider(url, diagnostics)
            fileIdentity = fileIdentity ?? fileSystemInfo.identity
            linkCount = values.linkCount.map(UInt64.init) ?? fileSystemInfo.linkCount
        }
        let volumeCapacity: VolumeCapacitySnapshot?
        if includeVolumeDetails,
           let totalCapacity = values.volumeTotalCapacity,
           let availableCapacity = values.volumeAvailableCapacity {
            volumeCapacity = VolumeCapacitySnapshot(
                totalCapacity: Int64(totalCapacity),
                availableCapacity: Int64(availableCapacity)
            )
        } else {
            volumeCapacity = nil
        }

        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            lastModified: values.contentModificationDate,
            isReadable: isReadable,
            volumeCapacity: volumeCapacity,
            fileIdentity: fileIdentity,
            linkCount: linkCount
        )
    }

    private nonisolated static func shouldReadFileSystemIdentity(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        url: URL,
        fileIdentity: FileIdentity?,
        linkCount: Int?,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        diagnostics: ScanDiagnosticsContext?
    ) -> Bool {
        guard !isDirectory, !isSymbolicLink else { return false }
        guard let linkCount else {
            return linkCountCapabilityCache.requiresFileSystemInfoWhenLinkCountMissing(
                for: url,
                diagnostics: diagnostics
            )
        }
        return linkCount > 1 && fileIdentity == nil
    }

    private nonisolated static func defaultFileSystemInfo(
        for url: URL,
        diagnostics: ScanDiagnosticsContext? = nil
    ) -> (identity: FileIdentity?, linkCount: UInt64) {
        var fileStat = stat()
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &fileStat))
        }
        #if DEBUG
        diagnostics?.record(operation: "metadata.lstat", url: url, startedAt: start)
        #endif
        guard result == 0 else {
            return (nil, 1)
        }

        return (
            FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino)),
            max(UInt64(fileStat.st_nlink), 1)
        )
    }

    private nonisolated static func defaultFileAllocatedSize(for url: URL) -> Int64? {
        var fileStat = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &fileStat))
        }
        guard result == 0 else { return nil }

        let blocks = max(Int64(fileStat.st_blocks), 0)
        let (allocatedSize, overflow) = blocks.multipliedReportingOverflow(by: 512)
        return overflow ? Int64.max : allocatedSize
    }

    private nonisolated static func fileIdentity(
        from resourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> FileIdentity? {
        guard let identifierData = resourceIdentifier as? Data else { return nil }
        return FileIdentity(resourceIdentifier: identifierData)
    }
}

nonisolated struct NodeMetadata: Sendable {
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let lastModified: Date?
    let isReadable: Bool
    let volumeCapacity: VolumeCapacitySnapshot?
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
}

nonisolated enum FileIdentity: Hashable, Sendable {
    case resourceIdentifier(Data)
    case fileSystem(device: UInt64, inode: UInt64)

    nonisolated init(device: UInt64, inode: UInt64) {
        self = .fileSystem(device: device, inode: inode)
    }

    nonisolated init(resourceIdentifier: Data) {
        self = .resourceIdentifier(resourceIdentifier)
    }

    nonisolated var isFileSystemIdentity: Bool {
        if case .fileSystem = self {
            return true
        }
        return false
    }
}
