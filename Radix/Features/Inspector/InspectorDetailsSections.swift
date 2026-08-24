import SwiftUI

struct InspectorDetailsSections: View {
    let node: FileNodeRecord
    let parentName: String?
    let percentOfParent: String
    let percentOfScan: String
    let activeTarget: ScanTarget?

    var body: some View {
        Section("Key Stats") {
            InspectorKeyStats(stats: [
                InspectorStat(
                    id: "allocated",
                    title: String(localized: "Allocated", comment: "Inspector storage statistic title."),
                    value: RadixFormatters.size(node.allocatedSize)
                ),
                InspectorStat(
                    id: "parent",
                    title: String(localized: "Of Parent", comment: "Inspector statistic for a selected item's share of its parent folder."),
                    value: percentOfParent
                ),
                InspectorStat(
                    id: "scan",
                    title: String(localized: "Of Scan", comment: "Inspector statistic for a selection's share of the entire scan."),
                    value: percentOfScan
                )
            ])
        }

        if let sharedStorageDescription = node.sharedStorageDescription {
            Section("Storage") {
                Text(sharedStorageDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section("Metadata") {
            LabeledContent("Kind") {
                Text(node.itemKind(activeTarget: activeTarget))
            }

            LabeledContent("Logical Size") {
                Text(RadixFormatters.size(node.logicalSize))
            }

            if let parentName {
                LabeledContent("Parent") {
                    Text(parentName)
                }
            }

            LabeledContent("Modified") {
                Text(RadixFormatters.date(node.lastModified))
            }

            LabeledContent("Access") {
                Text(node.accessDescription)
            }
        }
    }
}

struct InspectorStat: Identifiable {
    let id: String
    let title: String
    let value: String
}

struct InspectorKeyStats: View {
    let stats: [InspectorStat]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(stats) { stat in
                    InspectorStatCard(title: stat.title, value: stat.value)
                }
            }

            VStack(spacing: 8) {
                ForEach(stats) { stat in
                    InspectorStatCard(title: stat.title, value: stat.value)
                }
            }
        }
    }
}

private struct InspectorStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
