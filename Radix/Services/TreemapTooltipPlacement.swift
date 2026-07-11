import CoreGraphics

nonisolated enum TreemapTooltipPlacement {
    nonisolated static func origin(
        for pointer: CGPoint,
        tooltipSize: CGSize,
        in bounds: CGRect,
        gap: CGFloat = 14,
        margin: CGFloat = 8
    ) -> CGPoint {
        let standardizedBounds = bounds.standardized
        let horizontalMargin = min(
            max(margin, 0),
            max(standardizedBounds.width / 2, 0)
        )
        let verticalMargin = min(
            max(margin, 0),
            max(standardizedBounds.height / 2, 0)
        )
        let availableBounds = standardizedBounds.insetBy(
            dx: horizontalMargin,
            dy: verticalMargin
        )
        let tooltipWidth = max(tooltipSize.width, 0)
        let tooltipHeight = max(tooltipSize.height, 0)
        let gap = max(gap, 0)

        var x = pointer.x + gap
        if x + tooltipWidth > availableBounds.maxX {
            x = pointer.x - gap - tooltipWidth
        }

        var y = pointer.y + gap
        if y + tooltipHeight > availableBounds.maxY {
            y = pointer.y - gap - tooltipHeight
        }

        return CGPoint(
            x: clamped(
                x,
                lower: availableBounds.minX,
                upper: max(availableBounds.maxX - tooltipWidth, availableBounds.minX)
            ),
            y: clamped(
                y,
                lower: availableBounds.minY,
                upper: max(availableBounds.maxY - tooltipHeight, availableBounds.minY)
            )
        )
    }

    private nonisolated static func clamped(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        min(max(value, lower), upper)
    }
}
