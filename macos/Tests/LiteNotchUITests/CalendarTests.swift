import AppKit
import XCTest
@testable import LiteNotchUI

private func fixture(_ name: String) throws -> ViewModel {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try ViewModel.decode(Data(contentsOf: url))
}

/// A calendar store that answers at once with whatever the test put in it.
private final class FakeCalendar: CalendarSource {
    var access: CalendarAccess
    var grants = true
    var stored: [CalendarEventInput] = []
    var asked = 0
    var reads: [(Date, Date)] = []
    var onChange: (() -> Void)?

    init(access: CalendarAccess) { self.access = access }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        asked += 1
        access = grants ? .granted : .denied
        done(grants)
    }

    func events(from: Date, to: Date, _ done: @escaping ([CalendarEventInput]) -> Void) {
        reads.append((from, to))
        done(stored)
    }
}

final class CalendarTests: XCTestCase {
    private let t0 = 1_794_400_000_000

    // MARK: Decoding and commands

    func testTheCalendarFixtureDecodesWithItsEventsAndCountdown() throws {
        let vm = try fixture("calendar")
        XCTAssertTrue(vm.settings.calendar.enabled)
        XCTAssertEqual(vm.settings.calendar.alertMinutes, 5)
        XCTAssertEqual(vm.calendar.events.map(\.title), ["Design review", "1:1 with Sam", "Dentist"])
        XCTAssertEqual(vm.calendar.events[0].color, "#1BADF8")
        XCTAssertEqual(vm.calendar.events[0].location, "Room 3")
        // Inside the reminder time the closed notch counts down to the start.
        XCTAssertEqual(vm.compact.kind, .calendar)
        XCTAssertEqual(vm.compact.endsAtMs, vm.calendar.events[0].startMs)
        XCTAssertGreaterThan(NotchGeometry.wingWidth(for: vm.compact), 0)
        XCTAssertGreaterThan(NotchGeometry.islandWingWidth(for: vm.compact), 0)
    }

