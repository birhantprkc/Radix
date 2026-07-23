import SwiftUI

struct FileBrowserSearchFilterBar: View {
    @Binding var scope: FileBrowserFindTarget
    @Binding var query: FileBrowserQuery
    let isLoading: Bool
    @FocusState.Binding var isFocused: Bool

    @State private var showsFilterEditor = false

    private var scopeLabel: String {
        switch scope {
        case .currentContents:
            String(localized: "Current Contents", comment: "Search scope label for the currently visible directory contents.")
        case .entireScan:
            String(localized: "Entire Scan", comment: "Search scope label for all items in the scan.")
        }
    }

    private var prompt: String {
        switch scope {
        case .currentContents:
            String(localized: "Filter current contents", comment: "Search field placeholder for filtering the current directory contents.")
        case .entireScan:
            String(localized: "Search entire scan", comment: "Search field placeholder for searching all scanned items.")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                scopeMenu

                TextField(prompt, text: $query.text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                if !query.text.isEmpty {
                    clearTextButton
                }

                filterEditorButton
            }

            if query.hasStructuredFilters {
                HStack(spacing: 6) {
                    if let itemKind = query.itemKind {
                        filterChip(title: itemKind.title, accessibilityLabel: "Remove kind filter") {
                            query.itemKind = nil
                        }
                    }

                    if let allocatedSize = query.allocatedSize {
                        sizeFilterChip(allocatedSize)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var scopeMenu: some View {
        Menu {
            Button("Current Contents") {
                scope = .currentContents
                isFocused = true
            }

            Button("Entire Scan") {
                scope = .entireScan
                isFocused = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: scope == .currentContents ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                Text(scopeLabel)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
    }

    private var clearTextButton: some View {
        Button {
            query.text = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(scope == .currentContents ? "Clear current contents filter" : "Clear entire scan search")
        .accessibilityLabel(scope == .currentContents ? "Clear current contents filter" : "Clear entire scan search")
    }

    private var filterEditorButton: some View {
        Button {
            showsFilterEditor = true
        } label: {
            Image(systemName: query.hasStructuredFilters
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(query.hasStructuredFilters ? Color.accentColor : .secondary)
        .help("Search Filters")
        .accessibilityLabel("Search Filters")
        .popover(isPresented: $showsFilterEditor, arrowEdge: .bottom) {
            FileBrowserFilterEditor(query: $query)
        }
    }

    private func sizeFilterChip(_ filter: FileBrowserAllocatedSizeFilter) -> some View {
        filterChip(
            title: "\(String(localized: "Allocated")) \(filter.relation.symbol) \(RadixFormatters.size(filter.bytes))",
            accessibilityLabel: "Remove size filter"
        ) {
            query.allocatedSize = nil
        }
    }

    private func filterChip(
        title: String,
        accessibilityLabel: LocalizedStringKey,
        remove: @escaping () -> Void
    ) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct FileBrowserFilterEditor: View {
    @Binding var query: FileBrowserQuery
    @Environment(\.dismiss) private var dismiss

    @State private var itemKind: FileBrowserItemKindFilter?
    @State private var sizeIsEnabled: Bool
    @State private var sizeRelation: FileBrowserSizeRelation
    @State private var sizeValue: Double
    @State private var sizeUnit: FileBrowserSizeUnit

    init(query: Binding<FileBrowserQuery>) {
        _query = query
        let draft = Self.draftValues(for: query.wrappedValue.allocatedSize)
        _itemKind = State(initialValue: query.wrappedValue.itemKind)
        _sizeIsEnabled = State(initialValue: query.wrappedValue.allocatedSize != nil)
        _sizeRelation = State(initialValue: draft.relation)
        _sizeValue = State(initialValue: draft.value)
        _sizeUnit = State(initialValue: draft.unit)
    }

    private var sizeBytes: Int64? {
        let bytes = sizeValue * Double(sizeUnit.bytes)
        guard sizeValue.isFinite,
              sizeValue >= 0,
              bytes <= Double(Int64.max) else {
            return nil
        }
        return Int64(bytes.rounded())
    }

    private var canApply: Bool {
        !sizeIsEnabled || sizeBytes != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search Filters")
                .font(.headline)

            Form {
                Picker("Kind", selection: $itemKind) {
                    Text("Any Item").tag(nil as FileBrowserItemKindFilter?)
                    Text("File").tag(FileBrowserItemKindFilter.file as FileBrowserItemKindFilter?)
                    Text("Folder").tag(FileBrowserItemKindFilter.folder as FileBrowserItemKindFilter?)
                    Text("Package").tag(FileBrowserItemKindFilter.package as FileBrowserItemKindFilter?)
                }

                Toggle("Size", isOn: $sizeIsEnabled)

                if sizeIsEnabled {
                    Picker("Condition", selection: $sizeRelation) {
                        Text("Greater Than").tag(FileBrowserSizeRelation.greaterThan)
                        Text("At Least").tag(FileBrowserSizeRelation.atLeast)
                        Text("Less Than").tag(FileBrowserSizeRelation.lessThan)
                        Text("At Most").tag(FileBrowserSizeRelation.atMost)
                    }

                    LabeledContent("Value") {
                        HStack(spacing: 6) {
                            TextField(
                                "Value",
                                value: $sizeValue,
                                format: .number.precision(.fractionLength(0...2))
                            )
                            .frame(width: 90)

                            Picker("", selection: $sizeUnit) {
                                ForEach(FileBrowserSizeUnit.allCases) { unit in
                                    Text(verbatim: unit.title).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 75)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }

                Spacer()

                Button("Apply") {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func apply() {
        var updatedQuery = query
        updatedQuery.itemKind = itemKind
        updatedQuery.allocatedSize = sizeIsEnabled
            ? sizeBytes.map { FileBrowserAllocatedSizeFilter(relation: sizeRelation, bytes: $0) }
            : nil
        query = updatedQuery
        dismiss()
    }

    private static func draftValues(
        for filter: FileBrowserAllocatedSizeFilter?
    ) -> (relation: FileBrowserSizeRelation, value: Double, unit: FileBrowserSizeUnit) {
        guard let filter else {
            return (.greaterThan, 500, .megabytes)
        }

        let unit = FileBrowserSizeUnit.bestUnit(for: filter.bytes)
        return (
            filter.relation,
            Double(filter.bytes) / Double(unit.bytes),
            unit
        )
    }
}

private enum FileBrowserSizeUnit: CaseIterable, Identifiable {
    case kilobytes
    case megabytes
    case gigabytes
    case terabytes

    var id: Self { self }

    var title: String {
        switch self {
        case .kilobytes: "KB"
        case .megabytes: "MB"
        case .gigabytes: "GB"
        case .terabytes: "TB"
        }
    }

    var bytes: Int64 {
        switch self {
        case .kilobytes: 1_000
        case .megabytes: 1_000_000
        case .gigabytes: 1_000_000_000
        case .terabytes: 1_000_000_000_000
        }
    }

    static func bestUnit(for bytes: Int64) -> Self {
        for unit in allCases.reversed() where bytes >= unit.bytes && bytes.isMultiple(of: unit.bytes) {
            return unit
        }
        return .megabytes
    }
}

private extension FileBrowserItemKindFilter {
    var title: String {
        switch self {
        case .file:
            String(localized: "File", comment: "Search filter for regular files.")
        case .folder:
            String(localized: "Folder", comment: "Search filter for folders.")
        case .package:
            String(localized: "Package", comment: "Search filter for app bundles and packages.")
        }
    }
}

private extension FileBrowserSizeRelation {
    var symbol: String {
        switch self {
        case .greaterThan: ">"
        case .atLeast: "≥"
        case .lessThan: "<"
        case .atMost: "≤"
        }
    }
}
