import AppKit

@MainActor
class ChartKeyboardInteractionView: NSView {
    var onMove: (ChartSpatialSelectionDirection) -> Bool = { _ in false }

    override var acceptsFirstResponder: Bool { true }

    func focusForKeyboardInput() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let selectionModifiers: NSEvent.ModifierFlags = [
            .command,
            .control,
            .option,
            .shift
        ]
        guard event.modifierFlags.intersection(selectionModifiers).isEmpty,
              let direction = spatialSelectionDirection(for: event),
              onMove(direction) else {
            super.keyDown(with: event)
            return
        }
    }

    private func spatialSelectionDirection(
        for event: NSEvent
    ) -> ChartSpatialSelectionDirection? {
        switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }
}
