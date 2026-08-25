import SwiftUI

struct InspectorMultiSelectionView: View {
    let summary: InspectorSelectionSummary
    let percentOfScan: String
    let availability: FileNodeActionAvailability
    let canMoveSelectionToTrash: Bool
    let availabilityNotice: InspectorAvailabilityNoticeKind?
    let warnings: [ScanWarning]
    let fullDiskAccessAdvice: FullDiskAccessAdvice
    let actions: BulkFileActions
    let openFullDiskAccessSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    header
                }

                InspectorStorageSection(
                    allocatedSize: summary.allocatedSize,
                    percentOfParent: nil,
                    percentOfScan: percentOfScan,
                    notes: storageNotes
                )

                if summary.containsSharedStorageItems {
                    InspectorMultiSharedStorageSection(
                        containsKnownClones: summary.containsKnownClones
                    )
                }

                if !warnings.isEmpty {
                    InspectorWarningsSection(
                        selectionName: selectionTitle,
                        warnings: warnings,
                        fullDiskAccessAdvice: fullDiskAccessAdvice,
                        openFullDiskAccessSettings: openFullDiskAccessSettings
                    )
                }

                if let availabilityNotice {
                    InspectorAvailabilityNotice(kind: availabilityNotice)
                }

                InspectorSelectedItemsSection(summary: summary)
            }
            .formStyle(.grouped)

            if availability.canRevealInFinder || canMoveSelectionToTrash {
                InspectorActionBar(
                    revealAction: availability.canRevealInFinder
                        ? { actions.revealInFinder(summary.selectedNodes) }
                        : nil,
                    addToDiscardPileAction: canMoveSelectionToTrash
                        ? { actions.addToDiscardPile(summary.topLevelSelectedNodes) }
                        : nil,
                    addToDiscardPileTitle: addToDiscardPileTitle
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(selectionTitle)
                    .font(.headline)

                Text(selectionBreakdown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if availability.canCopyPath || canMoveSelectionToTrash {
                Menu {
                    if availability.canCopyPath {
                        Button("Copy Paths", systemImage: FileNodeAction.copyPath.systemImageName) {
                            actions.copyPaths(summary.selectedNodes)
                        }
                    }

                    if canMoveSelectionToTrash {
                        Divider()

                        Button(
                            moveToTrashTitle,
                            systemImage: FileNodeAction.moveToTrash.systemImageName,
                            role: .destructive
                        ) {
                            actions.moveToTrash(summary.topLevelSelectedNodes)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More Actions")
                .accessibilityLabel("More Actions")
            }
        }
    }

    private var selectionTitle: String {
        String(
            localized: "\(summary.selectedCount) Items Selected",
            comment: "Inspector heading for a selection containing multiple items."
        )
    }

    private var selectionBreakdown: String {
        var components: [String] = []
        if summary.selectedFolderCount > 0 {
            components.append(folderCountDescription)
        }
        if summary.selectedFileCount > 0 {
            components.append(fileCountDescription)
        }
        if summary.selectedPackageCount > 0 {
            components.append(packageCountDescription)
        }
        if summary.selectedStorageCategoryCount > 0 {
            components.append(storageCategoryCountDescription)
        }
        return components.joined(separator: " · ")
    }

    private var storageNotes: [String] {
        var notes: [String] = []
        if summary.containsOverlappingSelections {
            notes.append(String(localized: "Items inside another selected folder are included with that folder."))
        }
        if summary.missingSelectedNodeCount > 0 {
            notes.append(String(localized: "Some selected items are no longer available in this scan and are excluded from totals."))
        }
        notes.append(String(localized: "Allocated totals reflect Radix’s storage attribution, not guaranteed space reclaimed."))
        return notes
    }

    private var folderCountDescription: String {
        return String(
            localized: "\(summary.selectedFolderCount) folders",
            comment: "Inspector multiple-selection folder count."
        )
    }

    private var fileCountDescription: String {
        return String(
            localized: "\(summary.selectedFileCount) files",
            comment: "Inspector multiple-selection file count."
        )
    }

    private var packageCountDescription: String {
        return String(
            localized: "\(summary.selectedPackageCount) packages",
            comment: "Inspector multiple-selection package count."
        )
    }

    private var storageCategoryCountDescription: String {
        return String(
            localized: "\(summary.selectedStorageCategoryCount) storage categories",
            comment: "Inspector multiple-selection synthetic storage category count."
        )
    }

    private var addToDiscardPileTitle: String {
        String(
            localized: "Add \(summary.topLevelSelectedCount) Items to Discard Pile",
            comment: "Action for marking one or more effective top-level selected items for possible deletion."
        )
    }

    private var moveToTrashTitle: String {
        String(
            localized: "Move \(summary.topLevelSelectedCount) Items to Trash",
            comment: "Destructive action for moving one or more effective top-level selected items to the Trash."
        )
    }
}

private struct InspectorSelectedItemsSection: View {
    let summary: InspectorSelectionSummary

    @State private var showsAllItems = false
    @State private var showsAllItemsSheet = false

    private let defaultVisibleCount = 3
    private let maximumInlineCount = 100

    var body: some View {
        Section("Selected Items") {
            ForEach(visibleNodes) { node in
                InspectorSelectedItemRow(node: node)
            }

            if summary.selectedCount > defaultVisibleCount {
                Button {
                    if presentsAllItemsInSheet {
                        showsAllItemsSheet = true
                    } else {
                        showsAllItems.toggle()
                    }
                } label: {
                    HStack {
                        Text(disclosureTitle)
                        Spacer()
                        Image(systemName: showsAllItems ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .onChange(of: summary.selectedNodes.map(\.id)) { _, _ in
            showsAllItems = false
            showsAllItemsSheet = false
        }
        .sheet(isPresented: $showsAllItemsSheet) {
            InspectorAllSelectedItemsView(nodes: summary.selectedNodesByAllocatedSize)
        }
    }

    private var visibleNodes: [FileNodeRecord] {
        showsAllItems && !presentsAllItemsInSheet
            ? summary.selectedNodesByAllocatedSize
            : summary.largestSelectedNodes(limit: defaultVisibleCount)
    }

    private var presentsAllItemsInSheet: Bool {
        summary.selectedCount > maximumInlineCount
    }

    private var disclosureTitle: String {
        if presentsAllItemsInSheet {
            return String(
                localized: "View All \(summary.selectedCount) Items…",
                comment: "Action that opens the complete Inspector selected-items list in a sheet."
            )
        }
        if showsAllItems {
            return String(localized: "Show Less", comment: "Action that collapses the Inspector selected-items list.")
        }
        return String(
            localized: "Show \(summary.selectedCount - defaultVisibleCount) More",
            comment: "Action that expands the Inspector selected-items list."
        )
    }
}

private struct InspectorAllSelectedItemsView: View {
    @Environment(\.dismiss) private var dismiss

    let nodes: [FileNodeRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Selected Items")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            List(nodes) { node in
                InspectorSelectedItemRow(node: node)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

private struct InspectorSelectedItemRow: View {
    let node: FileNodeRecord

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: node.systemImageName)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text(node.name)
                .lineLimit(1)

            Spacer()

            Text(RadixFormatters.size(node.allocatedSize))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
