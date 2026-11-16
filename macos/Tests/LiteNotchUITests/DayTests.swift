import XCTest
@testable import LiteNotchUI

private func fixture(_ name: String) throws -> ViewModel {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try ViewModel.decode(Data(contentsOf: url))
}

final class DayTests: XCTestCase {
    private let start = 1_000_000_000
    private var end: Int { start + 8 * 3_600_000 }

    func testPercentBeforeDuringAndAfter() {
        func label(_ hoursIn: Double) -> String {
            let now = start + Int(hoursIn * 3_600_000)
            return Format.dayProgress(Format.dayPercent(startMs: start, endMs: end, nowMs: now))
        }
        XCTAssertEqual(label(-1), "\u{2212}13%")
        XCTAssertEqual(label(0), "0%")
        XCTAssertEqual(label(3), "37%")
        XCTAssertEqual(label(8), "100%")
        XCTAssertEqual(label(9.5), "+18%")
    }

    func testIconFollowsTheTimeOfDay() {
        func icon(_ hoursIn: Double) -> String {
            Format.daySymbol(startMs: start, endMs: end, nowMs: start + Int(hoursIn * 3_600_000))
        }
        // 10:00–18:00: horizon before 10, sun 10–15, horizon 15–18, moon after.
        XCTAssertEqual(icon(-3), "sun.horizon.fill")
        XCTAssertEqual(icon(0), "sun.max.fill")
        XCTAssertEqual(icon(4.9), "sun.max.fill")
        XCTAssertEqual(icon(5), "sun.horizon.fill")
        XCTAssertEqual(icon(8), "moon.fill")
        XCTAssertEqual(Format.daySymbolChanges(startMs: start, endMs: end).count, 3)
        // A short day has no full-sun part.
        XCTAssertEqual(Format.daySymbol(startMs: start, endMs: start + 3_600_000, nowMs: start), "sun.horizon.fill")
    }

    func testHomeCardChoice() throws {
        var vm = try fixture("day")
        XCTAssertEqual(vm.settings.day.homeCard, .auto)
        XCTAssertTrue(DayConfig.showsDayCard(vm), "nothing playing")
        vm.settings.day.homeCard = .media
        XCTAssertFalse(DayConfig.showsDayCard(vm))
        vm.settings.day.homeCard = .day
        vm.day = nil
        XCTAssertFalse(DayConfig.showsDayCard(vm), "day progress off or a day off")
    }

    func testNextChangeIsTheNextWholePercent() {
        let now = start + 3 * 3_600_000 + 1
        let next = Format.nextDayPercentMs(startMs: start, endMs: end, nowMs: now)
        XCTAssertEqual(Format.dayPercent(startMs: start, endMs: end, nowMs: next), 38)
        XCTAssertEqual(Format.dayPercent(startMs: start, endMs: end, nowMs: next - 1), 37)
        // Before the start too.
        let early = start - 3_600_000
        let n = Format.nextDayPercentMs(startMs: start, endMs: end, nowMs: early)
        XCTAssertGreaterThan(n, early)
        XCTAssertEqual(Format.dayPercent(startMs: start, endMs: end, nowMs: n), -12)
    }

    func testFixtureCarriesTodayAndTheClosedNotchActivity() throws {
        let vm = try fixture("day")
        let day = try XCTUnwrap(vm.day)
        XCTAssertTrue(vm.settings.day.enabled)
        XCTAssertEqual(vm.compact.kind, .day)
        XCTAssertEqual(vm.compact.endsAtMs, day.endMs)
        XCTAssertEqual(vm.compact.totalSecs.map { $0 * 1000 }, day.endMs - day.startMs)
        XCTAssertFalse(day.line.isEmpty)
        XCTAssertNil(try fixture("idle").day)
        XCTAssertEqual(NotchConfig.liveOrder.last, .day)
    }

    func testOldSettingsWithoutDayGetTheDefault() throws {
        var vm = try fixture("idle")
        vm.settings.day = DayConfig(enabled: true, startMin: 540, endMin: 1050, days: 0b111_1111)
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(vm.settings)) as? [String: Any])
        let day = try XCTUnwrap(obj["day"] as? [String: Any])
        XCTAssertEqual(day["start_min"] as? Int, 540)
        obj.removeValue(forKey: "day")
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let back = try d.decode(Settings.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(back.day, .default)
    }
}
