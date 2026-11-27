import AppKit
import XCTest

@testable import LiteNotchUI

/// Reported: after a tap the water jumped instead of rising. Two causes,
/// both only visible in a real window: a second layout in the same pass
/// cancelled the rise, and the fall (starting later) overwrote it on the
/// same property. The rise now lives on its own layer.
@MainActor
final class LiquidRiseTests: XCTestCase {
    func testTheWaterRisesAfterATap() {
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 240), styleMask: .borderless,
            backing: .buffered, defer: false)
        let view = LiquidNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 220))
        win.contentView?.addSubview(view)
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let color = NSColor.systemBlue.cgColor
        let span = 3_600_000
        view.configure(
            gauge: GaugeView(spanMs: span, leftMs: 0, emptyAtMs: now + span / 2), nowMs: now,
            color: color, animated: true)
        view.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // A cup: half to 60 %. Laid out twice, as AppKit sometimes does.
        view.configure(
            gauge: GaugeView(spanMs: span, leftMs: 0, emptyAtMs: now + span * 6 / 10), nowMs: now,
            color: color, animated: true)
        view.layout()
        view.layout()
        func shown() -> CGFloat {
            let y = { (l: CALayer) in
                l.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            }
            return y(view.water) + y(view.lift)
        }
        let target = -(220 - LiquidNSView.waveHeight) * 0.4
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(shown(), target - 3, "still on its way up")
        RunLoop.main.run(until: Date().addingTimeInterval(LiquidNSView.riseSecs))
        XCTAssertEqual(shown(), target, accuracy: 1, "arrived")
    }
}
