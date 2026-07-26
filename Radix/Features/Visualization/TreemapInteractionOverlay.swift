import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TreemapDiscardPileDragItem {
    let payload: DiscardPileDragPayload
    let segment: TreemapSegment
}

struct TreemapInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onMove: (ChartSpatialSelectionDirection) -> Bool
    let onKeyboardFocus: () -> Void
    let isKeyboardFocused: Bool
    let onPan: (CGSize, CGPoint) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let canStartPan: (CGPoint) -> Bool
    let discardPileDragItem: (CGPoint) -> TreemapDiscardPileDragItem?
    let onDiscardPileDragActiveChange: (Bool) -> Void
    let isPanEnabled: Bool

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        update(nsView)
    }

    private func update(_ view: InteractionView) {
        view.onHover = onHover
        view.onClick = onClick
        view.onMove = onMove
        view.onKeyboardFocus = onKeyboardFocus
        view.isKeyboardFocused = isKeyboardFocused
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.canStartPan = canStartPan
        view.discardPileDragItem = discardPileDragItem
        view.onDragActiveChange = onDiscardPileDragActiveChange
        view.isPanEnabled = isPanEnabled
        view.acquireKeyboardFocusIfNeeded()
    }

    final class InteractionView: ChartViewportInteractionView {
        var discardPileDragItem: (CGPoint) -> TreemapDiscardPileDragItem? = { _ in nil }

        private static let dragImageSize = NSSize(width: 54, height: 38)

        override func draggingItem(at location: CGPoint) -> NSDraggingItem? {
            guard let item = discardPileDragItem(location) else { return nil }
            guard let data = try? JSONEncoder().encode(item.payload) else { return nil }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(
                data,
                forType: NSPasteboard.PasteboardType(DiscardPileDragPayload.contentType.identifier)
            )

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let size = Self.dragImageSize
            draggingItem.setDraggingFrame(
                NSRect(
                    x: location.x - (size.width / 2),
                    y: location.y - (size.height / 2),
                    width: size.width,
                    height: size.height
                ),
                contents: dragImage(for: item.segment)
            )
            return draggingItem
        }

        private func dragImage(for segment: TreemapSegment) -> NSImage {
            NSImage(size: Self.dragImageSize, flipped: false) { bounds in
                let tileRect = bounds.insetBy(dx: 4, dy: 4)
                let path = NSBezierPath(roundedRect: tileRect, xRadius: 6, yRadius: 6)

                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                shadow.shadowBlurRadius = 5
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                self.dragColor(for: segment).withAlphaComponent(0.9).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()

                NSColor.white.withAlphaComponent(0.62).setStroke()
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
        }

        private func dragColor(for segment: TreemapSegment) -> NSColor {
            let appearance: TreemapColorAppearance = effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua ? .dark : .light
            let components = TreemapColorResolver.components(
                for: segment.colorToken,
                appearance: appearance
            )
            return NSColor(
                calibratedHue: CGFloat(components.hue),
                saturation: CGFloat(components.saturation),
                brightness: CGFloat(components.brightness),
                alpha: 1
            )
        }
    }
}
