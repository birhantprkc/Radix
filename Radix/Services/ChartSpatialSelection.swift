import CoreGraphics

nonisolated enum ChartSpatialSelectionDirection {
    case up
    case down
    case left
    case right
}

nonisolated struct ChartSpatialSelectionCandidate: Sendable {
    let nodeID: String
    let frames: [CGRect]

    init(nodeID: String, center: CGPoint) {
        self.nodeID = nodeID
        frames = [CGRect(origin: center, size: .zero)]
    }

    init(nodeID: String, frame: CGRect) {
        self.nodeID = nodeID
        frames = [frame]
    }

    init(nodeID: String, points: [CGPoint]) {
        self.nodeID = nodeID
        frames = points.map { CGRect(origin: $0, size: .zero) }
    }
}

nonisolated struct ChartSpatialSelectionResult: Sendable {
    let nodeID: String
    let targetPoint: CGPoint
}

nonisolated enum ChartSpatialSelection {
    nonisolated static func nextNodeID(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartSpatialSelectionCandidate]
    ) -> String? {
        nextSelection(
            from: selectedNodeID,
            moving: direction,
            among: candidates
        )?.nodeID
    }

    nonisolated static func nextSelection(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartSpatialSelectionCandidate]
    ) -> ChartSpatialSelectionResult? {
        guard !candidates.isEmpty else { return nil }
        guard let selectedNodeID,
              let current = candidates.first(where: { $0.nodeID == selectedNodeID }) else {
            return entrySelection(moving: direction, among: candidates)
        }

        var bestResult: ChartSpatialSelectionResult?
        var bestScore: CandidateScore?

        for candidate in candidates where candidate.nodeID != current.nodeID {
            for currentFrame in current.frames {
                for candidateFrame in candidate.frames {
                    guard let score = score(
                        from: currentFrame,
                        to: candidateFrame,
                        moving: direction
                    ) else {
                        continue
                    }
                    if let bestScore, score >= bestScore { continue }
                    bestResult = ChartSpatialSelectionResult(
                        nodeID: candidate.nodeID,
                        targetPoint: candidateFrame.center
                    )
                    bestScore = score
                }
            }
        }

        return bestResult
    }

    private nonisolated static func entrySelection(
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartSpatialSelectionCandidate]
    ) -> ChartSpatialSelectionResult? {
        var bestResult: ChartSpatialSelectionResult?
        var bestCoordinate = CGFloat.infinity
        var bestCrossAxisCoordinate = CGFloat.infinity

        for candidate in candidates {
            for frame in candidate.frames {
                let coordinate = entryCoordinate(for: frame.center, moving: direction)
                let crossAxisCoordinate = crossAxisCoordinate(
                    for: frame.center,
                    moving: direction
                )
                guard coordinate < bestCoordinate || (
                    coordinate == bestCoordinate &&
                        crossAxisCoordinate < bestCrossAxisCoordinate
                ) else {
                    continue
                }
                bestResult = ChartSpatialSelectionResult(
                    nodeID: candidate.nodeID,
                    targetPoint: frame.center
                )
                bestCoordinate = coordinate
                bestCrossAxisCoordinate = crossAxisCoordinate
            }
        }
        return bestResult
    }

    private nonisolated static func score(
        from currentFrame: CGRect,
        to candidateFrame: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CandidateScore? {
        let delta = CGPoint(
            x: candidateFrame.midX - currentFrame.midX,
            y: candidateFrame.midY - currentFrame.midY
        )
        let centerDistances = distances(for: delta, moving: direction)
        let forwardProgress = forwardProgress(
            from: currentFrame,
            to: candidateFrame,
            moving: direction
        )
        guard forwardProgress > 0 else { return nil }

        let forwardGap = forwardGap(
            between: currentFrame,
            and: candidateFrame,
            moving: direction
        )
        let crossAxisGap = crossAxisGap(
            between: currentFrame,
            and: candidateFrame,
            moving: direction
        )
        let isInDirectionalBeam = crossAxisGap == 0
        guard isInDirectionalBeam || crossAxisGap <= forwardGap else {
            return nil
        }

        return CandidateScore(
            beamRank: isInDirectionalBeam ? 0 : 1,
            distanceSquared: (forwardGap * forwardGap) + (crossAxisGap * crossAxisGap),
            crossAxisDistance: centerDistances.crossAxis,
            forwardDistance: forwardProgress
        )
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

    private nonisolated static func forwardGap(
        between current: CGRect,
        and candidate: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up:
            max(current.minY - candidate.maxY, 0)
        case .down:
            max(candidate.minY - current.maxY, 0)
        case .left:
            max(current.minX - candidate.maxX, 0)
        case .right:
            max(candidate.minX - current.maxX, 0)
        }
    }

    private nonisolated static func forwardProgress(
        from current: CGRect,
        to candidate: CGRect,
        moving direction: ChartSpatialSelectionDirection
    ) -> CGFloat {
        switch direction {
        case .up:
            current.minY - candidate.minY
        case .down:
            candidate.maxY - current.maxY
        case .left:
            current.minX - candidate.minX
        case .right:
            candidate.maxX - current.maxX
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

private extension CGRect {
    nonisolated var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
