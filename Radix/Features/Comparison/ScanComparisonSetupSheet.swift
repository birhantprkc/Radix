import SwiftUI

struct ScanComparisonSetupSheet: View {
    let setup: ScanComparisonSetup
    let canUseCurrentScan: Bool
    let onChooseSnapshot: (ScanComparisonSlot) -> Void
    let onUseCurrentScan: (ScanComparisonSlot) -> Void
    let onClear: (ScanComparisonSlot) -> Void
    let onSwap: () -> Void
    let onCancel: () -> Void
    let onCompare: () -> Void

    private var isBusy: Bool {
        setup.loadingSlot != nil
    }

    private var statusMessage: String? {
        setup.errorMessage ?? setup.validationMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Compare Snapshots", systemImage: "rectangle.split.2x1")
                .font(.title3.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary, .tint)

            HStack(alignment: .center, spacing: 12) {
                ScanComparisonCandidateSlotCard(
                    slot: .before,
                    candidate: setup.before,
                    isLoading: setup.loadingSlot == .before,
                    canUseCurrentScan: canUseCurrentScan,
                    actionsDisabled: isBusy,
                    onChooseSnapshot: onChooseSnapshot,
                    onUseCurrentScan: onUseCurrentScan,
                    onClear: onClear
                )

                Button {
                    onSwap()
                } label: {
                    Label("Swap", systemImage: "arrow.left.arrow.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isBusy)
                .help("Swap Before and After")

                ScanComparisonCandidateSlotCard(
                    slot: .after,
                    candidate: setup.after,
                    isLoading: setup.loadingSlot == .after,
                    canUseCurrentScan: canUseCurrentScan,
                    actionsDisabled: isBusy,
                    onChooseSnapshot: onChooseSnapshot,
                    onUseCurrentScan: onUseCurrentScan,
                    onClear: onClear
                )
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Compare") {
                    onCompare()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.canCompare)
            }
        }
        .padding(24)
        .frame(width: 760, alignment: .topLeading)
    }
}

private struct ScanComparisonCandidateSlotCard: View {
    let slot: ScanComparisonSlot
    let candidate: ScanComparisonCandidate?
    let isLoading: Bool
    let canUseCurrentScan: Bool
    let actionsDisabled: Bool
    let onChooseSnapshot: (ScanComparisonSlot) -> Void
    let onUseCurrentScan: (ScanComparisonSlot) -> Void
    let onClear: (ScanComparisonSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(slot.title)
                    .font(.headline)

                if candidate?.isCurrentScan == true {
                    Label("Current Scan", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.medium))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Group {
                if isLoading {
                    loadingContent
                } else if let candidate {
                    candidateContent(candidate)
                } else {
                    emptyContent
                }
            }
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)

            HStack(spacing: 8) {
                Button {
                    onChooseSnapshot(slot)
                } label: {
                    Label("Choose Snapshot", systemImage: "folder")
                }
                .disabled(actionsDisabled)

                Button {
                    onUseCurrentScan(slot)
                } label: {
                    Label("Use Current Scan", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(actionsDisabled || !canUseCurrentScan)

                if candidate != nil {
                    Button {
                        onClear(slot)
                    } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(actionsDisabled)
                    .help("Clear \(slot.title)")
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 246, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No snapshot selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reading snapshot")
                .font(.subheadline.weight(.semibold))
            Text("...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func candidateContent(_ candidate: ScanComparisonCandidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidate.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(candidate.path)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    setupMetric("Scanned", RadixFormatters.date(candidate.scanDate))
                    setupMetric("Size", RadixFormatters.size(candidate.totalAllocatedSize))
                }
                GridRow {
                    setupMetric("Files", candidate.fileCount.formatted())
                    setupMetric("Folders", candidate.directoryCount.formatted())
                }
                GridRow {
                    setupMetric("Warnings", candidate.warningCount.formatted())
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
    }

    private func setupMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .monospacedDigit()
        }
    }
}
