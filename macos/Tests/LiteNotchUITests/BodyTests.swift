import XCTest

@testable import LiteNotchUI

final class BodyTests: XCTestCase {
    private func fixture(_ name: String) throws -> ViewModel {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try ViewModel.decode(Data(contentsOf: url))
    }

    func testTheLevelFollowsTheEndTimeWhileCountingAndStandsStillOtherwise() {
        let counting = GaugeView(spanMs: 60_000, leftMs: 60_000, emptyAtMs: 100_000)
        XCTAssertEqual(BodyMath.percent(counting, nowMs: 40_000), 100)
        XCTAssertEqual(BodyMath.percent(counting, nowMs: 70_000), 50)
        XCTAssertEqual(BodyMath.percent(counting, nowMs: 200_000), 0, "never below empty")
        let still = GaugeView(spanMs: 60_000, leftMs: 15_000, emptyAtMs: nil)
        XCTAssertEqual(BodyMath.percent(still, nowMs: 999_999), 25)
        XCTAssertEqual(BodyMath.level(GaugeView(spanMs: 0, leftMs: 0, emptyAtMs: nil), nowMs: 0), 0)
    }

    func testTheNumberRedrawsAboutOncePerPercent() {
        XCTAssertEqual(BodyMath.redrawSecs(GaugeView(spanMs: 3_600_000, leftMs: 0, emptyAtMs: nil)), 36)
        XCTAssertEqual(BodyMath.redrawSecs(GaugeView(spanMs: 300_000, leftMs: 0, emptyAtMs: nil)), 10)
    }

    func testSinceLine() {
        XCTAssertEqual(BodyMath.since(nil, nowMs: 0, verb: "Drank"), "Not yet")
        XCTAssertEqual(BodyMath.since(0, nowMs: 30_000, verb: "Drank"), "Drank just now")
        XCTAssertEqual(BodyMath.since(0, nowMs: 20 * 60_000, verb: "Stretched"), "Stretched 20m ago")
        XCTAssertEqual(BodyMath.since(0, nowMs: 130 * 60_000, verb: "Drank"), "Drank 2h ago")
    }

    func testTheCoresGaugesDecodeAndChooseTheCard() throws {
        let vm = try fixture("body")
        let water = try XCTUnwrap(vm.body?.water)
        XCTAssertEqual(water.lastLabel, "+200 ml")
        XCTAssertEqual(vm.body?.stretch?.lastLabel, "+1")
        XCTAssertEqual(vm.settings.body.show, .both)
        XCTAssertEqual(HomeCardPick.card(vm, nowMs: 0), .body)
        XCTAssertEqual(try fixture("body-water").settings.body.show, .water)

        var off = vm
        off.body = nil
        XCTAssertEqual(HomeCardPick.card(off, nowMs: 0), .media, "gauges off: now playing instead")
        // Auto prefers the gauges to the day once a song's minute is over.
        var auto = vm
        auto.settings.day.homeCard = .auto
        auto.day = DayView(startMs: 0, endMs: 1, line: "")
        XCTAssertEqual(HomeCardPick.card(auto, nowMs: 0), .body)
        XCTAssertNil(try fixture("idle").body)
        XCTAssertEqual(try fixture("idle").settings.body, .default)
    }
}

@MainActor
final class LiquidLayoutTests: XCTestCase {
    /// Reported: after a tap the water hung from the top of the tank. A
    /// second layout set `frame` on a layer that carried the fall's
    /// transform, which moved the layer to cancel it.
    func testTheWaterStaysAtTheBottomAfterARefill() {
        let view = LiquidNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 206))
        let body = 206 - LiquidNSView.waveHeight
        func top(_ left: Int, emptyAt: Int?) -> CGFloat {
            view.configure(
                gauge: GaugeView(spanMs: 1000, leftMs: left, emptyAtMs: emptyAt), nowMs: 0,
                color: NSColor.systemBlue.cgColor, animated: false)
            view.layout()
            // The layer's model value: where the water rests when its fall ends,
            // or where it stands still. Its top edge is the body's top.
            return view.water.frame.minY + body
        }
        XCTAssertEqual(top(500, emptyAt: nil), body / 2, accuracy: 0.5, "half, standing still")
        XCTAssertEqual(top(1000, emptyAt: 1000), 0, accuracy: 0.5, "counting: rests empty")
        XCTAssertEqual(top(250, emptyAt: nil), body / 4, accuracy: 0.5, "after a tap, still from the bottom")
        XCTAssertEqual(top(250, emptyAt: nil), body / 4, accuracy: 0.5, "and again")
    }
}
