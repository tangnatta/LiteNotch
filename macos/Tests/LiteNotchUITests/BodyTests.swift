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

final class HomeAutoTests: XCTestCase {
    private let t0 = 10_000_000
    private let span = 100 * 60_000

    /// Everything on: a gauge at `pct` (still), the day, and a song.
    private func vm(pct: Int, songAt: Int?, playing: Bool = true, day: Bool = true) throws -> ViewModel {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/body.json")
        var v = try ViewModel.decode(Data(contentsOf: url))
        v.settings.day.homeCard = .auto
        v.body = BodyView(
            water: GaugeView(spanMs: span, leftMs: span * pct / 100, emptyAtMs: nil),
            stretch: GaugeView(spanMs: span, leftMs: span, emptyAtMs: nil))
        v.day = day ? DayView(startMs: 0, endMs: 1, line: "") : nil
        v.media = MediaView(
            app: "Music", title: "One", artist: "Band", album: "", playing: playing, durationMs: nil,
            positionMs: nil, positionAtMs: t0, controllable: true, artworkPath: nil, changedAtMs: songAt)
        return v
    }

    func testTheOrder() throws {
        let song = t0 - 10_000
        // 1. A gauge below 20 % comes before a new song.
        XCTAssertEqual(HomeCardPick.card(try vm(pct: 19, songAt: song), nowMs: t0), .body)
        // 2. A new song's minute.
        XCTAssertEqual(HomeCardPick.card(try vm(pct: 30, songAt: song), nowMs: t0), .media)
        XCTAssertEqual(HomeCardPick.card(try vm(pct: 80, songAt: song), nowMs: t0), .media)
        // 3. Below 50 % once the minute is over.
        XCTAssertEqual(HomeCardPick.card(try vm(pct: 49, songAt: t0 - 60_000), nowMs: t0), .body)
        // 4. The day.
        XCTAssertEqual(HomeCardPick.card(try vm(pct: 50, songAt: t0 - 60_000), nowMs: t0), .day)
        // 5. Music while it plays, with day progress off.
        XCTAssertEqual(HomeCardPick.card(try vm(pct: 80, songAt: nil, day: false), nowMs: t0), .media)
        // 6. Nothing playing: the gauges rather than an empty card.
        XCTAssertEqual(
            HomeCardPick.card(try vm(pct: 80, songAt: nil, playing: false, day: false), nowMs: t0), .body)
    }

    func testItRedrawsWhenAGaugeFallsPastAMark() throws {
        var v = try vm(pct: 60, songAt: nil)
        // Counting: 60 % now, empty in 60 min.
        v.body?.water = GaugeView(spanMs: span, leftMs: 0, emptyAtMs: t0 + span * 60 / 100)
        let half = try XCTUnwrap(HomeCardPick.nextChangeMs(v, nowMs: t0))
        XCTAssertEqual(BodyMath.percent(try XCTUnwrap(v.body?.water), nowMs: half - 1), 50)
        XCTAssertEqual(BodyMath.percent(try XCTUnwrap(v.body?.water), nowMs: half), 49)
        XCTAssertEqual(HomeCardPick.card(v, nowMs: half - 1), .day)
        XCTAssertEqual(HomeCardPick.card(v, nowMs: half), .body)
        let low = try XCTUnwrap(HomeCardPick.nextChangeMs(v, nowMs: half))
        XCTAssertEqual(BodyMath.percent(try XCTUnwrap(v.body?.water), nowMs: low), 19)
        XCTAssertNil(HomeCardPick.nextChangeMs(v, nowMs: low))
    }
}

final class ClosedBodyTests: XCTestCase {
    func testTheClosedNotchReadsTheCoresGauge() {
        let counting = CompactView(
            kind: .body, title: "Water", value: "", endsAtMs: 10_000_000 + 2_700_000, totalSecs: 5400,
            count: 0)
        XCTAssertEqual(BodyMath.percent(BodyMath.gauge(counting), nowMs: 10_000_000), 50)
        let still = CompactView(kind: .body, title: "Stretch", value: "33%", endsAtMs: nil, totalSecs: 3600, count: 0)
        XCTAssertEqual(BodyMath.percent(BodyMath.gauge(still), nowMs: 0), 33)
        XCTAssertNil(BodyMath.nextPercentMs(BodyMath.gauge(still), nowMs: 0), "still: drawn once")
    }

    func testItRedrawsOncePerPercent() {
        let g = GaugeView(spanMs: 100_000, leftMs: 0, emptyAtMs: 100_000)
        var now = 0
        var seen: [Int] = []
        while let next = BodyMath.nextPercentMs(g, nowMs: now), seen.count < 200 {
            XCTAssertGreaterThan(next, now)
            now = next
            seen.append(BodyMath.percent(g, nowMs: now))
        }
        XCTAssertEqual(seen, Array((0...99).reversed()), "every whole percent once, down to empty")
    }
}

final class BodyReviewTests: XCTestCase {
    /// The Settings › Notch preview has no span; it showed 0 % for "48%".
    func testAStandInWithoutASpanKeepsItsPercent() {
        let sample = NotchPriority.sample(.body)
        XCTAssertNil(sample.totalSecs)
        XCTAssertEqual(BodyMath.percent(BodyMath.gauge(sample), nowMs: 0), 48)
    }

    /// Auto: a new song while water falls past 50 % inside the song's
    /// minute. Both times must be handed over, or the card stays on music.
    func testEveryChangeTimeIsHandedToTheTimeline() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/body.json")
        var v = try ViewModel.decode(Data(contentsOf: url))
        v.settings.day.homeCard = .auto
        let t0 = 10_000_000
        let span = 100 * 60_000
        // 50.2 % now: below 50 % (49 shown) after 42 s, inside the minute.
        v.body = BodyView(
            water: GaugeView(spanMs: span, leftMs: 0, emptyAtMs: t0 + span * 502 / 1000), stretch: nil)
        v.media = MediaView(
            app: "Music", title: "One", artist: "Band", album: "", playing: true, durationMs: nil,
            positionMs: nil, positionAtMs: t0, controllable: true, artworkPath: nil, changedAtMs: t0)
        let times = HomeCardPick.changeTimesMs(v, nowMs: t0)
        XCTAssertEqual(times.count, 3, "half, low and the end of the minute")
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.contains(t0 + HomeCardPick.musicMs))
        XCTAssertLessThan(times[0], t0 + HomeCardPick.musicMs, "50 % falls first")
        XCTAssertEqual(HomeCardPick.card(v, nowMs: times[0]), .media, "past 50 %, still the minute")
        XCTAssertEqual(HomeCardPick.card(v, nowMs: t0 + HomeCardPick.musicMs), .body)
    }
}
