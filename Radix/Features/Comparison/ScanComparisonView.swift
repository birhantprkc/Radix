import SwiftUI

struct ScanComparisonRowActions {
    let reveal: (ScanComparisonRow) -> Void
    let canReveal: (ScanComparisonRow) -> Bool
    let showInBrowser: (ScanComparisonRow) -> Void
    let canShowInBrowser: (ScanComparisonRow) -> Bool
    let copyPath: (ScanComparisonRow) -> Void
}

struct ScanComparisonView: View {
    private static let initialSortOrder = [
        ScanComparisonRowComparator.defaultOrder
    ]

    let comparison: ScanComparison
    let actions: ScanComparisonRowActions
    let onClose: () -> Void

    @State private var filter: ScanComparisonRowFilter = .all
    @State private var searchText = ""
    @State private var sortOrder: [ScanComparisonRowComparator]
    @State private var selection = Set<ScanComparisonRow.ID>()
    @State private var displayedRows: [ScanComparisonRow]

    init(
        comparison: ScanComparison,
        actions: ScanComparisonRowActions,
        onClose: @escaping () -> Void
    ) {
        self.comparison = comparison
        self.actions = actions
        self.onClose = onClose

        let sortOrder = Self.initialSortOrder
        self._sortOrder = State(initialValue: sortOrder)
        self._displayedRows = State(initialValue: ScanComparisonRowQuery(
            changeKind: nil,
            searchText: "",
            sortOrder: sortOrder
        ).applying(to: comparison.rows))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if displayedRows.isEmpty {
                emptyState
            } else {
                comparisonTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    onClose()
                } label: {
                    Label("Close Comparison", systemImage: "xmark")
                }
                .help("Close Comparison")
            }
        }
        .onChange(of: rowQuery) { _, query in
            refreshDisplayedRows(using: query)
        }
        .onChange(of: comparison.id) { _, _ in
            refreshDisplayedRows(using: rowQuery)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snapshot Comparison")
                        .font(.title2.weight(.semibold))

                    Text("\(comparison.before.displayName) -> \(comparison.after.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Delta")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(signedSize(comparison.summary.allocatedDelta))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(deltaColor(comparison.summary.allocatedDelta))
                        .monospacedDigit()
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    sourceSummary(title: "Before", snapshot: comparison.before)
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 44)
                    sourceSummary(title: "After", snapshot: comparison.after)
                    Spacer(minLength: 10)
                    metricStrip
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 18) {
                        sourceSummary(title: "Before", snapshot: comparison.before)
                        Image(systemName: "arrow.right")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: 44)
                        sourceSummary(title: "After", snapshot: comparison.after)
                    }
                    metricStrip
                }
            }

            HStack(spacing: 12) {
                Picker("Filter", selection: $filter) {
                    ForEach(ScanComparisonRowFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func sourceSummary(title: String, snapshot: ComparedSnapshotSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(snapshot.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(RadixFormatters.date(snapshot.comparisonDate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 260, alignment: .leading)
    }

    private var metricStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                comparisonMetric("Scanned", signedSize(comparison.summary.allocatedDelta))
                comparisonMetric("Files", signedCount(comparison.summary.fileCountDelta))
                comparisonMetric("Folders", signedCount(comparison.summary.directoryCountDelta))
                comparisonMetric("Warnings", signedCount(comparison.summary.warningCountDelta))
                comparisonMetric("Changed", comparison.summary.changedCount.formatted())
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    comparisonMetric("Scanned", signedSize(comparison.summary.allocatedDelta))
                    comparisonMetric("Files", signedCount(comparison.summary.fileCountDelta))
                    comparisonMetric("Folders", signedCount(comparison.summary.directoryCountDelta))
                }
                GridRow {
                    comparisonMetric("Warnings", signedCount(comparison.summary.warningCountDelta))
                    comparisonMetric("Changed", comparison.summary.changedCount.formatted())
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
    }

    private func comparisonMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(minWidth: 78, alignment: .leading)
    }

    private var comparisonTable: some View {
        Table(of: ScanComparisonRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Change", sortUsing: ScanComparisonRowComparator(field: .changeKind)) { row in
                Label(row.kind.title, systemImage: row.kind.systemImageName)
                    .foregroundStyle(row.kind.tintColor)
            }
            .width(min: 105, ideal: 120)

            TableColumn("Path", sortUsing: ScanComparisonRowComparator(field: .relativePath)) { row in
                Text(row.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .width(min: 260, ideal: 430)

            TableColumn("Before", sortUsing: ScanComparisonRowComparator(field: .beforeAllocatedSize)) { row in
                Text(sizeText(row.beforeAllocatedSize))
                    .monospacedDigit()
            }
            .width(min: 105, ideal: 120)

            TableColumn("After", sortUsing: ScanComparisonRowComparator(field: .afterAllocatedSize)) { row in
                Text(sizeText(row.afterAllocatedSize))
                    .monospacedDigit()
            }
            .width(min: 105, ideal: 120)

            TableColumn("Delta", sortUsing: ScanComparisonRowComparator(field: .allocatedDelta)) { row in
                Text(signedSize(row.allocatedDelta))
                    .foregroundStyle(deltaColor(row.allocatedDelta))
                    .monospacedDigit()
            }
            .width(min: 105, ideal: 120)

            TableColumn("Kind", sortUsing: ScanComparisonRowComparator(field: .itemKind)) { row in
                Text(row.itemKind)
            }
            .width(min: 95, ideal: 115)
        } rows: {
            ForEach(displayedRows) { row in
                TableRow(row)
            }
        }
        .contextMenu(forSelectionType: ScanComparisonRow.ID.self) { ids in
            rowContextMenu(for: ids)
        } primaryAction: { ids in
            guard let row = singleRow(in: ids), actions.canReveal(row) else { return }
            actions.reveal(row)
        }
    }

    @ViewBuilder
    private func rowContextMenu(for ids: Set<ScanComparisonRow.ID>) -> some View {
        if let row = singleRow(in: ids) {
            Button {
                actions.reveal(row)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!actions.canReveal(row))

            Button {
                actions.showInBrowser(row)
            } label: {
                Label("Show in Browser", systemImage: "sidebar.squares.left")
            }
            .disabled(!actions.canShowInBrowser(row))

            Divider()

            Button {
                actions.copyPath(row)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }

    private func singleRow(in ids: Set<ScanComparisonRow.ID>) -> ScanComparisonRow? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return comparison.rows.first { $0.id == id }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            emptyStateTitle,
            systemImage: emptyStateSystemImage,
            description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        comparison.rows.isEmpty ? "No Changes" : "No Matching Changes"
    }

    private var emptyStateSystemImage: String {
        comparison.rows.isEmpty ? "checkmark.circle" : "magnifyingglass"
    }

    private var emptyStateDescription: String {
        comparison.rows.isEmpty
            ? "Matched paths have same allocated sizes."
            : "Adjust filter or search."
    }

    private var rowQuery: ScanComparisonRowQuery {
        ScanComparisonRowQuery(
            changeKind: filter.changeKind,
            searchText: searchText,
            sortOrder: sortOrder
        )
    }

    private func refreshDisplayedRows(using query: ScanComparisonRowQuery) {
        let rows = query.applying(to: comparison.rows)
        displayedRows = rows
        selection.formIntersection(rows.lazy.map(\.id))
    }

    private func sizeText(_ size: Int64?) -> String {
        guard let size else { return "-" }
        return RadixFormatters.size(size)
    }

    private func signedSize(_ size: Int64) -> String {
        guard size != 0 else { return RadixFormatters.size(0) }
        let prefix = size > 0 ? "+" : "-"
        return prefix + RadixFormatters.size(abs(size))
    }

    private func signedCount(_ count: Int) -> String {
        guard count != 0 else { return "0" }
        return count > 0 ? "+\(count.formatted())" : "-\(abs(count).formatted())"
    }

    private func deltaColor(_ delta: Int64) -> Color {
        if delta > 0 {
            return .red
        }
        if delta < 0 {
            return .green
        }
        return .secondary
    }
}

private enum ScanComparisonRowFilter: String, CaseIterable, Identifiable {
    case all
    case added
    case removed
    case grew
    case shrank

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .added:
            return ScanComparisonChangeKind.added.title
        case .removed:
            return ScanComparisonChangeKind.removed.title
        case .grew:
            return ScanComparisonChangeKind.grew.title
        case .shrank:
            return ScanComparisonChangeKind.shrank.title
        }
    }

    var changeKind: ScanComparisonChangeKind? {
        switch self {
        case .all:
            return nil
        case .added:
            return .added
        case .removed:
            return .removed
        case .grew:
            return .grew
        case .shrank:
            return .shrank
        }
    }
}

private extension ScanComparisonChangeKind {
    var systemImageName: String {
        switch self {
        case .added:
            return "plus.circle.fill"
        case .removed:
            return "minus.circle.fill"
        case .grew:
            return "arrow.up.circle.fill"
        case .shrank:
            return "arrow.down.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .added:
            return .blue
        case .removed:
            return .orange
        case .grew:
            return .red
        case .shrank:
            return .green
        }
    }
}
