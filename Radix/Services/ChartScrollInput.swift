import CoreGraphics
import Foundation

/// NSEvent deltas already incorporate the user's scrolling direction preference.
nonisolated enum ChartScrollInput {
    static func panDelta(_ delta: CGSize, isPrecise: Bool) -> CGSize {
        let unitScale: CGFloat = isPrecise ? 1 : 10
        return CGSize(
            width: min(max(delta.width * unitScale, -80), 80),
            height: min(max(delta.height * unitScale, -80), 80)
        )
    }

    static func zoomFactor(_ delta: CGSize, isPrecise: Bool) -> CGFloat {
        let amount = delta.height != 0 ? delta.height : -delta.width
        // Pixel scrolling remains continuous; one wheel line is a useful zoom step.
        return pow(isPrecise ? 1.0025 : 1.1, amount)
    }
}
