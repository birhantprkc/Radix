import SwiftUI

enum WorkspaceFocusTarget: Hashable {
    case chart
    case contents
}

enum ChartViewportAction {
    case zoomIn
    case zoomOut
    case reset
}

private struct FileListFilterActionKey: FocusedValueKey {
    typealias Value = (FileBrowserFindTarget) -> Void
}

private struct ChartViewportActionKey: FocusedValueKey {
    typealias Value = (ChartViewportAction) -> Void
}

extension FocusedValues {
    var fileListFilterAction: ((FileBrowserFindTarget) -> Void)? {
        get { self[FileListFilterActionKey.self] }
        set { self[FileListFilterActionKey.self] = newValue }
    }

    var chartViewportAction: ((ChartViewportAction) -> Void)? {
        get { self[ChartViewportActionKey.self] }
        set { self[ChartViewportActionKey.self] = newValue }
    }
}
