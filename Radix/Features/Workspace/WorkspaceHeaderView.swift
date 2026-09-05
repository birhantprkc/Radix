import SwiftUI

struct WorkspaceHeaderView: View {
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    let actions: WorkspaceActions

    var body: some View {
        let breadcrumbNodes = navigation.breadcrumbNodes

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(focusNode.name)
                            .font(.title2.weight(.semibold))

                        if snapshot.source.isImported {
                            ReadOnlySnapshotBadge()
                        }
                    }

                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                Spacer(minLength: 16)

                if let finishedAt = snapshot.finishedAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last Updated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(RadixFormatters.date(finishedAt))
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    BreadcrumbBar(
                        nodes: breadcrumbNodes,
                        onSelect: actions.focusNode
                    )

                    Spacer(minLength: 12)

                    MetricStrip(snapshot: snapshot)
                }

                VStack(alignment: .leading, spacing: 10) {
                    BreadcrumbBar(
                        nodes: breadcrumbNodes,
                        onSelect: actions.focusNode
                    )

                    MetricStrip(snapshot: snapshot)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusSubtitle: String {
        snapshot.target.url.path
    }
}

private struct ReadOnlySnapshotBadge: View {
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: "lock")
                .font(.caption.weight(.semibold))
                .imageScale(.small)

            Text("Imported Snapshot")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help("Imported snapshots are read-only.")
    }
}

private struct WorkspaceMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MetricStrip: View {
    let snapshot: ScanSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                metricRow
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    WorkspaceMetricView(title: String(localized: "Scanned", comment: "Workspace metric label for allocated storage scanned."), value: RadixFormatters.size(displayedAllocatedSize))
                    WorkspaceMetricView(title: String(localized: "Files", comment: "Workspace metric label for file count."), value: "\(displayedFileCount)")
                }

                GridRow {
                    WorkspaceMetricView(title: String(localized: "Folders", comment: "Workspace metric label for folder count."), value: "\(displayedDirectoryCount)")
                    WorkspaceMetricView(title: String(localized: "Warnings", comment: "Workspace metric label for warning count."), value: "\(warningCount)")
                }
            }
        }
    }

    private var metricRow: some View {
        Group {
            WorkspaceMetricView(title: String(localized: "Scanned", comment: "Workspace metric label for allocated storage scanned."), value: RadixFormatters.size(displayedAllocatedSize))
            WorkspaceMetricView(title: String(localized: "Files", comment: "Workspace metric label for file count."), value: "\(displayedFileCount)")
            WorkspaceMetricView(title: String(localized: "Folders", comment: "Workspace metric label for folder count."), value: "\(displayedDirectoryCount)")
            WorkspaceMetricView(title: String(localized: "Warnings", comment: "Workspace metric label for warning count."), value: "\(warningCount)")
        }
    }

    private var displayedFileCount: Int {
        snapshot.aggregateStats.fileCount
    }

    private var displayedDirectoryCount: Int {
        snapshot.aggregateStats.directoryCount
    }

    private var displayedAllocatedSize: Int64 {
        snapshot.aggregateStats.totalAllocatedSize
    }

    private var warningCount: Int {
        snapshot.scanWarnings.count
    }
}
