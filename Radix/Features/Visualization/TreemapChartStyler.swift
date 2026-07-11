import SwiftUI

enum TreemapChartStyler {
    static func baseStyle(for segment: TreemapSegment) -> SunburstSegmentDrawingStyle {
        if segment.isAggregate {
            return SunburstSegmentDrawingStyle(
                fillBaseColor: Color(nsColor: .tertiaryLabelColor),
                fillOpacity: 0.24,
                strokeColor: Color(nsColor: .separatorColor).opacity(0.7),
                strokeWidth: 1
            )
        }

        let opacity = standardOpacity(for: segment)
        return SunburstSegmentDrawingStyle(
            fillBaseColor: baseColor(for: segment),
            fillOpacity: opacity,
            strokeColor: Color(nsColor: .separatorColor).opacity(0.58),
            strokeWidth: 1
        )
    }

    static func selectionOverlayStyle(
        for segment: TreemapSegment,
        role: TreemapSelectionRole
    ) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetOpacity: Double
        let strokeColor: Color
        let strokeWidth: CGFloat

        switch role {
        case .ancestor:
            targetOpacity = min(base.fillOpacity + 0.05, 0.86)
            strokeColor = Color.white.opacity(0.25)
            strokeWidth = 1.5
        case .selected:
            targetOpacity = min(base.fillOpacity + 0.12, 0.94)
            strokeColor = Color.accentColor.opacity(0.95)
            strokeWidth = 3
        }

        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetOpacity),
            strokeColor: strokeColor,
            strokeWidth: strokeWidth
        )
    }

    static func hoverOverlayStyle(for segment: TreemapSegment) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetOpacity = segment.isAggregate
            ? 0.42
            : min(base.fillOpacity + 0.16, 0.96)
        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetOpacity),
            strokeColor: Color.primary.opacity(0.88),
            strokeWidth: 2.5
        )
    }

    private static func baseColor(for segment: TreemapSegment) -> Color {
        switch segment.colorToken.role {
        case .freeSpace:
            return Color(nsColor: .systemGray)
        case .aggregate:
            return Color(nsColor: .tertiaryLabelColor)
        case .normal:
            return SunburstColorResolver.color(for: segment.colorToken)
        }
    }

    private static func standardOpacity(for segment: TreemapSegment) -> Double {
        if segment.colorToken.role == .freeSpace { return 0.34 }
        return max(0.38, 0.8 - (Double(segment.depth) * 0.055))
    }

    private static func overlayOpacity(from baseOpacity: Double, to targetOpacity: Double) -> Double {
        guard targetOpacity > baseOpacity else { return 0 }
        let remainingOpacity = max(1 - baseOpacity, .leastNonzeroMagnitude)
        return min(max((targetOpacity - baseOpacity) / remainingOpacity, 0), 1)
    }
}
