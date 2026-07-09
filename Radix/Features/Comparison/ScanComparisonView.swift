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
    @State private var focusedLocationPath: String?
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
            sortOrder: sortOrder,
            pathPrefix: nil
        ).applying(to: comparison.rows))
    }

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                header

                Divider()

                comparisonContent
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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

    @ViewBuilder
    private var comparisonContent: some View {
        if displayedRows.isEmpty {
            emptyState
        } else {
            comparisonTable
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Storage Changes")
                .font(.title2.weight(.semibold))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    sourceSummary(title: "Earlier Scan", snapshot: comparison.before)
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 44)
                    sourceSummary(title: "Later Scan", snapshot: comparison.after)
                    Spacer(minLength: 10)
                    metricStrip
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 18) {
                        sourceSummary(title: "Earlier Scan", snapshot: comparison.before)
                        Image(systemName: "arrow.right")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: 44)
                        sourceSummary(title: "Later Scan", snapshot: comparison.after)
                    }
                    metricStrip
                }
            }

            if comparison.coverage.confidence != .high {
                coverageBanner
            }

            if !highlightedLocations.isEmpty {
                locationOverview
            }

            HStack(spacing: 12) {
                Picker("Filter", selection: $filter) {
                    ForEach(ScanComparisonRowFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                if let focusedLocationPath {
                    Button {
                        self.focusedLocationPath = nil
                    } label: {
                        Label("Showing \(focusedLocationPath)", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
                }

                Spacer()

                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var coverageBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: coverageSymbolName)
                .foregroundStyle(coverageColor)

            Text(coverageMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(coverageColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var coverageMessage: String {
        switch comparison.coverage.confidence {
        case .high:
            return "Comparable: same location, matching scan settings, and complete scans."
        case .limited:
            let warningCount = comparison.coverage.beforeWarningCount + comparison.coverage.afterWarningCount
            if warningCount > 0 {
                return "Limited coverage: \(warningCount) unreadable location\(warningCount == 1 ? "" : "s"). Missing entries below them are not necessarily deleted."
            }
            return "Limited coverage: scan settings are unavailable for one or both scans."
        case .low:
            return "Forensic comparison only: scan coverage or settings differ, so totals may not be directly comparable."
        }
    }

    private var coverageColor: Color {
        switch comparison.coverage.confidence {
        case .high:
            return .green
        case .limited:
            return .orange
        case .low:
            return .red
        }
    }

    private var coverageSymbolName: String {
        switch comparison.coverage.confidence {
        case .high:
            return "checkmark.seal.fill"
        case .limited:
            return "exclamationmark.triangle.fill"
        case .low:
            return "exclamationmark.octagon.fill"
        }
    }

    private var highlightedLocations: [ScanComparisonLocationChange] {
        let increases = comparison.topLevelChanges
            .filter { $0.allocatedDelta > 0 }
            .sorted { lhs, rhs in
                lhs.allocatedDelta == rhs.allocatedDelta
                    ? lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
                    : lhs.allocatedDelta > rhs.allocatedDelta
            }
        if !increases.isEmpty {
            return Array(increases.prefix(3))
        }
        return Array(comparison.topLevelChanges.prefix(3))
    }

    private var locationOverviewTitle: String {
        comparison.topLevelChanges.contains { $0.allocatedDelta > 0 }
            ? "Largest Increases"
            : "Largest Changes"
    }

    private var locationOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(locationOverviewTitle)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(signedSize(comparison.summary.grossIncreasedAllocatedSize)) added or grew • \(RadixFormatters.size(comparison.summary.grossReclaimedAllocatedSize)) reclaimed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ForEach(highlightedLocations) { location in
                locationRow(location)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func locationRow(_ location: ScanComparisonLocationChange) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(location.relativePath)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(location.affectedCount.formatted()) affected item\(location.affectedCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(signedSize(location.allocatedDelta))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(deltaColor(location.allocatedDelta))
                .monospacedDigit()

            Button("Show Changes") {
                focusedLocationPath = location.relativePath
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
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
                comparisonMetric("Tracked", signedSize(comparison.summary.allocatedDelta))
                comparisonMetric("Files", signedCount(comparison.summary.fileCountDelta))
                comparisonMetric("Folders", signedCount(comparison.summary.directoryCountDelta))
                comparisonMetric("Warnings", signedCount(comparison.summary.warningCountDelta))
                comparisonMetric(
                    "Changed",
                    comparison.summary.changedCount.formatted()
                )
                .help("Items present in both scans whose tracked size changed")
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    comparisonMetric("Tracked", signedSize(comparison.summary.allocatedDelta))
                    comparisonMetric("Files", signedCount(comparison.summary.fileCountDelta))
                    comparisonMetric("Folders", signedCount(comparison.summary.directoryCountDelta))
                }
                GridRow {
                    comparisonMetric("Warnings", signedCount(comparison.summary.warningCountDelta))
                    comparisonMetric(
                        "Changed",
                        comparison.summary.changedCount.formatted()
                    )
                    .help("Items present in both scans whose tracked size changed")
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
                Text(pathText(for: row))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .width(min: 260, ideal: 430)

            TableColumn("Earlier", sortUsing: ScanComparisonRowComparator(field: .beforeAllocatedSize)) { row in
                Text(sizeText(row.beforeAllocatedSize))
                    .monospacedDigit()
            }
            .width(min: 105, ideal: 120)

            TableColumn("Later", sortUsing: ScanComparisonRowComparator(field: .afterAllocatedSize)) { row in
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
        comparison.rows.isEmpty ? "No Tracked Size Changes" : "No Matching Changes"
    }

    private var emptyStateSystemImage: String {
        comparison.rows.isEmpty ? "checkmark.circle" : "magnifyingglass"
    }

    private var emptyStateDescription: String {
        comparison.rows.isEmpty
            ? "No tracked size changes were found."
            : "Adjust filter or search."
    }

    private var rowQuery: ScanComparisonRowQuery {
        ScanComparisonRowQuery(
            changeKind: filter.changeKind,
            searchText: searchText,
            sortOrder: sortOrder,
            pathPrefix: focusedLocationPath
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

    private func pathText(for row: ScanComparisonRow) -> String {
        guard let movedFromRelativePath = row.movedFromRelativePath else {
            return row.relativePath
        }
        return "\(movedFromRelativePath) → \(row.relativePath)"
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
    case moved

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
        case .moved:
            return ScanComparisonChangeKind.moved.title
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
        case .moved:
            return .moved
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
        case .moved:
            return "arrow.left.arrow.right.circle.fill"
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
        case .moved:
            return .purple
        }
    }
}
