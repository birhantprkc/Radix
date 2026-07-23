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
                adaptiveFilterSummary
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
            HStack(spacing: 4) {
                Image(systemName: query.hasStructuredFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                if query.structuredFilterCount > 0 {
                    Text(verbatim: "\(query.structuredFilterCount)")
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(query.hasStructuredFilters ? Color.accentColor : .secondary)
        .help("Search Filters")
        .accessibilityLabel("Search Filters")
        .popover(isPresented: $showsFilterEditor, arrowEdge: .bottom) {
            FileBrowserFilterEditor(query: $query)
        }
    }

    private var adaptiveFilterSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                filterChips
                Spacer(minLength: 0)
            }

            HStack {
                Button {
                    showsFilterEditor = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        Text("Search Filters")
                        Text(verbatim: "(\(query.structuredFilterCount))")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var filterChips: some View {
        if let itemKind = query.itemKind {
            filterChip(title: itemKind.title, accessibilityLabel: "Remove kind filter") {
                query.itemKind = nil
            }
        }

        if let allocatedSize = query.allocatedSize {
            sizeFilterChip(allocatedSize)
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
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct FileBrowserFilterEditor: View {
    @Binding var query: FileBrowserQuery
    @Environment(\.dismiss) private var dismiss

    private var allFiltersAreActive: Bool {
        query.itemKind != nil && query.allocatedSize != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Filters")
                .font(.headline)

            if query.hasStructuredFilters {
                ScrollView {
                    VStack(spacing: 8) {
                        if query.itemKind != nil {
                            kindFilterRow
                        }

                        if query.allocatedSize != nil {
                            FileBrowserSizeFilterRow(filter: $query.allocatedSize)
                        }
                    }
                }
                .frame(height: min(CGFloat(query.structuredFilterCount) * 48, 240))

                Divider()
            }

            HStack {
                if query.hasStructuredFilters {
                    Button("Clear All") {
                        query.itemKind = nil
                        query.allocatedSize = nil
                    }
                }

                Spacer()

                addFilterMenu

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private var kindFilterRow: some View {
        HStack(spacing: 8) {
            Text("Kind")
                .frame(width: 45, alignment: .leading)

            Picker("", selection: itemKindBinding) {
                Text("File").tag(FileBrowserItemKindFilter.file)
                Text("Folder").tag(FileBrowserItemKindFilter.folder)
                Text("Package").tag(FileBrowserItemKindFilter.package)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            removeFilterButton(accessibilityLabel: "Remove kind filter") {
                query.itemKind = nil
            }
        }
        .filterRowStyle()
    }

    private var itemKindBinding: Binding<FileBrowserItemKindFilter> {
        Binding(
            get: { query.itemKind ?? .file },
            set: { query.itemKind = $0 }
        )
    }

    private var addFilterMenu: some View {
        Menu {
            if query.itemKind == nil {
                Button("Kind") {
                    query.itemKind = .file
                }
            }

            if query.allocatedSize == nil {
                Button("Size") {
                    query.allocatedSize = FileBrowserAllocatedSizeFilter(
                        relation: .greaterThan,
                        bytes: 500_000_000
                    )
                }
            }
        } label: {
            Label("Add Filter", systemImage: "plus")
        }
        .disabled(allFiltersAreActive)
    }
}

private struct FileBrowserSizeFilterRow: View {
    @Binding var filter: FileBrowserAllocatedSizeFilter?
    @State private var unit: FileBrowserSizeUnit

    init(filter: Binding<FileBrowserAllocatedSizeFilter?>) {
        _filter = filter
        _unit = State(initialValue: FileBrowserSizeUnit.bestUnit(for: filter.wrappedValue?.bytes ?? 0))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Size")
                .frame(width: 45, alignment: .leading)

            Picker("", selection: relationBinding) {
                Text("Greater Than").tag(FileBrowserSizeRelation.greaterThan)
                Text("At Least").tag(FileBrowserSizeRelation.atLeast)
                Text("Less Than").tag(FileBrowserSizeRelation.lessThan)
                Text("At Most").tag(FileBrowserSizeRelation.atMost)
            }
            .labelsHidden()
            .frame(width: 125)

            TextField(
                "Value",
                value: valueBinding,
                format: .number.precision(.fractionLength(0...2))
            )
            .frame(width: 80)

            Picker("", selection: $unit) {
                ForEach(FileBrowserSizeUnit.allCases) { unit in
                    Text(verbatim: unit.title).tag(unit)
                }
            }
            .labelsHidden()
            .frame(width: 70)
            .onChange(of: unit) { previousUnit, nextUnit in
                updateUnit(from: previousUnit, to: nextUnit)
            }

            removeFilterButton(accessibilityLabel: "Remove size filter") {
                filter = nil
            }
        }
        .filterRowStyle()
    }

    private var relationBinding: Binding<FileBrowserSizeRelation> {
        Binding(
            get: { filter?.relation ?? .greaterThan },
            set: { relation in
                guard var updatedFilter = filter else { return }
                updatedFilter.relation = relation
                filter = updatedFilter
            }
        )
    }

    private var valueBinding: Binding<Double> {
        Binding(
            get: {
                Double(filter?.bytes ?? 0) / Double(unit.bytes)
            },
            set: { value in
                guard value.isFinite,
                      value >= 0,
                      value <= Double(Int64.max) / Double(unit.bytes),
                      var updatedFilter = filter else {
                    return
                }
                updatedFilter.bytes = Int64((value * Double(unit.bytes)).rounded())
                filter = updatedFilter
            }
        )
    }

    private func updateUnit(
        from previousUnit: FileBrowserSizeUnit,
        to nextUnit: FileBrowserSizeUnit
    ) {
        guard var updatedFilter = filter else { return }
        let displayedValue = Double(updatedFilter.bytes) / Double(previousUnit.bytes)
        let nextBytes = displayedValue * Double(nextUnit.bytes)
        guard nextBytes <= Double(Int64.max) else { return }
        updatedFilter.bytes = Int64(nextBytes.rounded())
        filter = updatedFilter
    }
}

private func removeFilterButton(
    accessibilityLabel: LocalizedStringKey,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
}

private extension View {
    func filterRowStyle() -> some View {
        padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