    func testTheCalendarIsOffByDefaultAndAViewModelWithoutItStillDecodes() throws {
        let idle = try fixture("idle")
        XCTAssertFalse(idle.settings.calendar.enabled)
        XCTAssertTrue(idle.calendar.events.isEmpty)

        // What a core from before the calendar sends.
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(idle)) as? [String: Any])
        old.removeValue(forKey: "calendar")
        var settings = try XCTUnwrap(old["settings"] as? [String: Any])
        settings.removeValue(forKey: "calendar")
        old["settings"] = settings
        let vm = try ViewModel.decode(JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(vm.calendar, .empty)
        XCTAssertEqual(vm.settings.calendar, .default)
    }

    func testCalendarEventsAreSentInTheShapeTheCoreReads() throws {
        let command = ShellCommand.calendarEvents([
            CalendarEventInput(id: "e1", title: "Stand-up", startMs: 10, endMs: 20, calendar: "Work",
                               color: "#FF3B30", location: "Room 3"),
            CalendarEventInput(id: "e2", title: "Lunch", startMs: 30, endMs: 40),
        ])
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.encode().utf8)) as? [String: Any])
        XCTAssertEqual(sent["cmd"] as? String, "calendar_events")
        let events = try XCTUnwrap(sent["events"] as? [[String: Any]])
        XCTAssertEqual(events[0] as NSDictionary, [
            "id": "e1", "title": "Stand-up", "start_ms": 10, "end_ms": 20, "all_day": false,
            "calendar": "Work", "color": "#FF3B30", "location": "Room 3",
        ] as NSDictionary)
        XCTAssertTrue(events[1]["color"] is NSNull)
    }

    func testCalendarSettingsRoundTripInSnakeCase() throws {
        var settings = try fixture("idle").settings
        settings.calendar = CalendarConfig(enabled: true, alertMinutes: 15, alertAtStart: false)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(ShellCommand.setSettings(settings).encode().utf8)) as? [String: Any])
        let calendar = try XCTUnwrap((sent["settings"] as? [String: Any])?["calendar"] as? [String: Any])
        XCTAssertEqual(calendar as NSDictionary,
                       ["enabled": true, "alert_minutes": 15, "alert_at_start": false] as NSDictionary)
    }

    // MARK: Text

    func testWhenAnEventStartsIsSaidInRoundedUpMinutes() {
        func at(_ secs: Int) -> String { Format.startsIn(startMs: t0 + secs * 1000, nowMs: t0) }
        XCTAssertEqual(at(0), "now")
        XCTAssertEqual(at(-600), "now")
        XCTAssertEqual(at(20), "in 1m")
        XCTAssertEqual(at(240), "in 4m")
        XCTAssertEqual(at(241), "in 5m")
        XCTAssertEqual(at(3600), "in 1h")
        XCTAssertEqual(at(8040), "in 2h 14m")
        XCTAssertEqual(at(27 * 3600), "in 1d 3h")
    }

    func testEventTimesNameTheDayOnlyWhenItIsNotToday() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        // 2026-11-12 12:00 UTC, a Thursday. (Hours of two digits: whether 9 is
        // written 09 follows the system's own setting.)
        let now = 1_794_477_600_000 + 2 * 3_600_000
        func time(startHours: Int, minutes: Int) -> String {
            let start = now + startHours * 3_600_000
            return Format.eventTime(startMs: start, endMs: start + minutes * 60_000, nowMs: now,
                                    calendar: utc, locale: locale)
        }
        XCTAssertEqual(time(startHours: 2, minutes: 30), "14:00 \u{2013} 14:30")
        XCTAssertEqual(time(startHours: -1, minutes: 90), "11:00 \u{2013} 12:30", "one that is running")
        XCTAssertEqual(time(startHours: 23, minutes: 60), "Tomorrow 11:00 \u{2013} 12:00")
        XCTAssertEqual(time(startHours: 47, minutes: 60), "Sat 11:00 \u{2013} 12:00")

        let event = CalendarEvent(id: "e", title: "Review", startMs: now + 2 * 3_600_000,
                                  endMs: now + 3 * 3_600_000, location: "Room 3")
        XCTAssertEqual(CalendarText.detail(event, nowMs: now, calendar: utc, locale: locale),
                       "14:00 \u{2013} 15:00 \u{b7} Room 3")
    }

    func testHomeShowsTheFirstEventThatHasNotEnded() {
        let view = CalendarView(events: [
            CalendarEvent(id: "a", title: "A", startMs: t0, endMs: t0 + 1000),
            CalendarEvent(id: "b", title: "B", startMs: t0 + 2000, endMs: t0 + 3000),
            CalendarEvent(id: "c", title: "C", startMs: t0 + 4000, endMs: t0 + 5000),
        ])
        XCTAssertEqual(view.current(nowMs: t0)?.id, "a")
        XCTAssertEqual(view.later(nowMs: t0), 2)
        // The view model is not re-sent every second; an ended event is skipped here.
        XCTAssertEqual(view.current(nowMs: t0 + 1000)?.id, "b")
        XCTAssertEqual(view.later(nowMs: t0 + 1000), 1)
        XCTAssertNil(view.current(nowMs: t0 + 5000))
        XCTAssertEqual(view.later(nowMs: t0 + 5000), 0)
    }

    // MARK: Observer

    private func drain() {
        // The observer hops to the main queue up to three times per change.
        for _ in 0..<4 {
            let done = expectation(description: "main queue")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    private func make(access: CalendarAccess, enabled: Bool) throws
        -> (AppModel, MockBridge, FakeCalendar, CalendarObserver) {
        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        let source = FakeCalendar(access: access)
        source.stored = [CalendarEventInput(id: "e1", title: "Stand-up", startMs: t0, endMs: t0 + 60_000)]
        let now = Date(timeIntervalSince1970: Double(t0) / 1000)
        let observer = CalendarObserver(model: model, source: source, now: { now }, debounce: 0)
        observer.start()
        try set(model, enabled: enabled)
        return (model, bridge, source, observer)
    }

    private func set(_ model: AppModel, enabled: Bool) throws {
        var vm = try fixture("idle")
        vm.settings.calendar.enabled = enabled
        model.apply(vm)
        drain()
    }

    private func eventLists(_ bridge: MockBridge) -> [[String]] {
        bridge.sentObjects.filter { $0["cmd"] as? String == "calendar_events" }.map {
            (($0["events"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
    }

    func testNothingIsAskedOrReadWhileTheCalendarIsOff() throws {
        let (model, bridge, source, observer) = try make(access: .unknown, enabled: false)
        defer { observer.stop() }
        source.onChange?()
        drain()
        XCTAssertEqual(source.asked, 0)
        XCTAssertTrue(source.reads.isEmpty)
        XCTAssertTrue(eventLists(bridge).isEmpty)
        XCTAssertEqual(model.calendarAccess, .unknown)
    }

    func testTurningItOnAsksOnceThenSendsTheNextTwoDays() throws {
        let (model, bridge, source, observer) = try make(access: .unknown, enabled: true)
        defer { observer.stop() }
        XCTAssertEqual(source.asked, 1)
        XCTAssertEqual(model.calendarAccess, .granted)
        XCTAssertEqual(eventLists(bridge), [["e1"]])
        let read = try XCTUnwrap(source.reads.first)
        XCTAssertEqual(read.1.timeIntervalSince(read.0), 48 * 3600)
        XCTAssertEqual(Int(read.0.timeIntervalSince1970 * 1000), t0)
    }

    func testARefusalIsReportedAndNothingIsSentOrAskedAgain() throws {
        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        let source = FakeCalendar(access: .unknown)
        source.grants = false
        let observer = CalendarObserver(model: model, source: source, now: Date.init, debounce: 0)
        observer.start()
        defer { observer.stop() }
        try set(model, enabled: true)
        XCTAssertEqual(model.calendarAccess, .denied)
        XCTAssertTrue(eventLists(bridge).isEmpty)

        try set(model, enabled: false)
        try set(model, enabled: true)
        XCTAssertEqual(source.asked, 1, "macOS shows its question only once")

        // Allowed later in System Settings: noticed when the panel opens.
        source.access = .granted
        source.stored = [CalendarEventInput(id: "e9", title: "Later", startMs: 1, endMs: 2)]
        model.panelOpened.send()
        drain()
        XCTAssertEqual(model.calendarAccess, .granted)
        XCTAssertEqual(eventLists(bridge), [["e9"]])
    }

    func testAChangedCalendarIsSentAgainAndAnUnchangedOneIsNot() throws {
        // The observer holds the model weakly, as the app delegate owns both.
        let (model, bridge, source, observer) = try make(access: .granted, enabled: true)
        defer { observer.stop(); _ = model }
        XCTAssertEqual(eventLists(bridge), [["e1"]])

        source.onChange?()
        drain()
        XCTAssertEqual(eventLists(bridge), [["e1"]], "same events: the core is left alone")
        XCTAssertEqual(source.reads.count, 2)

        source.stored.append(CalendarEventInput(id: "e2", title: "Review", startMs: t0, endMs: t0 + 1))
        source.onChange?()
        source.onChange?()
        source.onChange?()
        drain()
        XCTAssertEqual(eventLists(bridge), [["e1"], ["e1", "e2"]])
        XCTAssertEqual(source.reads.count, 3, "a burst of changes is one read")
    }

    func testTurningItOffAndOnSendsTheEventsAgain() throws {
        let (model, bridge, _, observer) = try make(access: .granted, enabled: true)
        defer { observer.stop() }
        try set(model, enabled: false)
        try set(model, enabled: true)
        XCTAssertEqual(eventLists(bridge), [["e1"], ["e1"]], "the core forgot them when it was turned off")
    }

    // MARK: Navigation

    func testACalendarNotificationOpensHomeAndSettingsHaveACalendarSection() throws {
        let model = AppModel(bridge: MockBridge())
        model.apply(try fixture("calendar"))
        let panel = model.primary
        panel.selectTab(.clipboard)
        let reminder = try XCTUnwrap(model.view?.inbox.history.first { $0.source == "calendar" })
        XCTAssertEqual(reminder.open, .tab(.home, pane: nil))
        panel.follow(reminder.open)
        XCTAssertEqual(panel.tab, .home)
        XCTAssertTrue(panel.expanded)

        panel.follow(.tab(.settings, pane: "calendar"))
        XCTAssertEqual(panel.settingsSection, .calendar)
        XCTAssertEqual(SettingsSection.calendar.title, "Calendar")
        XCTAssertEqual(Format.featureName("calendar_alert"), "Calendar reminders")
    }
}
