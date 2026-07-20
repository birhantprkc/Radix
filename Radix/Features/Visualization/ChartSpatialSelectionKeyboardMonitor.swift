import AppKit
import SwiftUI

struct ChartSpatialSelectionKeyboardMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onMove: (ChartSpatialSelectionDirection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onMove = onMove
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            coordinator?.windowNumber = nsView?.window?.windowNumber
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var isEnabled = false
        var onMove: (ChartSpatialSelectionDirection) -> Void = { _ in }
        var windowNumber: Int?

        private var monitor: Any?

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      isEnabled,
                      event.windowNumber == windowNumber,
                      let direction = Self.direction(for: event) else {
                    return event
                }
                onMove(direction)
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private static func direction(for event: NSEvent) -> ChartSpatialSelectionDirection? {
            let selectionModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(selectionModifiers).isEmpty else { return nil }

            switch event.keyCode {
            case 123: return .left
            case 124: return .right
            case 125: return .down
            case 126: return .up
            default: return nil
            }
        }
    }
}
