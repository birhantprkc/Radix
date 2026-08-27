import SwiftUI

struct SunburstBaseCanvas: View, Equatable {
    let segments: [SunburstSegment]
    let renderVersion: Int

    static func == (lhs: SunburstBaseCanvas, rhs: SunburstBaseCanvas) -> Bool {
        lhs.renderVersion == rhs.renderVersion
    }

    var body: some View {
        Canvas { context, size in
            for segment in segments {
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.baseStyle(for: segment)
                context.fill(path, with: .color(style.fillColor))
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

struct SunburstSelectionOverlay: View, Equatable {
    let segments: [SunburstSelectionOverlaySegment]

    var body: some View {
        Canvas { context, size in
            for overlaySegment in segments {
                let segment = overlaySegment.segment
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.selectionOverlayStyle(
                    for: segment,
                    role: overlaySegment.role
                )
                if style.fillOpacity > 0 {
                    context.fill(path, with: .color(style.fillColor))
                }
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

struct SunburstDiscardPileOverlay: View, Equatable {
    let segments: [SunburstSegment]
    let renderVersion: Int
    let overlay: DiscardPileVisualizationOverlay

    static func == (lhs: SunburstDiscardPileOverlay, rhs: SunburstDiscardPileOverlay) -> Bool {
        lhs.renderVersion == rhs.renderVersion
            && lhs.overlay == rhs.overlay
    }

    var body: some View {
        Canvas { context, size in
            for segment in segments {
                let aggregateContainerNodeID = segment.isAggregate
                    ? segment.containerNodeID
                    : nil
                guard let role = overlay.role(
                    for: segment.nodeID,
                    aggregateContainerNodeID: aggregateContainerNodeID
                ) else { continue }
                let path = SunburstRenderer.path(for: segment, in: size)
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
                    context.fill(
                        path,
                        with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.66))
                    )
                case .containsQueuedItem:
                    context.stroke(
                        path,
                        with: .color(Color.accentColor.opacity(0.72)),
                        style: StrokeStyle(lineWidth: 1.75, dash: [4, 3])
                    )
                case .movingToTrashRoot:
                    context.fill(
                        path,
                        with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.66))
                    )
                    context.stroke(
                        path,
                        with: .color(Color.secondary.opacity(0.8)),
                        lineWidth: 1.5
                    )
                case .movingToTrashDescendant:
                    context.fill(
                        path,
                        with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.66))
                    )
                case .containsMovingToTrashItem:
                    context.stroke(
                        path,
                        with: .color(Color.secondary.opacity(0.72)),
                        style: StrokeStyle(lineWidth: 1.75, dash: [4, 3])
                    )
                }
            }
        }
    }
}

struct SunburstHoverOverlay: View, Equatable {
    let segment: SunburstSegment?

    var body: some View {
        Canvas { context, size in
            guard let segment else { return }

            let path = SunburstRenderer.path(for: segment, in: size)
            let style = SunburstChartStyler.hoverOverlayStyle(for: segment)
            if style.fillOpacity > 0 {
                context.fill(path, with: .color(style.fillColor))
            }
            context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
        }
    }
}
