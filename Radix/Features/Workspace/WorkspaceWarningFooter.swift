import AppKit
import SwiftUI

struct WarningFooter: View {
    let warnings: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let actions: WorkspaceActions
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                    Text(warnings.first?.path ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButtons
                .controlSize(.small)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if shouldSuggestFullDiskAccess {
                Button("Open Full Disk Access") {
                    actions.openFullDiskAccessSettings()
                }
                .buttonStyle(.bordered)

                dismissButton
            } else {
                dismissButton
            }
        }
    }

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Dismiss warning")
        .accessibilityLabel("Dismiss warning")
    }

    private var summary: String {
        String(localized: "\(warnings.count) locations had limited access or scan warnings.", comment: "Warning summary for locations with limited access or scan warnings. The location count controls pluralization.")
    }
}
