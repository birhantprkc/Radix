//
//  FileNodeRecord.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated struct FileNodeRecord: Equatable, Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let allocatedSize: Int64
    let unduplicatedAllocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let lastModified: Date?
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
    let isPackage: Bool
    let isAccessible: Bool
    let isSelfAccessible: Bool
    let isSynthetic: Bool
    let isAutoSummarized: Bool

    init(
        id: String,
        url: URL,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        logicalSize: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        isSelfAccessible: Bool,
        isSynthetic: Bool,
        isAutoSummarized: Bool
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.allocatedSize = allocatedSize
        self.unduplicatedAllocatedSize = unduplicatedAllocatedSize ?? allocatedSize
        self.logicalSize = logicalSize
        self.descendantFileCount = descendantFileCount
        self.lastModified = lastModified
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.isPackage = isPackage
        self.isAccessible = isAccessible
        self.isSelfAccessible = isSelfAccessible
        self.isSynthetic = isSynthetic
        self.isAutoSummarized = isAutoSummarized
    }

    var itemKind: String {
        if isSynthetic {
            return String(localized: "System Data", comment: "Kind label for storage that cannot be attributed to a regular file.")
        }
        if isAutoSummarized {
            return String(localized: "Summarized", comment: "Kind label for a directory whose contents are summarized for performance.")
        }
        if isSymbolicLink {
            return String(localized: "Alias", comment: "Kind label for a symbolic link.")
        }
        if isPackage {
            return String(localized: "Package", comment: "Kind label for an app bundle or package.")
        }
        return isDirectory
            ? String(localized: "Folder", comment: "Kind label for a directory.")
            : String(localized: "File", comment: "Kind label for a regular file.")
    }

    var supportsFileActions: Bool {
        !isSynthetic
    }

    static func directory(
        id: String,
        url: URL,
        name: String,
        children: [FileNodeRecord],
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        childrenAreSorted: Bool = false
    ) -> FileNodeRecord {
        let sortedChildren = childrenAreSorted ? children : FileTreeStore.sortedChildren(children)
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var childrenAreAccessible = true
        for child in sortedChildren {
            allocatedSize += child.allocatedSize
            logicalSize += child.logicalSize
            childrenAreAccessible = childrenAreAccessible && child.isAccessible
            if child.isDirectory {
                descendantFileCount += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                descendantFileCount += 1
            }
        }
        let isFullyAccessible = isAccessible && childrenAreAccessible

        return FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isFullyAccessible,
            isSelfAccessible: isAccessible,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}

extension FileNodeRecord {
    nonisolated var systemImageName: String {
        if isSynthetic {
            return "internaldrive.fill"
        }
        if isSymbolicLink {
            return "arrowshape.turn.up.right.circle.fill"
        }
        if isPackage {
            return "shippingbox.fill"
        }
        return isDirectory ? "folder.fill" : "doc.fill"
    }

    var secondaryStatusText: String? {
        if isSynthetic {
            return String(localized: "Estimated from volume usage", comment: "Secondary status shown for system storage estimated from volume usage.")
        }
        if isAutoSummarized {
            return String(localized: "Summarized (\(descendantFileCount) files)", comment: "Secondary status showing how many files are represented by a summarized directory.")
        }
        if !isAccessible {
            return String(localized: "Limited access", comment: "Secondary status for a file or folder that could not be fully read.")
        }
        return nil
    }

    var accessDescription: String {
        if isSynthetic {
            return String(localized: "Estimated", comment: "Metadata value indicating that storage is estimated.")
        }
        return isAccessible
            ? String(localized: "Readable", comment: "Metadata value indicating that a file or folder is readable.")
            : String(localized: "Limited", comment: "Metadata value indicating that access to a file or folder is limited.")
    }

}
