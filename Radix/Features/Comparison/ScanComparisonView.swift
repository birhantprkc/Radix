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
            ToolbarItem(placement: .navigation) {
                Button {
                    onClose()
                } label: {
                    Label("Back to Scan", systemImage: "chevron.backward")
                }
                .help("Back to Scan")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage Changes")
                        .font(.title2.weight(.semibold))

                    Text(changeHeadline)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(deltaColor(comparison.summary.allocatedDelta))
                }

                Spacer(minLength: 16)

                metricStrip
            }

            scanTimeline

            if comparison.coverage.confidence != .high {
                coverageBanner
            }

            if !highlightedLocations.isEmpty {
                locationOverview
            }

            HStack(spacing: 12) {
                Picker("Filter", selection: $filter) {
                    ForEach(ScanComparisonRowFilter.allCases) { filter in
                        Text(filterTitle(filter))
                            .tag(filter)
                            .disabled(filter != .all && filterCount(filter) == 0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)

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

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search names and paths", text: $searchText)
                        .textFieldStyle(.plain)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Search")
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 250, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            if let selectedRow {
                selectionActions(for: selectedRow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var changeHeadline: String {
        let delta = comparison.summary.allocatedDelta
        if delta > 0 {
            return "Storage increased by \(RadixFormatters.size(delta))"
        }
        if delta < 0 {
            return "Storage decreased by \(RadixFormatters.size(-delta))"
        }
        return "No net storage change"
    }

    private var scanTimeline: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .foregroundStyle(.secondary)

            sourceSummary(title: "Earlier", snapshot: comparison.before)

            Image(systemName: "arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)

            sourceSummary(title: "Later", snapshot: comparison.after)

            Spacer(minLength: 8)

            Text("\(signedSize(comparison.summary.grossIncreasedAllocatedSize)) added or grew  •  \(RadixFormatters.size(comparison.summary.grossReclaimedAllocatedSize)) reclaimed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
            Text(locationOverviewTitle)
                .font(.subheadline.weight(.semibold))

            ForEach(highlightedLocations) { location in
                locationRow(location)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func locationRow(_ location: ScanComparisonLocationChange) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                focusedLocationPath = location.relativePath
            }
        } label: {
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

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .help("Show changes in \(location.relativePath)")
    }

    private func sourceSummary(title: String, snapshot: ComparedSnapshotSummary) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)

            Text(snapshot.displayName)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(comparisonDate(snapshot.comparisonDate))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private var metricStrip: some View {
        HStack(spacing: 14) {
            comparisonMetric("Files", signedCount(comparison.summary.fileCountDelta))
            comparisonMetric("Folders", signedCount(comparison.summary.directoryCountDelta))
            comparisonMetric("Modified", comparison.summary.changedCount.formatted())
                .help("Items present in both scans whose tracked size changed")
            comparisonMetric("Warnings", signedCount(comparison.summary.warningCountDelta))
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
        .frame(minWidth: 66, alignment: .leading)
    }

    private var comparisonTable: some View {
        Table(of: ScanComparisonRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Change", sortUsing: ScanComparisonRowComparator(field: .changeKind)) { row in
                Label(row.kind.title, systemImage: row.kind.systemImageName)
                    .foregroundStyle(row.kind.tintColor)
            }
            .width(min: 105, ideal: 120)

            TableColumn("Item", sortUsing: ScanComparisonRowComparator(field: .relativePath)) { row in
                HStack(spacing: 8) {
                    Image(systemName: itemSymbol(for: row))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .lineLimit(1)

                        Text(itemLocation(for: row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            .width(min: 280, ideal: 500)

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
        .alternatingRowBackgrounds(.disabled)
    }

    private var selectedRow: ScanComparisonRow? {
        singleRow(in: selection)
    }

    private func selectionActions(for row: ScanComparisonRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: itemSymbol(for: row))
                .foregroundStyle(.secondary)

            Text(row.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer()

            Button {
                actions.showInBrowser(row)
            } label: {
                Label("Show in Browser", systemImage: "sidebar.squares.left")
            }
            .disabled(!actions.canShowInBrowser(row))

            Button {
                actions.reveal(row)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!actions.canReveal(row))

            Button {
                actions.copyPath(row)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

    private func itemLocation(for row: ScanComparisonRow) -> String {
        if let movedFromRelativePath = row.movedFromRelativePath {
            return "\(movedFromRelativePath) → \(row.relativePath)"
        }

        let components = row.relativePath.split(separator: "/")
        let parent = components.dropLast().joined(separator: "/")
        return parent.isEmpty ? row.itemKind : parent
    }

    private func itemSymbol(for row: ScanComparisonRow) -> String {
        if row.itemKind == "Package" {
            return "shippingbox.fill"
        }
        return row.isDirectory ? "folder.fill" : "doc.fill"
    }

    private func comparisonDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func filterTitle(_ filter: ScanComparisonRowFilter) -> String {
        "\(filter.title) \(filterCount(filter).formatted())"
    }

    private func filterCount(_ filter: ScanComparisonRowFilter) -> Int {
        switch filter {
        case .all:
            return comparison.rows.count
        case .added:
            return comparison.summary.addedCount
        case .removed:
            return comparison.summary.removedCount
        case .grew:
            return comparison.summary.grewCount
        case .shrank:
            return comparison.summary.shrankCount
        case .moved:
            return comparison.summary.movedCount
        }
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
