import SwiftUI

struct ScanComparisonRowActions {
    let reveal: (ScanComparisonRow) -> Void
    let canReveal: (ScanComparisonRow) -> Bool
    let showInBrowser: (ScanComparisonRow) -> Void
    let canShowInBrowser: (ScanComparisonRow) -> Bool
    let copyPath: (ScanComparisonRow) -> Void
    let revealNode: (ScanComparisonChangeTreeNode) -> Void
    let canRevealNode: (ScanComparisonChangeTreeNode) -> Bool
    let showNodeInBrowser: (ScanComparisonChangeTreeNode) -> Void
    let canShowNodeInBrowser: (ScanComparisonChangeTreeNode) -> Bool
    let copyNodePath: (ScanComparisonChangeTreeNode) -> Void
}

struct ScanComparisonView: View {
    private static let initialSortOrder = [
        ScanComparisonRowComparator.defaultOrder
    ]

    let comparison: ScanComparison
    let actions: ScanComparisonRowActions
    let onClose: () -> Void

    @State private var displayMode: ScanComparisonDisplayMode = .significant
    @State private var impactFilter: ScanComparisonImpactFilter
    @State private var searchText = ""
    @State private var focusedLocationPath: String?
    @State private var sortOrder: [ScanComparisonRowComparator]
    @State private var selection = Set<ScanComparisonRow.ID>()
    @State private var aggregateSelection = Set<ScanComparisonChangeTreeNode.ID>()
    @State private var displayedRows: [ScanComparisonRow]
    @State private var projection: ScanComparisonChangeTreeProjection

