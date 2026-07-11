import SwiftUI

struct TreemapTileDrawingStyle {
    let fillColor: Color
    let strokeColor: Color
    let strokeWidth: CGFloat
}

struct TreemapLabelDrawingStyle {
    let primaryColor: Color
    let secondaryColor: Color
}

struct TreemapSelectionDrawingStyle {
    let strokeColor: Color
    let strokeWidth: CGFloat
}

struct TreemapHoverDrawingStyle {
    let fillColor: Color
    let fillOpacity: Double
    let strokeColor: Color
    let strokeWidth: CGFloat
}

enum TreemapChartStyler {
    static func baseStyle(
        for segment: TreemapSegment,
        colorScheme: ColorScheme
    ) -> TreemapTileDrawingStyle {
        TreemapTileDrawingStyle(
            fillColor: TreemapColorResolver.color(
                for: segment.colorToken,
                appearance: appearance(for: colorScheme)
            ),
            strokeColor: colorScheme == .dark
                ? Color.black.opacity(0.38)
                : Color.white.opacity(0.72),
            strokeWidth: 1
        )
    }

    static func labelStyle(colorScheme: ColorScheme) -> TreemapLabelDrawingStyle {
        switch colorScheme {
        case .dark:
            return TreemapLabelDrawingStyle(
                primaryColor: Color.white.opacity(0.96),
                secondaryColor: Color.white.opacity(0.72)
            )
        default:
            return TreemapLabelDrawingStyle(
                primaryColor: Color.black.opacity(0.84),
                secondaryColor: Color.black.opacity(0.62)
            )
        }
    }

    static func selectionOverlayStyle() -> TreemapSelectionDrawingStyle {
        TreemapSelectionDrawingStyle(
            strokeColor: Color.accentColor,
            strokeWidth: 2.75
        )
    }

    static func hoverOverlayStyle(colorScheme: ColorScheme) -> TreemapHoverDrawingStyle {
        TreemapHoverDrawingStyle(
            fillColor: colorScheme == .dark ? .white : .black,
            fillOpacity: colorScheme == .dark ? 0.075 : 0.055,
            strokeColor: colorScheme == .dark
                ? Color.white.opacity(0.72)
                : Color.black.opacity(0.58),
            strokeWidth: 1.75
        )
    }

    private static func appearance(for colorScheme: ColorScheme) -> TreemapColorAppearance {
        colorScheme == .dark ? .dark : .light
    }
}
