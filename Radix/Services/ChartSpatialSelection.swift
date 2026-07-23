import CoreGraphics

nonisolated enum ChartSpatialSelectionDirection {
    case up
    case down
    case left
    case right
}

nonisolated struct ChartRectangleSelectionCandidate: Sendable {
    let nodeID: String
    let frame: CGRect
}

nonisolated enum ChartRectangleSpatialSelection {
    nonisolated static func nextNodeID(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartRectangleSelectionCandidate]
    ) -> String? {
        guard !candidates.isEmpty else { return nil }
        guard let selectedNodeID,
              let current = candidates.first(where: { $0.nodeID == selectedNodeID }) else {
            return entryNodeID(moving: direction, among: candidates)
        }

        var bestNodeID: String?
        var bestScore: SpatialCandidateScore?

        for candidate in candidates where candidate.nodeID != current.nodeID {
            guard let score = score(
                from: current.frame,
                to: candidate.frame,
                moving: direction
            ) else {
                continue
            }
            if let bestScore, score >= bestScore { continue }
            bestNodeID = candidate.nodeID
            bestScore = score
        }

        return bestNodeID
    }

    private nonisolated static func entryNodeID(
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartRectangleSelectionCandidate]
    ) -> String? {
        candidates.min { lhs, rhs in
            let lhsCoordinate = entryCoordinate(for: lhs.frame, moving: direction)
            let rhsCoordinate = entryCoordinate(for: rhs.frame, moving: direction)
            if lhsCoordinate != rhsCoordinate {
                return lhsCoordinate < rhsCoordinate
            }
            return crossAxisCoordinate(for: lhs.frame, moving: direction)
                < crossAxisCoordinate(for: rhs.frame, moving: direction)
        }?.nodeID
    }

    private nonisolated static func score(
        from current: CGRect,
        to candidate: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> SpatialCandidateScore? {
        guard let forwardGap = directionalGap(
            from: current,
            to: candidate,
            moving: direction
        ) else {
            return nil
        }

        let crossAxisGap = crossAxisGap(
            between: current,
            and: candidate,
            moving: direction
        )
        guard crossAxisGap == 0 || crossAxisGap <= forwardGap else {
            return nil
        }

        return SpatialCandidateScore(
            distanceSquared: (forwardGap * forwardGap) + (crossAxisGap * crossAxisGap),
            crossAxisDistance: crossAxisCenterDistance(
                between: current,
                and: candidate,
                moving: direction
            )
        )
    }

    private nonisolated static func directionalGap(
        from current: CGRect,
        to candidate: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat? {
        switch direction {
        case .up:
            guard candidate.maxY <= current.minY else { return nil }
            return current.minY - candidate.maxY
        case .down:
            guard candidate.minY >= current.maxY else { return nil }
            return candidate.minY - current.maxY
        case .left:
            guard candidate.maxX <= current.minX else { return nil }
            return current.minX - candidate.maxX
        case .right:
            guard candidate.minX >= current.maxX else { return nil }
            return candidate.minX - current.maxX
        }
    }

    private nonisolated static func crossAxisGap(
        between current: CGRect,
        and candidate: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up, .down:
            intervalGap(current.minX...current.maxX, candidate.minX...candidate.maxX)
        case .left, .right:
            intervalGap(current.minY...current.maxY, candidate.minY...candidate.maxY)
        }
    }

    private nonisolated static func intervalGap(
        _ lhs: ClosedRange<CGFloat>,
        _ rhs: ClosedRange<CGFloat>
    ) -> CGFloat {
        if lhs.upperBound < rhs.lowerBound {
            return rhs.lowerBound - lhs.upperBound
        }
        if rhs.upperBound < lhs.lowerBound {
            return lhs.lowerBound - rhs.upperBound
        }
        return 0
    }

    private nonisolated static func crossAxisCenterDistance(
        between current: CGRect,
        and candidate: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up, .down:
            abs(candidate.midX - current.midX)
        case .left, .right:
            abs(candidate.midY - current.midY)
        }
    }

    private nonisolated static func entryCoordinate(
        for frame: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up: -frame.maxY
        case .down: frame.minY
        case .left: -frame.maxX
        case .right: frame.minX
        }
    }

    private nonisolated static func crossAxisCoordinate(
        for frame: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up, .down: frame.midX
        case .left, .right: frame.midY
        }
    }
}

private nonisolated struct SpatialCandidateScore: Comparable {
    let distanceSquared: CGFloat
    let crossAxisDistance: CGFloat

    static func < (lhs: SpatialCandidateScore, rhs: SpatialCandidateScore) -> Bool {
        if lhs.distanceSquared != rhs.distanceSquared {
            return lhs.distanceSquared < rhs.distanceSquared
        }
        return lhs.crossAxisDistance < rhs.crossAxisDistance
    }
}
