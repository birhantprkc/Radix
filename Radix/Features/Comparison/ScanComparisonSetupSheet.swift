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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare Snapshots")
                    .font(.title3.weight(.semibold))

                Text("Choose the earlier and later snapshots you want to compare.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            HStack(alignment: .center, spacing: 16) {
                ScanComparisonCandidateGroup(
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
                    Label("Swap Before and After", systemImage: "arrow.left.arrow.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .disabled(isBusy || (setup.before == nil && setup.after == nil))
                .help("Swap Before and After")

                ScanComparisonCandidateGroup(
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
            .padding(20)

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let statusMessage {
                        Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }

                    ForEach(setup.compatibilityWarnings, id: \.self) { warning in
                        Label(warning.message, systemImage: warning.symbolName)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: 430, alignment: .leading)

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
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 780)
    }
}

private struct ScanComparisonCandidateGroup: View {
    let slot: ScanComparisonSlot
    let candidate: ScanComparisonCandidate?
    let isLoading: Bool
    let canUseCurrentScan: Bool
    let actionsDisabled: Bool
    let onChooseSnapshot: (ScanComparisonSlot) -> Void
    let onUseCurrentScan: (ScanComparisonSlot) -> Void
    let onClear: (ScanComparisonSlot) -> Void

    var body: some View {
        GroupBox {
            Group {
                if isLoading {
                    loadingContent
                } else if let candidate {
                    candidateContent(candidate)
                } else {
                    emptyContent
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 170,
                maxHeight: 170,
                alignment: .topLeading
            )
            .padding(8)
        } label: {
            HStack(spacing: 8) {
                Text(slot.title)
                    .font(.headline)

                if candidate?.isCurrentScan == true {
                    Label("Current Scan", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No Snapshot Selected")
                .font(.subheadline.weight(.medium))

            Text(emptyStateMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            sourceActions
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingContent: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Reading Snapshot…")
                .font(.subheadline.weight(.medium))

            Text("Validating snapshot contents")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateContent(_ candidate: ScanComparisonCandidate) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidate.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(candidate.path)
            }

            Label(
                "Scanned \(RadixFormatters.date(candidate.scanDate))",
                systemImage: "clock"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 28) {
                metric("Size", RadixFormatters.size(candidate.totalAllocatedSize))
                metric("Files", candidate.fileCount.formatted())
                metric("Folders", candidate.directoryCount.formatted())

                if candidate.warningCount > 0 {
                    metric("Warnings", candidate.warningCount.formatted())
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                selectedControls(for: candidate)
            }
        }
    }

    private var emptyStateMessage: String {
        canUseCurrentScan
            ? "Choose a saved snapshot or use the current scan."
            : "Choose a saved snapshot."
    }

    private var sourceActions: some View {
        HStack(spacing: 8) {
            Button("Choose Snapshot…") {
                onChooseSnapshot(slot)
            }

            if canUseCurrentScan {
                Button("Use Current Scan") {
                    onUseCurrentScan(slot)
                }
            }
        }
        .controlSize(.small)
        .disabled(actionsDisabled)
    }

    private func selectedControls(for candidate: ScanComparisonCandidate) -> some View {
        HStack(spacing: 8) {
            Button("Replace…") {
                onChooseSnapshot(slot)
            }

            if canUseCurrentScan, !candidate.isCurrentScan {
                Button {
                    onUseCurrentScan(slot)
                } label: {
                    Label(
                        "Use Current Scan for \(slot.title)",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                .labelStyle(.iconOnly)
                .help("Use Current Scan")
            }

            Button {
                onClear(slot)
            } label: {
                Label("Clear \(slot.title)", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Clear \(slot.title)")
        }
        .controlSize(.small)
        .disabled(actionsDisabled)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
