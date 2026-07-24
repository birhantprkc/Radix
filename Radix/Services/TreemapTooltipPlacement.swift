import CoreGraphics

nonisolated enum TreemapTooltipPlacement {
    nonisolated static func origin(
        for pointer: CGPoint,
        tooltipSize: CGSize,
        in bounds: CGRect,
        avoiding avoidanceFrame: CGRect? = nil,
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

        let trailingX = pointer.x + gap
        let leadingX = pointer.x - gap - tooltipWidth
        let belowY = pointer.y + gap
        let aboveY = pointer.y - gap - tooltipHeight
        let preferredX = trailingX + tooltipWidth <= availableBounds.maxX
            ? trailingX
            : leadingX
        let alternateX = preferredX == trailingX ? leadingX : trailingX
        let preferredY = belowY + tooltipHeight <= availableBounds.maxY
            ? belowY
            : aboveY
        let alternateY = preferredY == belowY ? aboveY : belowY
        let candidates = [
            CGPoint(x: preferredX, y: preferredY),
            CGPoint(x: alternateX, y: preferredY),
            CGPoint(x: preferredX, y: alternateY),
            CGPoint(x: alternateX, y: alternateY)
        ].map { candidate in
            CGPoint(
                x: clamped(
                    candidate.x,
                    lower: availableBounds.minX,
                    upper: max(availableBounds.maxX - tooltipWidth, availableBounds.minX)
                ),
                y: clamped(
                    candidate.y,
                    lower: availableBounds.minY,
                    upper: max(availableBounds.maxY - tooltipHeight, availableBounds.minY)
                )
            )
        }

        guard let avoidanceFrame else { return candidates[0] }
        let standardizedAvoidanceFrame = avoidanceFrame.standardized
        return candidates.first { candidate in
            !CGRect(
                origin: candidate,
                size: CGSize(width: tooltipWidth, height: tooltipHeight)
            ).intersects(standardizedAvoidanceFrame)
        } ?? candidates[0]
    }

    private nonisolated static func clamped(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        min(max(value, lower), upper)
    }
}
