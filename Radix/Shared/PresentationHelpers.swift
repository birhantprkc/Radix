import Foundation
import SwiftUI

private let cachedHomePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

extension ScanTarget {
    var sidebarTitle: String {
        switch url.path {
        case "/":
            return displayName
        case cachedHomePath:
            return String(localized: "Home", comment: "Sidebar name for the user's home folder.")
        case cachedHomePath + "/Desktop":
            return String(localized: "Desktop", comment: "Sidebar name for the user's Desktop folder.")
        case cachedHomePath + "/Documents":
            return String(localized: "Documents", comment: "Sidebar name for the user's Documents folder.")
        case cachedHomePath + "/Downloads":
            return String(localized: "Downloads", comment: "Sidebar name for the user's Downloads folder.")
        case cachedHomePath + "/Library":
            return String(localized: "Library", comment: "Sidebar name for the user's Library folder.")
        case "/Applications":
            return String(localized: "Applications", comment: "Sidebar name for the system Applications folder.")
        default:
            return displayName
        }
    }

    var sidebarSymbolName: String {
        switch url.path {
        case "/":
            return "internaldrive.fill"
        case cachedHomePath:
            return "house.fill"
        case cachedHomePath + "/Desktop":
            return "desktopcomputer"
        case cachedHomePath + "/Documents":
            return "doc.on.doc.fill"
        case cachedHomePath + "/Downloads":
            return "arrow.down.circle.fill"
        case cachedHomePath + "/Library":
            return "books.vertical.fill"
        case "/Applications":
            return "square.grid.2x2.fill"
        default:
            return kind == .volume ? "externaldrive.fill" : "folder.fill"
        }
    }

}

extension ScanWarningCategory {
    var symbolName: String {
        switch self {
        case .permissionDenied:
            return "hand.raised.fill"
        case .fileSystem:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum RadixSystemImages {
    static var quickLook: String {
        FileNodeAction.quickLook.systemImageName
    }

    static var revealInFinder: String {
        FileNodeAction.revealInFinder.systemImageName
    }

    static var copyPath: String {
        FileNodeAction.copyPath.systemImageName
    }
}

extension FullDiskAccessStatus {
    var fullDiskAccessBadgeTitle: String {
        switch self {
        case .granted:
            return String(localized: "Enabled", comment: "Full Disk Access status badge when permission is granted.")
        case .notGranted:
            return String(localized: "Not Enabled", comment: "Full Disk Access status badge when permission is not granted.")
        case .unknown:
            return String(localized: "Unknown", comment: "Full Disk Access status badge when permission cannot be determined.")
        }
    }

    var fullDiskAccessSettingsSummary: String {
        switch self {
        case .granted:
            return String(localized: "Full Disk Access is enabled.", comment: "Full Disk Access settings summary when permission is granted.")
        case .notGranted:
            return String(localized: "Full Disk Access is not enabled.", comment: "Full Disk Access settings summary when permission is not granted.")
        case .unknown:
            return String(localized: "Full Disk Access could not be verified.", comment: "Full Disk Access settings summary when permission cannot be determined.")
        }
    }

    var fullDiskAccessSystemImage: String {
        switch self {
        case .granted:
            return "checkmark.circle.fill"
        case .notGranted:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var fullDiskAccessColor: Color {
        switch self {
        case .granted:
            return .green
        case .notGranted:
            return .orange
        case .unknown:
            return .secondary
        }
    }
}
