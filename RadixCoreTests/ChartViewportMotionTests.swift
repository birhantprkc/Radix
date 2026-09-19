import CoreGraphics
import Testing

@testable import RadixCore

struct ChartViewportMotionTests {
    @Test
    func animationPresentsIntermediateGeometryAndFinishesExactly() throws {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let anchor = CGPoint(x: 160, y: 70)
        let target = ChartViewportTransform.identity.zoomed(by: 4, anchor: anchor, in: frame)
        var motion = ChartViewportMotion()
        motion.move(to: target, at: 10, duration: 1)
        #expect(motion.transform == .identity)
        #expect(motion.target == target)

        motion.advance(to: 10.5)
        #expect(motion.isAnimating)
        #expect(motion.transform.scale > 1 && motion.transform.scale < 4)
        #expect(motion.transform.frame(for: frame).contains(frame))
        let hit = try #require(motion.transform.localChartPoint(for: anchor, in: frame))
        #expect(abs(hit.point.x / hit.size.width - 0.75) < 0.000_001)
        #expect(abs(hit.point.y / hit.size.height - 0.5) < 0.000_001)

        motion.advance(to: 11)
        #expect(motion.transform == target)
        #expect(!motion.isAnimating)
    }

    @Test
    func gestureInterruptsFromPresentedFrameWithoutFinishingOldAnimation() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        var motion = ChartViewportMotion()
        motion.move(to: ChartViewportTransform(scale: 4), at: 0, duration: 1)
        motion.advance(to: 0.25)
        let dragged = motion.transform.panned(by: CGSize(width: 10, height: -5), in: frame)
        motion.move(to: dragged, at: 0.3, duration: 0)
        motion.advance(to: 2)
        #expect(motion.transform == dragged)
        #expect(motion.target == dragged)
        #expect(!motion.isAnimating)
    }

    @Test
    func repeatedControlZoomAccumulatesAtTargetButStartsAtPresentedFrame() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        var motion = ChartViewportMotion()
        motion.move(to: motion.target.zoomed(by: 1.25, anchor: nil, in: frame), at: 0, duration: 1)
        motion.advance(to: 0.25)
        let presented = motion.transform
        motion.move(to: motion.target.zoomed(by: 1.25, anchor: nil, in: frame), at: 0.25, duration: 1)
        #expect(motion.transform == presented)
        #expect(motion.target.scale == 1.5625)
        motion.advance(to: 1.25)
        #expect(motion.transform.scale == 1.5625)
    }

    @Test
    func resetInterpolatesToIdentityAndStopRetainsPresentedFrame() {
        var motion = ChartViewportMotion()
        motion.move(to: ChartViewportTransform(scale: 4, offset: CGSize(width: 90, height: -40)), at: 0, duration: 0)
        motion.move(to: .identity, at: 1, duration: 1)
        motion.advance(to: 1.5)
        #expect(motion.transform.scale > 1 && motion.transform.scale < 4)
        let presented = motion.transform
        motion.stop()
        motion.advance(to: 3)
        #expect(motion.transform == presented)
        #expect(motion.target == presented)
        #expect(!motion.isAnimating)
        motion.move(to: .identity, at: 4, duration: 0)
        #expect(motion.transform == .identity)
    }
}