    init(
        comparison: ScanComparison,
        actions: ScanComparisonRowActions,
        onClose: @escaping () -> Void
    ) {
        self.comparison = comparison
        self.actions = actions
        self.onClose = onClose

        let sortOrder = Self.initialSortOrder
        let impactFilter: ScanComparisonImpactFilter = if comparison.summary.allocatedDelta > 0 {
            .takingSpace
        } else if comparison.summary.allocatedDelta < 0 {
            .freeingSpace
        } else {
            .allActivity
        }
        self._impactFilter = State(initialValue: impactFilter)
        self._sortOrder = State(initialValue: sortOrder)
        self._displayedRows = State(initialValue: ScanComparisonRowQuery(
            changeKind: nil,
            impactFilter: impactFilter,
            searchText: "",
            sortOrder: sortOrder,
            pathPrefix: nil
        ).applying(to: comparison.rows))
        self._projection = State(initialValue: comparison.changeTree.significantProjection(
            impactFilter: impactFilter
        ))
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
        .onChange(of: impactFilter) { _, filter in
            projection = comparison.changeTree.significantProjection(impactFilter: filter)
            aggregateSelection.removeAll()
        }
        .onChange(of: displayMode) { _, mode in
            if mode == .significant {
                focusedLocationPath = nil
                selection.removeAll()
            } else {
                aggregateSelection.removeAll()
            }
        }
        .onChange(of: comparison.id) { _, _ in
            refreshDisplayedRows(using: rowQuery)
            projection = comparison.changeTree.significantProjection(impactFilter: impactFilter)
        }
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if effectiveDisplayMode == .significant, !projection.roots.isEmpty {
            significantTable
        } else if displayedRows.isEmpty {
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

            HStack(spacing: 16) {
                Picker("Detail", selection: $displayMode) {
                    ForEach(ScanComparisonDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .accessibilityLabel("Comparison detail")

                Divider()
                    .frame(height: 22)

                Picker("Show", selection: $impactFilter) {
                    ForEach(ScanComparisonImpactFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.systemImageName).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Show changes")

                Spacer(minLength: 16)

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
                .frame(width: 280, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            if !comparison.rows.isEmpty {
                comparisonStatus
            }

            if effectiveDisplayMode == .significant, let selectedAggregateNode {
                aggregateSelectionActions(for: selectedAggregateNode)
            } else if let selectedRow {
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

    private var effectiveDisplayMode: ScanComparisonDisplayMode {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? displayMode
            : .allChanges
    }

    private var comparisonStatus: some View {
        HStack(spacing: 6) {
            if let focusedLocationPath {
                Button {
                    self.focusedLocationPath = nil
                } label: {
                    Label(focusedLocationPath, systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lineLimit(1)
                .help("Clear location filter")
            }

            Image(systemName: effectiveDisplayMode == .significant ? "scope" : "list.bullet")
                .foregroundStyle(.secondary)

            if effectiveDisplayMode == .significant {
                Text(significantStatusText)
            } else {
                Text("Showing \(displayedRows.count.formatted()) of \(comparison.rows.count.formatted()) filesystem changes.")
                if !searchText.isEmpty, displayMode == .significant {
                    Text("Search uses All Changes.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var significantStatusText: String {
        let percentage = projection.representedFraction.formatted(.percent.precision(.fractionLength(0)))
        let effect = impactFilter.statusNoun
        if projection.hiddenRootCount == 0 {
            return "Showing all meaningful \(effect) contributors; expand folders to trace their source."
        }
        return "Named contributors represent \(percentage) of \(effect); \(projection.groupedAffectedCount.formatted()) smaller changes are grouped under Other."
    }

    private var significantTable: some View {
        Table(
            projection.roots,
            children: \.children,
            selection: $aggregateSelection
        ) {
            TableColumn("Contributor") { node in
                HStack(spacing: 8) {
                    Image(systemName: itemSymbol(for: node))
                        .foregroundStyle(node.isRemainder ? Color.secondary : Color.accentColor)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .fontWeight(node.isRemainder ? .regular : .medium)
                            .lineLimit(1)

                        if node.isRemainder {
                            Text("Switch to All Changes to inspect every item")
                        } else if node.relativePath != node.name {
                            Text(node.relativePath)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(node.isRemainder ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .width(min: 280, ideal: 520)

            TableColumn("Taking Space") { node in
                Text(node.increasedAllocatedSize == 0 ? "–" : "+" + RadixFormatters.size(node.increasedAllocatedSize))
                    .foregroundStyle(node.increasedAllocatedSize == 0 ? Color.secondary : Color.red)
                    .monospacedDigit()
                    .accessibilityLabel("Taking \(RadixFormatters.size(node.increasedAllocatedSize))")
            }
            .width(min: 110, ideal: 130)

            TableColumn("Freeing Space") { node in
                Text(node.reclaimedAllocatedSize == 0 ? "–" : "−" + RadixFormatters.size(node.reclaimedAllocatedSize))
                    .foregroundStyle(node.reclaimedAllocatedSize == 0 ? Color.secondary : Color.green)
                    .monospacedDigit()
                    .accessibilityLabel("Freeing \(RadixFormatters.size(node.reclaimedAllocatedSize))")
            }
            .width(min: 110, ideal: 130)

            TableColumn("Net") { node in
                Text(signedSize(node.allocatedDelta))
                    .foregroundStyle(deltaColor(node.allocatedDelta))
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 120)

            TableColumn("Changes") { node in
                Text(node.affectedCount.formatted())
                    .monospacedDigit()
                    .accessibilityLabel("\(node.affectedCount.formatted()) affected items")
            }
            .width(min: 75, ideal: 90)
        }
        .contextMenu(forSelectionType: ScanComparisonChangeTreeNode.ID.self) { ids in
            aggregateContextMenu(for: ids)
        } primaryAction: { ids in
            guard let node = singleAggregateNode(in: ids) else { return }
            if node.isRemainder {
                showAllChanges(for: node)
            } else if actions.canShowNodeInBrowser(node) {
                actions.showNodeInBrowser(node)
            }
        }
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

    private var selectedAggregateNode: ScanComparisonChangeTreeNode? {
        singleAggregateNode(in: aggregateSelection)
    }

    private func aggregateSelectionActions(for node: ScanComparisonChangeTreeNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: itemSymbol(for: node))
                .foregroundStyle(.secondary)

            Text(node.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer()

            if node.isRemainder {
                Button {
                    showAllChanges(for: node)
                } label: {
                    Label("Show All Changes", systemImage: "list.bullet")
                }
            } else {
                Button {
                    actions.showNodeInBrowser(node)
                } label: {
                    Label("Show in Browser", systemImage: "sidebar.squares.left")
                }
                .disabled(!actions.canShowNodeInBrowser(node))

                Button {
                    actions.revealNode(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!actions.canRevealNode(node))

                Button {
                    actions.copyNodePath(node)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .disabled(node.fileURL == nil)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

    @ViewBuilder
    private func aggregateContextMenu(for ids: Set<ScanComparisonChangeTreeNode.ID>) -> some View {
        if let node = singleAggregateNode(in: ids) {
            if node.isRemainder {
                Button {
                    showAllChanges(for: node)
                } label: {
                    Label("Show All Changes", systemImage: "list.bullet")
                }
            } else {
                Button {
                    actions.revealNode(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!actions.canRevealNode(node))

                Button {
                    actions.showNodeInBrowser(node)
                } label: {
                    Label("Show in Browser", systemImage: "sidebar.squares.left")
                }
                .disabled(!actions.canShowNodeInBrowser(node))

                Divider()

                Button {
                    actions.copyNodePath(node)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .disabled(node.fileURL == nil)
            }
        }
    }

    private func singleAggregateNode(
        in ids: Set<ScanComparisonChangeTreeNode.ID>
    ) -> ScanComparisonChangeTreeNode? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return projection.node(withID: id)
    }

    private func showAllChanges(for node: ScanComparisonChangeTreeNode) {
        displayMode = .allChanges
        focusedLocationPath = node.relativePath.isEmpty ? nil : node.relativePath
        aggregateSelection.removeAll()
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
            : "Choose a different view or adjust your search."
    }

    private var rowQuery: ScanComparisonRowQuery {
        ScanComparisonRowQuery(
            changeKind: nil,
            impactFilter: impactFilter,
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

    private func itemSymbol(for node: ScanComparisonChangeTreeNode) -> String {
        if node.isRemainder {
            return "ellipsis.circle"
        }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }

    private func comparisonDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
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

private enum ScanComparisonDisplayMode: String, CaseIterable, Identifiable {
    case significant
    case allChanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .significant:
            return "Significant"
        case .allChanges:
            return "All Changes"
        }
    }
}

private extension ScanComparisonImpactFilter {
    var title: String {
        switch self {
        case .takingSpace:
            return "Taking Space"
        case .freeingSpace:
            return "Freeing Space"
        case .moved:
            return "Moves"
        case .allActivity:
            return "Everything"
        }
    }

    var systemImageName: String {
        switch self {
        case .takingSpace:
            return "arrow.up.right"
        case .freeingSpace:
            return "arrow.down.right"
        case .moved:
            return "arrow.left.arrow.right"
        case .allActivity:
            return "waveform.path.ecg"
        }
    }

    var statusNoun: String {
        switch self {
        case .takingSpace:
            return "storage growth"
        case .freeingSpace:
            return "reclaimed storage"
        case .moved:
            return "moves"
        case .allActivity:
            return "storage activity"
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
