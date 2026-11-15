import AppKit
import XCTest
@testable import LiteNotchUI

private func fixture(_ name: String) throws -> ViewModel {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try ViewModel.decode(Data(contentsOf: url))
}

private func compact(_ kind: ActivityKind, ends: Int? = 1, count: Int = 1) -> CompactView {
    CompactView(kind: kind, title: "t", value: "v", endsAtMs: ends, totalSecs: nil, count: count)
}

/// Which activity the closed notch shows when several want it, and how two
/// share it.
final class NotchPriorityTests: XCTestCase {
    // MARK: What the core sends

    func testTheFixtureWithAMeetingSoonDuringFocusHasBothAndTheDot() throws {
        let vm = try fixture("pair")
        XCTAssertEqual(vm.compact.kind, .calendar)
        XCTAssertEqual(vm.compactSecondary?.kind, .pomodoro)
        XCTAssertTrue(vm.waiting)
        XCTAssertEqual(vm.settings.notch, .default)
        XCTAssertEqual(vm.settings.notch.order, NotchConfig.liveOrder)

        let idle = try fixture("idle")
        XCTAssertNil(idle.compactSecondary)
        XCTAssertFalse(idle.waiting)
        XCTAssertTrue(ClosedContent(view: idle).isEmpty)
    }

