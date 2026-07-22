import CoreGraphics

nonisolated enum ChartSpatialSelectionDirection {
    case up
    case down
    case left
    case right
}

nonisolated struct ChartSpatialSelectionCandidate: Sendable {
    let nodeID: String
    let frame: CGRect

    var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    init(nodeID: String, center: CGPoint) {
        self.nodeID = nodeID
        frame = CGRect(origin: center, size: .zero)
    }

    init(nodeID: String, frame: CGRect) {
        self.nodeID = nodeID
        self.frame = frame
    }
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
            return entryNodeID(moving: direction, among: candidates)
        }

        var bestNodeID: String?
        var bestScore: CandidateScore?

        for candidate in candidates where candidate.nodeID != current.nodeID {
            let delta = CGPoint(
                x: candidate.center.x - current.center.x,
                y: candidate.center.y - current.center.y
            )
            let distances = distances(for: delta, moving: direction)
            guard distances.forward > 0 else { continue }

            let crossAxisGap = crossAxisGap(
                between: current.frame,
                and: candidate.frame,
                moving: direction
            )
            let isInDirectionalBeam = crossAxisGap == 0
            guard isInDirectionalBeam || distances.crossAxis <= distances.forward else {
                continue
            }

            let score = CandidateScore(
                beamRank: isInDirectionalBeam ? 0 : 1,
                distanceSquared: (distances.forward * distances.forward)
                    + (distances.crossAxis * distances.crossAxis),
                crossAxisDistance: distances.crossAxis,
                forwardDistance: distances.forward
            )
            if let bestScore, score >= bestScore { continue }
            bestNodeID = candidate.nodeID
            bestScore = score
        }

        return bestNodeID
    }

    private nonisolated static func entryNodeID(
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartSpatialSelectionCandidate]
    ) -> String? {
        candidates.min { lhs, rhs in
            let lhsCoordinate = entryCoordinate(for: lhs.center, moving: direction)
            let rhsCoordinate = entryCoordinate(for: rhs.center, moving: direction)
            if lhsCoordinate == rhsCoordinate {
                return crossAxisCoordinate(for: lhs.center, moving: direction)
                    < crossAxisCoordinate(for: rhs.center, moving: direction)
            }
            return lhsCoordinate < rhsCoordinate
        }?.nodeID
    }

    private nonisolated static func entryCoordinate(
        for center: CGPoint,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up: -center.y
        case .down: center.y
        case .left: -center.x
        case .right: center.x
        }
    }

    private nonisolated static func crossAxisCoordinate(
        for center: CGPoint,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up, .down: center.x
        case .left, .right: center.y
        }
    }

    private nonisolated static func crossAxisGap(
        between current: CGRect,
        and candidate: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up, .down:
            intervalGap(
                current.minX...current.maxX,
                candidate.minX...candidate.maxX
            )
        case .left, .right:
            intervalGap(
                current.minY...current.maxY,
                candidate.minY...candidate.maxY
            )
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

    private nonisolated struct CandidateScore: Comparable {
        let beamRank: Int
        let distanceSquared: CGFloat
        let crossAxisDistance: CGFloat
        let forwardDistance: CGFloat

        static func < (lhs: CandidateScore, rhs: CandidateScore) -> Bool {
            if lhs.beamRank != rhs.beamRank {
                return lhs.beamRank < rhs.beamRank
            }
            if lhs.distanceSquared != rhs.distanceSquared {
                return lhs.distanceSquared < rhs.distanceSquared
            }
            if lhs.crossAxisDistance != rhs.crossAxisDistance {
                return lhs.crossAxisDistance < rhs.crossAxisDistance
            }
            return lhs.forwardDistance < rhs.forwardDistance
        }
    }
}
