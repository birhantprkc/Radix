import CoreGraphics
import Testing

@testable import RadixCore

struct ChartScrollInputTests {
    @Test(arguments: [true, false])
    func panPreservesTheDirectionAlreadySuppliedByAppKit(isPrecise: Bool) {
        let delta = CGSize(width: 2, height: -3)
        let pan = ChartScrollInput.panDelta(delta, isPrecise: isPrecise)
        let reversed = ChartScrollInput.panDelta(
            CGSize(width: -delta.width, height: -delta.height), isPrecise: isPrecise
        )
        #expect(pan.width > 0 && pan.height < 0)
        #expect(reversed.width == -pan.width && reversed.height == -pan.height)
        #expect(abs(pan.height) == (isPrecise ? 3 : 30))
    }

    @Test
    func wheelZoomUsesLineUnitsAndOppositeInputReversesTheScale() {
        let delta = CGSize(width: 0, height: 1)
        let pixels = ChartScrollInput.zoomFactor(delta, isPrecise: true)
        let lines = ChartScrollInput.zoomFactor(delta, isPrecise: false)
        #expect(abs(pixels - 1.0025) < 0.000_001)
        #expect(abs(lines - 1.1) < 0.000_001)
        let reversed = ChartScrollInput.zoomFactor(CGSize(width: 0, height: -1), isPrecise: false)
        #expect(abs(lines * reversed - 1) < 0.000_001)
        #expect(ChartScrollInput.zoomFactor(CGSize(width: -1, height: 0), isPrecise: false) == lines)
        #expect(ChartScrollInput.zoomFactor(.zero, isPrecise: false) == 1)
    }

    @Test
    func panCapsLargeDeltasWithoutChangingTheirSign() {
        #expect(ChartScrollInput.panDelta(CGSize(width: 100, height: -100), isPrecise: false)
            == CGSize(width: 80, height: -80))
    }
}
