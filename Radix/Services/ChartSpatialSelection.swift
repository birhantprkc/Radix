import CoreGraphics

nonisolated enum ChartSpatialSelectionDirection {
    case up
    case down
    case left
    case right
}

nonisolated struct ChartSpatialSelectionCandidate: Sendable {
    let nodeID: String
    let center: CGPoint
}

nonisolated enum ChartSpatialSelection {
    nonisolated static func nextNodeID(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartSpatialSelectionCandidate]
    ) -> String? {
        guard !candidates.isEmpty else { return nil }
        guard let selectedNodeID,
              let current = candidates.first(where: { $0.nodeID == selectedNodeID }) else {
            return candidates[0].nodeID
        }

        var bestNodeID: String?
        var bestScore = CGFloat.infinity

        for candidate in candidates where candidate.nodeID != current.nodeID {
            let delta = CGPoint(
                x: candidate.center.x - current.center.x,
                y: candidate.center.y - current.center.y
            )
            let distances = distances(for: delta, moving: direction)
            guard distances.forward > 0 else { continue }

            // Favor nearby candidates while making straight movements predictable.
            let score = distances.forward + (distances.crossAxis * 2)
            if score < bestScore {
                bestNodeID = candidate.nodeID
                bestScore = score
            }
        }

        return bestNodeID
    }

    private nonisolated static func distances(
        for delta: CGPoint,
        moving direction: ChartSpatialSelectionDirection
    ) -> (forward: CGFloat, crossAxis: CGFloat) {
        switch direction {
        case .up:
            (-delta.y, abs(delta.x))
        case .down:
            (delta.y, abs(delta.x))
        case .left:
            (-delta.x, abs(delta.y))
        case .right:
            (delta.x, abs(delta.y))
        }
    }
}
