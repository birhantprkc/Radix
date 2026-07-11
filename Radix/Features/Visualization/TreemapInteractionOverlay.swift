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
    let discardPileDragItem: (CGPoint) -> TreemapDiscardPileDragItem?
    let onDiscardPileDragActiveChange: (Bool) -> Void

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
        view.discardPileDragItem = discardPileDragItem
        view.onDiscardPileDragActiveChange = onDiscardPileDragActiveChange
    }

    final class InteractionView: NSView, NSDraggingSource {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        var discardPileDragItem: (CGPoint) -> TreemapDiscardPileDragItem? = { _ in nil }
        var onDiscardPileDragActiveChange: (Bool) -> Void = { _ in }

        private static let dragThreshold: CGFloat = 3
        private static let dragImageSize = NSSize(width: 54, height: 38)
        private var trackingArea: NSTrackingArea?
        private var mouseDownLocation: CGPoint?
        private var didDrag = false

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }

            let nextTrackingArea = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(nextTrackingArea)
            trackingArea = nextTrackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(eventLocation(event))
        }

        override func mouseMoved(with event: NSEvent) {
            onHover(eventLocation(event))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = eventLocation(event)
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !didDrag,
                  let mouseDownLocation,
                  didExceedDragThreshold(from: mouseDownLocation, to: eventLocation(event)),
                  let dragItem = discardPileDragItem(mouseDownLocation),
                  let draggingItem = draggingItem(for: dragItem, at: mouseDownLocation) else {
                return
            }

            didDrag = true
            onDiscardPileDragActiveChange(true)
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if !didDrag {
                onClick(eventLocation(event), event.clickCount)
            }
            mouseDownLocation = nil
            didDrag = false
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            true
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            onDiscardPileDragActiveChange(false)
        }

        private func eventLocation(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        private func didExceedDragThreshold(from start: CGPoint, to end: CGPoint) -> Bool {
            let dx = end.x - start.x
            let dy = end.y - start.y
            return ((dx * dx) + (dy * dy)) >= (Self.dragThreshold * Self.dragThreshold)
        }

        private func draggingItem(
            for item: TreemapDiscardPileDragItem,
            at location: CGPoint
        ) -> NSDraggingItem? {
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
            let components = SunburstColorResolver.components(for: segment.colorToken)
            return NSColor(
                calibratedHue: CGFloat(components.hue),
                saturation: CGFloat(components.saturation),
                brightness: CGFloat(components.brightness),
                alpha: 1
            )
        }
    }
}
