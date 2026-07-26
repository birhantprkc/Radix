import SwiftUI

struct ChartViewportControls: View {
    let zoomText: String
    let canZoomOut: Bool
    let canZoomIn: Bool
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let reset: () -> Void
    @State private var showsControls = false

    var body: some View {
        let accessibilityLabel = String(
            localized: "Zoom Controls",
            comment: "Accessibility label for opening the disk map zoom controls."
        )

        Button {
            showsControls.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(zoomText)
        .help(accessibilityLabel)
        .popover(isPresented: $showsControls, arrowEdge: .trailing) {
            controlRow
                .padding(10)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 6) {
            controlButton(
                systemName: "minus.magnifyingglass",
                accessibilityLabel: String(localized: "Zoom Out", comment: "Accessibility label for zooming out of the disk map."),
                action: zoomOut
            )
            .disabled(!canZoomOut)

            Text(zoomText)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)

            controlButton(
                systemName: "plus.magnifyingglass",
                accessibilityLabel: String(localized: "Zoom In", comment: "Accessibility label for zooming into the disk map."),
                action: zoomIn
            )
            .disabled(!canZoomIn)

            Divider()
                .frame(height: 16)

            controlButton(
                systemName: "arrow.counterclockwise",
                accessibilityLabel: String(localized: "Reset Zoom", comment: "Accessibility label for resetting the disk map zoom."),
                action: reset
            )
            .disabled(!canZoomOut)
        }
    }

    private func controlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
