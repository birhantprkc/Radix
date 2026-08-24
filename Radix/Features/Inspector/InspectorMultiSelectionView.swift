import SwiftUI

struct InspectorMultiSelectionView: View {
    let summary: InspectorSelectionSummary
    let percentOfScan: String
    let availability: FileNodeActionAvailability
    let actions: BulkFileActions

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)

                    Text(selectionTitle)
                        .font(.headline)
                }
            }

            Section {
                InspectorKeyStats(stats: [
                    InspectorStat(
                        id: "allocated",
                        title: String(localized: "Allocated", comment: "Inspector storage statistic title."),
                        value: RadixFormatters.size(summary.allocatedSize)
                    ),
                    InspectorStat(
                        id: "logical",
                        title: String(localized: "Logical Size", comment: "Inspector statistic for the apparent size of selected items."),
                        value: RadixFormatters.size(summary.logicalSize)
                    ),
                    InspectorStat(
                        id: "scan",
                        title: String(localized: "Of Scan", comment: "Inspector statistic for a selection's share of the entire scan."),
                        value: percentOfScan
                    )
                ])
            } header: {
                Text("Key Stats")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if summary.containsOverlappingSelections {
                        Text("Overlapping selections are counted once in totals.")
                    }
                    Text("Sizes show attributed allocated storage, not guaranteed space reclaimed.")
                }
            }

            Section("Actions") {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            revealButton
                            copyPathsButton
                        }

                        VStack(spacing: 8) {
                            revealButton
                            copyPathsButton
                        }
                    }

                    Button {
                        actions.addToDiscardPile(summary.selectedNodes)
                    } label: {
                        Label(addToDiscardPileTitle, systemImage: "checklist")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!availability.canMoveToTrash)

                    Button(role: .destructive) {
                        actions.moveToTrash(summary.selectedNodes)
                    } label: {
                        Label(moveToTrashTitle, systemImage: FileNodeAction.moveToTrash.systemImageName)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!availability.canMoveToTrash)
                }
                .controlSize(.regular)
            }
        }
        .formStyle(.grouped)
    }

    private var selectionTitle: String {
        String(
            localized: "\(summary.selectedCount) Items Selected",
            comment: "Inspector heading for a selection containing multiple items."
        )
    }

    private var addToDiscardPileTitle: String {
        String(
            localized: "Add \(summary.selectedCount) Items to Discard Pile",
            comment: "Action for marking multiple selected items for possible deletion."
        )
    }

    private var moveToTrashTitle: String {
        String(
            localized: "Move \(summary.selectedCount) Items to Trash",
            comment: "Destructive action for moving multiple selected items to the Trash."
        )
    }

    private var revealButton: some View {
        Button {
            actions.revealInFinder(summary.selectedNodes)
        } label: {
            Label(FileNodeAction.revealInFinder.title, systemImage: FileNodeAction.revealInFinder.systemImageName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!availability.canRevealInFinder)
    }

    private var copyPathsButton: some View {
        Button {
            actions.copyPaths(summary.selectedNodes)
        } label: {
            Label("Copy Paths", systemImage: FileNodeAction.copyPath.systemImageName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!availability.canCopyPath)
    }
}
