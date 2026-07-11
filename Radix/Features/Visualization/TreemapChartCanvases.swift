import SwiftUI

struct TreemapBaseCanvas: View, Equatable {
    let segments: [TreemapSegment]
    let renderVersion: Int

    static func == (lhs: TreemapBaseCanvas, rhs: TreemapBaseCanvas) -> Bool {
        lhs.renderVersion == rhs.renderVersion
    }

    var body: some View {
        Canvas { context, size in
            for segment in segments {
                let path = tilePath(for: segment, in: size)
                let style = TreemapChartStyler.baseStyle(for: segment)
                context.fill(path, with: .color(style.fillColor))
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }

            for segment in segments {
                drawLabel(for: segment, in: size, context: &context)
            }
        }
    }

    private func drawLabel(
        for segment: TreemapSegment,
        in size: CGSize,
        context: inout GraphicsContext
    ) {
        let rect = displayRect(for: segment, in: size)
        guard rect.width >= 42, rect.height >= 20 else { return }

        let horizontalPadding: CGFloat = 6
        let availableWidth = rect.width - (horizontalPadding * 2)
        guard availableWidth > 18 else { return }

        let name = truncated(segment.label, for: availableWidth, averageCharacterWidth: 6.1)
        let nameText = context.resolve(
            Text(name)
                .font(.system(size: 11, weight: segment.showsContainerHeader ? .semibold : .medium))
                .foregroundStyle(.primary.opacity(0.86))
        )
        var labelContext = context
        let clipRect = CGRect(
            x: rect.minX + horizontalPadding,
            y: rect.minY + 3,
            width: availableWidth,
            height: segment.showsContainerHeader ? 15 : max(rect.height - 6, 0)
        )
        labelContext.clip(to: Path(clipRect))
        labelContext.draw(
            nameText,
            at: CGPoint(x: clipRect.minX, y: clipRect.minY),
            anchor: .topLeading
        )

        guard !segment.showsContainerHeader,
              rect.width >= 70,
              rect.height >= 42 else {
            return
        }

        let sizeText = context.resolve(
            Text(RadixFormatters.size(segment.totalSize))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.9))
        )
        labelContext.draw(
            sizeText,
            at: CGPoint(x: clipRect.minX, y: clipRect.minY + 17),
            anchor: .topLeading
        )
    }

    private func truncated(
        _ text: String,
        for width: CGFloat,
        averageCharacterWidth: CGFloat
    ) -> String {
        let maximumCount = max(Int(width / averageCharacterWidth), 1)
        guard text.count > maximumCount, maximumCount > 1 else { return text }
        return String(text.prefix(maximumCount - 1)) + "…"
    }
}

struct TreemapSelectionOverlay: View, Equatable {
    let segments: [TreemapSelectionOverlaySegment]

    var body: some View {
        Canvas { context, size in
            for overlay in segments {
                let path = tilePath(for: overlay.segment, in: size)
                let style = TreemapChartStyler.selectionOverlayStyle(
                    for: overlay.segment,
                    role: overlay.role
                )
                if style.fillOpacity > 0 {
                    context.fill(path, with: .color(style.fillColor))
                }
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

struct TreemapHoverOverlay: View, Equatable {
    let segment: TreemapSegment?

    var body: some View {
        Canvas { context, size in
            guard let segment else { return }
            let path = tilePath(for: segment, in: size)
            let style = TreemapChartStyler.hoverOverlayStyle(for: segment)
            if style.fillOpacity > 0 {
                context.fill(path, with: .color(style.fillColor))
            }
            context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
        }
    }
}

private func displayRect(for segment: TreemapSegment, in size: CGSize) -> CGRect {
    let rect = TreemapRenderer.rect(for: segment, in: size)
    let inset = min(CGFloat(0.75), min(rect.width, rect.height) * 0.12)
    return rect.insetBy(dx: inset, dy: inset)
}

private func tilePath(for segment: TreemapSegment, in size: CGSize) -> Path {
    let rect = displayRect(for: segment, in: size)
    let radius = min(CGFloat(5), min(rect.width, rect.height) * 0.1)
    return Path(roundedRect: rect, cornerRadius: max(radius, 0))
}
