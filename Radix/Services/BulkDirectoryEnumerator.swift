//
//  BulkDirectoryEnumerator.swift
//  Radix
//
//  Created by Codex on 7/9/26.
//

import Darwin
import Foundation

/// Immediate-child enumeration backed by `getattrlistbulk(2)`.
///
/// Foundation's URL enumerator is a good compatibility path, but a scanner pays
/// heavily for materializing resource values one URL at a time. Darwin can return
/// the directory entry and the metadata Radix needs in the same kernel operation.
/// Unsupported filesystems return `nil` so callers can transparently fall back.
nonisolated enum BulkDirectoryEnumerator {
    struct Batch: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
    }

    struct Result: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
    }

    enum StreamError: Error {
        case unavailable
    }

    /// Single-consumer cursor over the batches returned by `getattrlistbulk(2)`.
    /// Dropping a partially consumed cursor closes its descriptor, which lets
    /// threshold probes stop without reading or retaining the rest of a wide directory.
    final class Cursor: @unchecked Sendable {
        private let directoryURL: URL
        private let includeHiddenFiles: Bool
        private let loadsPackageMetadata: Bool
        private let metadataLoader: ScanMetadataLoader
        private let lock = NSLock()
        private var descriptor: Int32
        private var attributes = requestedAttributes
        private var isFinished = false
        private var buffer: UnsafeMutableRawBufferPointer?
        private let forcedUnavailableAfterBatchCount: Int?
        private var successfulBatchCount = 0

        fileprivate init(
            directoryURL: URL,
            includeHiddenFiles: Bool,
            loadsPackageMetadata: Bool,
            metadataLoader: ScanMetadataLoader,
            descriptor: Int32,
            forcedUnavailableAfterBatchCount: Int?
        ) {
            self.directoryURL = directoryURL
            self.includeHiddenFiles = includeHiddenFiles
            self.loadsPackageMetadata = loadsPackageMetadata
            self.metadataLoader = metadataLoader
            self.descriptor = descriptor
            self.forcedUnavailableAfterBatchCount = forcedUnavailableAfterBatchCount
            buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: bufferCapacity,
                alignment: 8
            )
        }

        deinit {
            closeDescriptor()
            releaseBuffer()
        }

        func invalidate() {
            lock.lock()
            isFinished = true
            closeDescriptor()
            releaseBuffer()
            lock.unlock()
        }

        func nextBatch(cancellationCheck: CancellationCheck) throws -> Batch? {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return nil }
            try cancellationCheck()
            if let forcedUnavailableAfterBatchCount,
               successfulBatchCount == forcedUnavailableAfterBatchCount {
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                throw StreamError.unavailable
            }

            guard let buffer,
                  let bufferAddress = buffer.baseAddress else {
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                throw StreamError.unavailable
            }
            let count = getattrlistbulk(
                descriptor,
                &attributes,
                bufferAddress,
                buffer.count,
                UInt64(FSOPT_PACK_INVAL_ATTRS)
            )
            if count < 0 {
                let errorCode = errno
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                if unsupportedErrors.contains(errorCode) {
                    throw StreamError.unavailable
                }
                throw posixError(errorCode, url: directoryURL)
            }
            guard count > 0 else {
                try cancellationCheck()
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                return nil
            }

            var entries: [DirectoryEntry] = []
            var enumeratedItemCount = 0
            do {
                guard try parseBatch(
                    bufferAddress: UnsafeRawPointer(bufferAddress),
                    bufferByteCount: buffer.count,
                    entryCount: Int(count),
                    directoryURL: directoryURL,
                    includeHiddenFiles: includeHiddenFiles,
                    loadsPackageMetadata: loadsPackageMetadata,
                    metadataLoader: metadataLoader,
                    entries: &entries,
                    enumeratedItemCount: &enumeratedItemCount,
                    cancellationCheck: cancellationCheck
                ) else {
                    isFinished = true
                    closeDescriptor()
                    throw StreamError.unavailable
                }
            } catch {
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                throw error
            }
            successfulBatchCount += 1
            return Batch(
                entries: entries,
                enumeratedItemCount: enumeratedItemCount
            )
        }

        private func closeDescriptor() {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }

        private func releaseBuffer() {
            buffer?.deallocate()
            buffer = nil
        }
    }

    private static let bufferCapacity = 64 * 1_024
    private static let unsupportedErrors: Set<Int32> = [EINVAL, ENOTSUP, ENOSYS]

    static func directoryEntries(
        at directoryURL: URL,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool = true,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        forcedUnavailableAfterBatchCount: Int? = nil
    ) throws -> Result? {
        var entries: [DirectoryEntry] = []
        var enumeratedItemCount = 0
        let cursor = try makeCursor(
            at: directoryURL,
            includeHiddenFiles: includeHiddenFiles,
            loadsPackageMetadata: loadsPackageMetadata,
            metadataLoader: metadataLoader,
            cancellationCheck: cancellationCheck,
            forcedUnavailableAfterBatchCount: forcedUnavailableAfterBatchCount
        )
        do {
            while let batch = try cursor.nextBatch(cancellationCheck: cancellationCheck) {
                entries.append(contentsOf: batch.entries)
                enumeratedItemCount += batch.enumeratedItemCount
            }
        } catch StreamError.unavailable {
            return nil
        }
        return Result(
            entries: entries,
            enumeratedItemCount: enumeratedItemCount
        )
    }

    static func makeCursor(
        at directoryURL: URL,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool = true,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        forcedUnavailableAfterBatchCount: Int? = nil
    ) throws -> Cursor {
        try cancellationCheck()
        #if DEBUG
        let openStart = metadataLoader.diagnostics?.start()
        #endif
        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixError(errno, url: directoryURL)
        }
        #if DEBUG
        metadataLoader.diagnostics?.record(
            operation: "bulk.cursor.open",
            url: directoryURL,
            startedAt: openStart
        )
        #endif
        return Cursor(
            directoryURL: directoryURL,
            includeHiddenFiles: includeHiddenFiles,
            loadsPackageMetadata: loadsPackageMetadata,
            metadataLoader: metadataLoader,
            descriptor: descriptor,
            forcedUnavailableAfterBatchCount: forcedUnavailableAfterBatchCount
        )
    }

    private static var requestedAttributes: attrlist {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = requiredCommonAttributes
        attributes.fileattr = requiredFileAttributes
        return attributes
    }

    private static var requiredCommonAttributes: attrgroup_t {
        var attributes = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attributes |= attrgroup_t(ATTR_CMN_ERROR)
        attributes |= attrgroup_t(ATTR_CMN_NAME)
        attributes |= attrgroup_t(ATTR_CMN_DEVID)
        attributes |= attrgroup_t(ATTR_CMN_OBJTYPE)
        attributes |= attrgroup_t(ATTR_CMN_MODTIME)
        attributes |= attrgroup_t(ATTR_CMN_FLAGS)
        attributes |= attrgroup_t(ATTR_CMN_USERACCESS)
        attributes |= attrgroup_t(ATTR_CMN_FILEID)
        return attributes
    }

    private static var requiredFileAttributes: attrgroup_t {
        attrgroup_t(
            ATTR_FILE_LINKCOUNT |
            ATTR_FILE_TOTALSIZE |
            ATTR_FILE_ALLOCSIZE
        )
    }

    /// Bulk enumeration can succeed even when an individual filesystem cannot
    /// vend every requested attribute. Those default-packed values are not a
    /// safe substitute for scanner metadata, so select the Foundation path.
    static func hasRequiredMetadataAttributes(
        _ returned: attribute_set_t,
        objectType: fsobj_type_t
    ) -> Bool {
        guard returned.commonattr & requiredCommonAttributes == requiredCommonAttributes else {
            return false
        }
        return objectType == VDIR.rawValue ||
            returned.fileattr & requiredFileAttributes == requiredFileAttributes
    }

    private static func parseBatch(
        bufferAddress: UnsafeRawPointer,
        bufferByteCount: Int,
        entryCount: Int,
        directoryURL: URL,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool,
        metadataLoader: ScanMetadataLoader,
        entries: inout [DirectoryEntry],
        enumeratedItemCount: inout Int,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        let bufferEnd = bufferAddress.advanced(by: bufferByteCount)
        var entryAddress = bufferAddress

        for index in 0..<entryCount {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            guard MemoryLayout<UInt32>.size <= entryAddress.distance(to: bufferEnd) else {
                return false
            }
            let entryLength = Int(entryAddress.loadUnaligned(as: UInt32.self))
            guard entryLength >= MemoryLayout<UInt32>.size,
                  entryLength <= entryAddress.distance(to: bufferEnd) else {
                return false
            }

            let entryEnd = entryAddress.advanced(by: entryLength)
            guard let parsed = parsedEntry(
                at: entryAddress,
                end: entryEnd,
                directoryURL: directoryURL,
                loadsPackageMetadata: loadsPackageMetadata,
                metadataLoader: metadataLoader
            ) else {
                return false
            }
            enumeratedItemCount += 1

            if includeHiddenFiles || !parsed.isHidden {
                entries.append(parsed.entry)
            }
            entryAddress = entryEnd
        }
        return true
    }

    private static func parsedEntry(
        at entryAddress: UnsafeRawPointer,
        end entryEnd: UnsafeRawPointer,
        directoryURL: URL,
        loadsPackageMetadata: Bool,
        metadataLoader: ScanMetadataLoader
    ) -> (entry: DirectoryEntry, isHidden: Bool)? {
        var cursor = AttributeCursor(
            current: entryAddress.advanced(by: MemoryLayout<UInt32>.size),
            end: entryEnd
        )

        // ATTR_CMN_RETURNED_ATTRS is always first. For getattrlistbulk,
        // ATTR_CMN_ERROR immediately follows it; remaining values follow the
        // declaration order from getattrlist(2). FSOPT_PACK_INVAL_ATTRS keeps
        // this fixed portion stable even when a filesystem lacks an attribute.
        guard let returned: attribute_set_t = cursor.read(),
              let entryError: UInt32 = cursor.read() else {
            return nil
        }

        let nameReferenceAddress = cursor.current
        guard let nameReference: attrreference_t = cursor.read(),
              let name = string(
                  reference: nameReference,
                  referenceAddress: nameReferenceAddress,
                  entryAddress: entryAddress,
                  entryEnd: entryEnd
              ),
              let deviceID: dev_t = cursor.read(),
              let objectType: fsobj_type_t = cursor.read(),
              let modificationTime: timespec = cursor.read(),
              let flags: UInt32 = cursor.read(),
              let userAccess: UInt32 = cursor.read(),
              let fileID: UInt64 = cursor.read() else {
            return nil
        }

        var fileLinkCount: UInt32 = 1
        var fileLogicalSize: off_t = 0
        var fileAllocatedSize: off_t = 0
        if objectType == VREG.rawValue || returned.fileattr != 0 {
            // Once a file-attribute payload is present, FSOPT_PACK_INVAL_ATTRS
            // physically packs every requested field in that group. Advance
            // through the complete layout before inspecting `returned`.
            guard let linkCount: UInt32 = cursor.read(),
                  let logicalSize: off_t = cursor.read(),
                  let allocatedSize: off_t = cursor.read() else {
                return nil
            }
            fileLinkCount = linkCount
            fileLogicalSize = logicalSize
            fileAllocatedSize = allocatedSize
        }

        let isDirectory = objectType == VDIR.rawValue
        let isSymbolicLink = objectType == VLNK.rawValue
        let directoryHint: URL.DirectoryHint = isDirectory ? .isDirectory : .notDirectory
        let url = directoryURL.appending(path: name, directoryHint: directoryHint)
        let isHidden = name.first == "." || (flags & UInt32(UF_HIDDEN)) != 0

        if entryError != 0 {
            guard entryError <= UInt32(Int32.max) else { return nil }
            return (
                DirectoryEntry(
                    url: url,
                    metadata: nil,
                    localizedEnumerationError: posixError(Int32(entryError), url: url),
                    isDirectoryHint: isDirectory
                ),
                isHidden
            )
        }

        guard hasRequiredMetadataAttributes(returned, objectType: objectType) else {
            return nil
        }

        let logicalSize: off_t = isDirectory ? 0 : fileLogicalSize
        let allocatedSize: off_t = isDirectory ? 0 : fileAllocatedSize
        let lastModified = Date(
            timeIntervalSince1970: Double(modificationTime.tv_sec) +
                Double(modificationTime.tv_nsec) / 1_000_000_000
        )

        let metadata = NodeMetadata(
            isDirectory: isDirectory,
            isPackage: isDirectory && loadsPackageMetadata && metadataLoader.isPackageDirectory(at: url),
            isSymbolicLink: isSymbolicLink,
            logicalSize: max(Int64(logicalSize), 0),
            allocatedSize: max(Int64(allocatedSize), 0),
            lastModified: lastModified,
            isReadable: (userAccess & UInt32(R_OK)) != 0,
            volumeUsedCapacity: nil,
            fileIdentity: FileIdentity(
                device: UInt64(truncatingIfNeeded: deviceID),
                inode: fileID
            ),
            linkCount: isDirectory ? 1 : max(UInt64(fileLinkCount), 1)
        )
        return (DirectoryEntry(url: url, metadata: metadata), isHidden)
    }

    private static func string(
        reference: attrreference_t,
        referenceAddress: UnsafeRawPointer,
        entryAddress: UnsafeRawPointer,
        entryEnd: UnsafeRawPointer
    ) -> String? {
        guard reference.attr_dataoffset >= 0 else { return nil }
        let dataOffset = Int(reference.attr_dataoffset)
        guard dataOffset <= referenceAddress.distance(to: entryEnd) else { return nil }
        let start = referenceAddress.advanced(by: dataOffset)
        let byteCount = Int(reference.attr_length)
        guard start >= entryAddress,
              start <= entryEnd,
              byteCount <= start.distance(to: entryEnd),
              byteCount > 0 else {
            return nil
        }

        let bytes = UnsafeRawBufferPointer(start: start, count: byteCount)
        let stringByteCount = bytes.last == 0 ? byteCount - 1 : byteCount
        return String(decoding: bytes.prefix(stringByteCount), as: UTF8.self)
    }

    private static func posixError(_ code: Int32, url: URL) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSURLErrorKey: url]
        )
    }
}

private nonisolated struct AttributeCursor {
    var current: UnsafeRawPointer
    let end: UnsafeRawPointer

    mutating func read<T>() -> T? {
        let size = MemoryLayout<T>.size
        let alignedSize = (size + 3) & ~3
        guard size <= current.distance(to: end),
              alignedSize <= current.distance(to: end) else {
            return nil
        }
        let value = current.loadUnaligned(as: T.self)
        current = current.advanced(by: alignedSize)
        return value
    }
}
