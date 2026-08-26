import SwiftUI

struct TreemapBaseCanvas: View, Equatable {
    let segments: [TreemapSegment]
    let renderVersion: Int
    let colorScheme: ColorScheme
    let contentFrame: CGRect

    static func == (lhs: TreemapBaseCanvas, rhs: TreemapBaseCanvas) -> Bool {
        lhs.renderVersion == rhs.renderVersion
            && lhs.colorScheme == rhs.colorScheme
            && lhs.contentFrame == rhs.contentFrame
    }

    var body: some View {
        Canvas { context, size in
            let viewportBounds = CGRect(origin: .zero, size: size)
            context.clip(to: Path(viewportBounds))

            for segment in segments {
                let displayRect = TreemapRenderer.displayRect(
                    for: segment,
                    in: contentFrame
                )
                guard displayRect.intersects(viewportBounds) else { continue }

                let path = tilePath(in: displayRect)
                let style = TreemapChartStyler.baseStyle(
                    for: segment,
                    colorScheme: colorScheme
                )
                context.fill(path, with: .color(style.fillColor))
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

struct TreemapLabelCanvas: View, Equatable {
    let segments: [TreemapSegment]
    let renderVersion: Int
    let colorScheme: ColorScheme
    let contentFrame: CGRect

    static func == (lhs: TreemapLabelCanvas, rhs: TreemapLabelCanvas) -> Bool {
        lhs.renderVersion == rhs.renderVersion
            && lhs.colorScheme == rhs.colorScheme
            && lhs.contentFrame == rhs.contentFrame
    }

    var body: some View {
        Canvas { context, size in
            let viewportBounds = CGRect(origin: .zero, size: size)
            context.clip(to: Path(viewportBounds))

            for segment in segments {
                drawLabel(
                    for: segment,
                    in: contentFrame,
                    viewportBounds: viewportBounds,
                    context: &context
                )
            }
        }
    }

    private func drawLabel(
        for segment: TreemapSegment,
        in contentFrame: CGRect,
        viewportBounds: CGRect,
        context: inout GraphicsContext
    ) {
        let rect = TreemapRenderer.displayRect(for: segment, in: contentFrame)
        guard rect.intersects(viewportBounds),
              rect.width >= 42,
              rect.height >= 20 else {
            return
        }

        let horizontalPadding: CGFloat = 6
        let availableWidth = rect.width - (horizontalPadding * 2)
        guard availableWidth > 18 else { return }

        let labelStyle = TreemapChartStyler.labelStyle(colorScheme: colorScheme)
        let name = truncated(segment.label, for: availableWidth, averageCharacterWidth: 6.1)
        let nameText = context.resolve(
            Text(name)
                .font(.system(size: 11, weight: segment.showsContainerHeader ? .semibold : .medium))
                .foregroundStyle(labelStyle.primaryColor)
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
                .foregroundStyle(labelStyle.secondaryColor)
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
    let segment: TreemapSegment?
    let contentFrame: CGRect

    var body: some View {
        Canvas { context, size in
            guard let segment else { return }
            let viewportBounds = CGRect(origin: .zero, size: size)
            let displayRect = TreemapRenderer.displayRect(
                for: segment,
                in: contentFrame
            )
            guard displayRect.intersects(viewportBounds) else { return }
            context.clip(to: Path(viewportBounds))

            let style = TreemapChartStyler.selectionOverlayStyle()
            guard let accentPath = strokedTilePath(
                for: segment,
                in: contentFrame,
                lineWidth: style.strokeWidth
            ) else {
                context.fill(
                    tilePath(in: displayRect),
                    with: .color(style.strokeColor.opacity(0.72))
                )
                return
            }
            context.stroke(
                accentPath,
                with: .color(style.strokeColor),
                lineWidth: style.strokeWidth
            )
        }
    }
}

struct TreemapDiscardPileOverlay: View, Equatable {
    let segments: [TreemapSegment]
    let renderVersion: Int
    let overlay: DiscardPileVisualizationOverlay
    let contentFrame: CGRect

    static func == (lhs: TreemapDiscardPileOverlay, rhs: TreemapDiscardPileOverlay) -> Bool {
        lhs.renderVersion == rhs.renderVersion
            && lhs.overlay == rhs.overlay
            && lhs.contentFrame == rhs.contentFrame
    }

    var body: some View {
        Canvas { context, size in
            let viewportBounds = CGRect(origin: .zero, size: size)
            context.clip(to: Path(viewportBounds))

            for segment in segments {
                let aggregateContainerNodeID = segment.isAggregate
                    ? segment.containerNodeID
                    : nil
                guard let role = overlay.role(
                    for: segment.nodeID,
                    aggregateContainerNodeID: aggregateContainerNodeID
                ) else { continue }
                let displayRect = TreemapRenderer.displayRect(for: segment, in: contentFrame)
                guard displayRect.intersects(viewportBounds) else { continue }
                let path = tilePath(in: displayRect)

                switch role {
                case .queuedRoot:
                    context.fill(
                        path,
                        with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.66))
                    )
                    context.stroke(
                        path,
                        with: .color(Color.accentColor.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 2, dash: [5, 3])
                    )
                case .queuedDescendant:
                    // The queued root tile already covers nested treemap content.
                    break
                case .containsQueuedItem:
                    context.stroke(
                        path,
                        with: .color(Color.accentColor.opacity(0.72)),
                        style: StrokeStyle(lineWidth: 1.75, dash: [4, 3])
                    )
                }
            }
        }
    }
}

struct TreemapHoverOverlay: View, Equatable {
    let segment: TreemapSegment?
    let colorScheme: ColorScheme
    let contentFrame: CGRect

    var body: some View {
        Canvas { context, size in
            guard let segment else { return }
            let viewportBounds = CGRect(origin: .zero, size: size)
            let displayRect = TreemapRenderer.displayRect(
                for: segment,
                in: contentFrame
            )
            guard displayRect.intersects(viewportBounds) else { return }
            context.clip(to: Path(viewportBounds))

            let path = tilePath(in: displayRect)
            let style = TreemapChartStyler.hoverOverlayStyle(colorScheme: colorScheme)
            if style.fillOpacity > 0 {
                context.fill(path, with: .color(style.fillColor.opacity(style.fillOpacity)))
            }
            if let strokePath = strokedTilePath(
                for: segment,
                in: contentFrame,
                lineWidth: style.strokeWidth
            ) {
                context.stroke(
                    strokePath,
                    with: .color(style.strokeColor),
                    lineWidth: style.strokeWidth
                )
            }
        }
    }
}

private func tilePath(
    in displayRect: CGRect,
    insetBy additionalInset: CGFloat = 0
) -> Path {
    let baseRadius = min(CGFloat(5), min(displayRect.width, displayRect.height) * 0.1)
    let maximumInset = max(min(displayRect.width, displayRect.height) / 2, 0)
    let inset = min(max(additionalInset, 0), maximumInset)
    let rect = displayRect.insetBy(dx: inset, dy: inset)
    let radius = max(baseRadius - inset, 0)
    return Path(roundedRect: rect, cornerRadius: max(radius, 0))
}

private func strokedTilePath(
    for segment: TreemapSegment,
    in contentFrame: CGRect,
    lineWidth: CGFloat
) -> Path? {
    guard let strokeRect = TreemapRenderer.strokeRect(
        for: segment,
        in: contentFrame,
        lineWidth: lineWidth
    ) else {
        return nil
    }

    let baseRadius = min(CGFloat(5), min(strokeRect.width, strokeRect.height) * 0.1)
    let radius = max(baseRadius - (lineWidth / 2), 0)
    return Path(roundedRect: strokeRect, cornerRadius: radius)
}
