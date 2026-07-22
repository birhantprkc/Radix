import SwiftUI

struct ChartSpatialSelectionKeyboardHandler: ViewModifier {
    let isEnabled: Bool
    let onMove: (ChartSpatialSelectionDirection) -> Bool

    func body(content: Content) -> some View {
        content.onKeyPress(
            keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]
        ) { press in
            let selectionModifiers: EventModifiers = [.command, .control, .option, .shift]
            guard isEnabled,
                  press.modifiers.intersection(selectionModifiers).isEmpty,
                  let direction = direction(for: press.key) else {
                return .ignored
            }
            return onMove(direction) ? .handled : .ignored
        }
    }

    private func direction(for key: KeyEquivalent) -> ChartSpatialSelectionDirection? {
        switch key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        default: nil
        }
    }
}

extension View {
    func chartSpatialSelectionKeyboardHandler(
        isEnabled: Bool,
        onMove: @escaping (ChartSpatialSelectionDirection) -> Bool
    ) -> some View {
        modifier(ChartSpatialSelectionKeyboardHandler(
            isEnabled: isEnabled,
            onMove: onMove
        ))
    }
}
