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
        XCTAssertEqual(BodyMath.since(nil, nowMs: 0, verb: "Drank"), "Full to start")
        XCTAssertEqual(BodyMath.since(0, nowMs: 30_000, verb: "Drank"), "Drank just now")
        XCTAssertEqual(BodyMath.since(0, nowMs: 20 * 60_000, verb: "Stretched"), "Stretched 20m ago")
        XCTAssertEqual(BodyMath.since(0, nowMs: 130 * 60_000, verb: "Drank"), "Drank 2h ago")
    }

    func testTheCoresGaugesDecodeAndChooseTheCard() throws {
        let vm = try fixture("body")
        let water = try XCTUnwrap(vm.body?.water)
        XCTAssertEqual(water.lastLabel, "+1 cup")
        XCTAssertEqual(vm.body?.stretch?.lastLabel, "+1")
        XCTAssertEqual(vm.settings.body.show, .both)
        XCTAssertTrue(BodyConfig.showsBodyCard(vm))
        XCTAssertFalse(DayConfig.showsDayCard(vm))
        XCTAssertEqual(try fixture("body-water").settings.body.show, .water)

        var off = vm
        off.body = nil
        XCTAssertFalse(BodyConfig.showsBodyCard(off), "gauges off: now playing instead")
        XCTAssertNil(try fixture("idle").body)
        XCTAssertEqual(try fixture("idle").settings.body, .default)
    }
}