    func testAViewModelFromBeforeTwoPlacesStillDecodes() throws {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(try fixture("pair"))) as? [String: Any])
        old.removeValue(forKey: "compact_secondary")
        old.removeValue(forKey: "waiting")
        var settings = try XCTUnwrap(old["settings"] as? [String: Any])
        settings.removeValue(forKey: "notch")
        old["settings"] = settings
        let vm = try ViewModel.decode(JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(vm.compactSecondary)
        XCTAssertFalse(vm.waiting)
        XCTAssertEqual(vm.settings.notch, .default)
    }

    func testNotchSettingsAndThePauseCommandHaveTheCoresWireFormat() throws {
        var settings = try fixture("idle").settings
        settings.notch = NotchConfig(order: [.pomodoro, .media], hidden: [.agent], twoPlaces: false, waitingDot: false)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(ShellCommand.setSettings(settings).encode().utf8)) as? [String: Any])
        let notch = try XCTUnwrap((sent["settings"] as? [String: Any])?["notch"] as? [String: Any])
        XCTAssertEqual(notch as NSDictionary, ["order": ["pomodoro", "media"], "hidden": ["agent"],
                                               "two_places": false, "waiting_dot": false] as NSDictionary)
        XCTAssertEqual(ShellCommand.pomodoroPause.encode(), #"{"cmd":"pomodoro_pause"}"#)
    }

    // MARK: Geometry

    func testOneActivityKeepsItsWidthAndTheDotAddsALittle() {
        for floating in [false, true] {
            for kind in [ActivityKind.pomodoro, .timer, .media, .caffeine, .meeting, .agent, .calendar] {
                let c = compact(kind)
                let before = floating ? NotchGeometry.floatingWingWidth(for: c) : NotchGeometry.wingWidth(for: c)
                XCTAssertEqual(NotchGeometry.wingWidth(for: ClosedContent(primary: c), floating: floating), before,
                               "\(kind) alone looks as it always did")
                XCTAssertEqual(NotchGeometry.wingWidth(for: ClosedContent(primary: c, waiting: true), floating: floating),
                               before + NotchGeometry.waitingDotSpace)
            }
            XCTAssertEqual(NotchGeometry.wingWidth(for: ClosedContent(primary: nil), floating: floating), 0)
            XCTAssertGreaterThan(NotchGeometry.wingWidth(for: ClosedContent(primary: nil, waiting: true), floating: floating),
                                 NotchGeometry.waitingDot, "room for the dot beside a bare notch")
        }
    }

    /// Reported: on a Mac with a notch the lone dot was hard to see, tucked
    /// against the camera housing. The wing leaves clear space on the
    /// housing's side of the dot, at least as much as its outer padding.
    func testTheLoneDotSitsClearOfTheCameraHousing() {
        let wing = NotchGeometry.wingWidth(for: ClosedContent(primary: nil, waiting: true), floating: false)
        let outerPadding: CGFloat = 12
        let clear = wing - outerPadding - NotchGeometry.waitingDot
        XCTAssertGreaterThanOrEqual(clear, 14, "space between the housing and the dot")
        XCTAssertGreaterThanOrEqual(clear, outerPadding)
        // With an activity the dot is at the far end of a full wing already.
        XCTAssertGreaterThan(NotchGeometry.wingWidth(for: ClosedContent(primary: compact(.pomodoro), waiting: true),
                                                     floating: false), wing)
    }

    func testTwoActivitiesFitIconAndTimeOnEachSideWithinABound() {
        let kinds: [ActivityKind] = [.meeting, .calendar, .timer, .pomodoro, .media, .caffeine, .agent]
        for floating in [false, true] {
            for a in kinds {
                for b in kinds where a != b {
                    let pair = ClosedContent(primary: compact(a, count: 3), secondary: compact(b, count: 3), waiting: true)
                    let w = NotchGeometry.wingWidth(for: pair, floating: floating)
                    XCTAssertGreaterThanOrEqual(w, 30, "\(a)+\(b)")
                    XCTAssertLessThanOrEqual(w, floating ? 90 : 104, "\(a)+\(b)")
                    // Both wings are the same width, so the notch stays centred;
                    // each must hold its own side.
                    let need = 16 + (NotchGeometry.pairValueWidth(compact(a, count: 3)) > 0
                        ? NotchGeometry.pairGap + NotchGeometry.pairValueWidth(compact(a, count: 3)) : 0)
                    XCTAssertGreaterThanOrEqual(w, need, "\(a) fits on the left")
                }
            }
        }
        // Icon only where there is no time to show.
        XCTAssertEqual(NotchGeometry.pairValueWidth(compact(.caffeine, ends: nil)), 0)
        XCTAssertEqual(NotchGeometry.pairValueWidth(compact(.agent, count: 1)), 0)
        XCTAssertGreaterThan(NotchGeometry.pairValueWidth(compact(.agent, count: 2)), 0)
    }

    func testTheShapeIsSizedForWhatItShows() {
        let attached = NotchLayout(style: .attached, notch: CGSize(width: 185, height: 32))
        let floating = NotchLayout(style: .floating, notch: NotchGeometry.fallbackSize, hasNotch: false, menuBarHeight: 24)
        let one = ClosedContent(primary: compact(.pomodoro))
        let two = ClosedContent(primary: compact(.calendar), secondary: compact(.pomodoro))
        XCTAssertEqual(attached.size(for: .closed, content: one), attached.size(for: .closed, compact: compact(.pomodoro)))
        // Without a notch (this floating layout) the closed notch is one row.
        XCTAssertEqual(floating.size(for: .closed, content: one).width,
                       max(floating.centerWidth, NotchGeometry.rowWidth(for: one, floating: true)))
        XCTAssertGreaterThan(attached.size(for: .closed, content: two).width, attached.size(for: .closed, content: one).width)
        XCTAssertEqual(attached.size(for: .closed, content: two).height, 32)
        XCTAssertEqual(floating.size(for: .closed, content: two).height, 21)
        // Open and as a toast the size does not depend on the activities.
        XCTAssertEqual(attached.size(for: .expanded, content: two), attached.size(for: .expanded, compact: nil))
        XCTAssertEqual(floating.size(for: .toast, content: two), floating.size(for: .toast, compact: nil))
    }

    func testAnIdleFirstActivityShowsNothingAndDropsTheSecond() {
        let c = ClosedContent(primary: compact(.idle), secondary: compact(.media))
        XCTAssertNil(c.primary)
        XCTAssertNil(c.secondary)
        XCTAssertTrue(c.isEmpty)
        XCTAssertFalse(ClosedContent(primary: compact(.idle), waiting: true).isEmpty, "the dot alone is drawn")
        XCTAssertEqual(ClosedActivityView.spoken(ClosedContent(primary: compact(.calendar), secondary: compact(.pomodoro),
                                                                waiting: true)),
                       "t v. t v. An agent is waiting for you")
    }

    // MARK: Settings preview

    func testThePreviewAppliesTheSameRuleAsTheCore() {
        let d = NotchConfig.default
        func kinds(_ r: (first: ActivityKind?, second: ActivityKind?)) -> [ActivityKind?] { [r.first, r.second] }
        // The case that started this: focus running, a meeting five minutes away.
        XCTAssertEqual(kinds(NotchPriority.resolve([.pomodoro, .calendar], config: d)), [.calendar, .pomodoro])
        XCTAssertEqual(kinds(NotchPriority.resolve([.media, .pomodoro], config: d)), [.pomodoro, .media])
        XCTAssertEqual(kinds(NotchPriority.resolve(NotchConfig.liveOrder.reversed(), config: d)), [.meeting, .calendar])
        XCTAssertEqual(kinds(NotchPriority.resolve([], config: d)), [nil, nil])

        var one = d
        one.twoPlaces = false
        XCTAssertEqual(kinds(NotchPriority.resolve([.pomodoro, .calendar], config: one)), [.calendar, nil])

        var custom = d
        custom.order = [.pomodoro]
        custom.hidden = [.media]
        XCTAssertEqual(kinds(NotchPriority.resolve([.pomodoro, .calendar, .media], config: custom)), [.pomodoro, .calendar])
        XCTAssertEqual(kinds(NotchPriority.resolve([.media], config: custom)), [nil, nil], "hidden: Home only")
    }

    func testMovingAnActivityKeepsEveryActivityOnce() {
        let all = NotchConfig.liveOrder
        XCTAssertEqual(NotchPriority.move(.calendar, by: -1, in: all).prefix(2), [.calendar, .meeting])
        XCTAssertEqual(NotchPriority.move(.meeting, by: -1, in: all), all, "already first")
        XCTAssertEqual(NotchPriority.move(.agent, by: 1, in: all), all, "already last")
        XCTAssertEqual(NotchPriority.move(.pomodoro, by: 1, in: all)[3...4], [.media, .pomodoro])
        // A short or untidy saved order is filled out first.
        let moved = NotchPriority.move(.media, by: 1, in: [.media, .media, .banner])
        XCTAssertEqual(moved.count, all.count)
        XCTAssertEqual(Set(moved), Set(all))
        XCTAssertEqual(moved.prefix(2), [.meeting, .media])
        XCTAssertEqual(NotchPriority.normalizedOrder([.unknown, .idle]), all)
    }

    func testEverySituationDrawsSomethingAndSaysWhat() {
        XCTAssertEqual(NotchPriority.situations.count, 4)
        for s in NotchPriority.situations {
            let content = NotchPriority.content(for: s, config: .default)
            XCTAssertFalse(content.isEmpty, s.id)
            XCTAssertFalse(NotchPriority.explanation(for: s, config: .default).isEmpty)
        }
        let meeting = NotchPriority.situations[0]
        XCTAssertEqual(NotchPriority.explanation(for: meeting, config: .default),
                       "Event about to start first, focus session beside it.")
        let busy = NotchPriority.situations[3]
        var off = NotchConfig.default
        off.waitingDot = false
        off.hidden = NotchConfig.liveOrder
        XCTAssertTrue(NotchPriority.content(for: busy, config: off).isEmpty)
        let text = NotchPriority.explanation(for: busy, config: off)
        XCTAssertTrue(text.hasPrefix("Nothing in the notch."))
        XCTAssertTrue(text.hasSuffix("No sign of the waiting agent."))
        for kind in NotchConfig.liveOrder {
            XCTAssertNotEqual(NotchPriority.name(kind), kind.rawValue)
            XCTAssertNotEqual(NotchPriority.symbol(kind), "circle")
        }
    }

    // MARK: The banner's button

    func testTheStartingBannersButtonPausesFocusAndAnswersTheBanner() throws {
        let json = #"""
        {"id":7,"source":"calendar","title":"Design review","body":"Starting now","priority":"high",
         "group":"calendar-1-e1","ttl_secs":null,"created_ms":0,"read":false,"open":null,"action":"pause_focus"}
        """#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let banner = try d.decode(NotificationItem.self, from: Data(json.utf8))
        XCTAssertEqual(banner.action, .pauseFocus)
        let plain = try d.decode(NotificationItem.self, from: Data(json.replacingOccurrences(of: #","action":"pause_focus""#, with: "").utf8))
        XCTAssertNil(plain.action)
        let newer = try d.decode(NotificationItem.self, from: Data(json.replacingOccurrences(of: "pause_focus", with: "snooze").utf8))
        XCTAssertEqual(newer.action, .unknown)

        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        model.primary.banner(banner, perform: .pauseFocus)
        XCTAssertEqual(bridge.sentObjects.compactMap { $0["cmd"] as? String },
                       ["pomodoro_pause", "notify_opened", "notify_dismiss_banner"])
        model.primary.banner(newer, perform: .unknown)
        XCTAssertEqual(bridge.sent.count, 3, "an action this version does not know does nothing")
    }
}
