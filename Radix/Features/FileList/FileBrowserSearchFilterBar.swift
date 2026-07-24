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
            HStack(spacing: 5) {
                Image(systemName: query.hasStructuredFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                Text("Filters")
                if query.structuredFilterCount > 0 {
                    Text(verbatim: "(\(query.structuredFilterCount))")
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .foregroundStyle(query.hasStructuredFilters ? Color.accentColor : .secondary)
        .help("Search Filters")
        .accessibilityLabel("Search Filters")
        .popover(isPresented: $showsFilterEditor, arrowEdge: .bottom) {
            FileBrowserFilterEditor(query: $query)
        }
    }
}

private struct FileBrowserFilterEditor: View {
    @Binding var query: FileBrowserQuery
    @State private var sizeRelation: FileBrowserSizeRelation
    @State private var sizeValue: Double?
    @State private var sizeUnit: FileBrowserSizeUnit

    init(query: Binding<FileBrowserQuery>) {
        _query = query
        let filter = query.wrappedValue.allocatedSize
        let unit = FileBrowserSizeUnit.bestUnit(for: filter?.bytes ?? 0)
        _sizeRelation = State(initialValue: filter?.relation ?? .greaterThan)
        _sizeValue = State(initialValue: filter.map { Double($0.bytes) / Double(unit.bytes) })
        _sizeUnit = State(initialValue: unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search Filters")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 14) {
                kindFilterRow
                sizeFilterRow
            }

            if query.hasStructuredFilters {
                Divider()

                Button("Clear Filters") {
                    sizeValue = nil
                    sizeRelation = .greaterThan
                    sizeUnit = .megabytes
                    query.itemKind = nil
                    query.allocatedSize = nil
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private var kindFilterRow: some View {
        GridRow {
            Text("Kind")

            Picker("", selection: itemKindBinding) {
                Text("Any").tag(nil as FileBrowserItemKindFilter?)
                Text("File").tag(FileBrowserItemKindFilter.file as FileBrowserItemKindFilter?)
                Text("Folder").tag(FileBrowserItemKindFilter.folder as FileBrowserItemKindFilter?)
                Text("Package").tag(FileBrowserItemKindFilter.package as FileBrowserItemKindFilter?)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .gridCellColumns(3)
        }
    }

    private var sizeFilterRow: some View {
        GridRow {
            Text("Size")

            Picker("", selection: $sizeRelation) {
                Text("Greater Than").tag(FileBrowserSizeRelation.greaterThan)
                Text("At Least").tag(FileBrowserSizeRelation.atLeast)
                Text("Less Than").tag(FileBrowserSizeRelation.lessThan)
                Text("At Most").tag(FileBrowserSizeRelation.atMost)
            }
            .labelsHidden()
            .frame(minWidth: 120, maxWidth: .infinity)

            TextField(
                "Any",
                value: $sizeValue,
                format: .number.precision(.fractionLength(0...2))
            )
            .frame(width: 80)

            Picker("", selection: $sizeUnit) {
                ForEach(FileBrowserSizeUnit.allCases) { unit in
                    Text(verbatim: unit.title).tag(unit)
                }
            }
            .labelsHidden()
            .frame(width: 70)
        }
        .onChange(of: sizeRelation) {
            updateSizeFilter()
        }
        .onChange(of: sizeValue) {
            updateSizeFilter()
        }
        .onChange(of: sizeUnit) {
            updateSizeFilter()
        }
    }

    private var itemKindBinding: Binding<FileBrowserItemKindFilter?> {
        Binding(
            get: { query.itemKind },
            set: { query.itemKind = $0 }
        )
    }

    private func updateSizeFilter() {
        guard let sizeValue,
              sizeValue.isFinite,
              sizeValue >= 0,
              sizeValue <= Double(Int64.max) / Double(sizeUnit.bytes) else {
            query.allocatedSize = nil
            return
        }

        query.allocatedSize = FileBrowserAllocatedSizeFilter(
            relation: sizeRelation,
            bytes: Int64((sizeValue * Double(sizeUnit.bytes)).rounded())
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

private extension FileBrowserQuery {
    var structuredFilterCount: Int {
        (itemKind == nil ? 0 : 1) + (allocatedSize == nil ? 0 : 1)
    }
}
