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

    var details: [String: EventDetailInput] = [:]
    var choices: [CalendarChoice] = [CalendarChoice(id: "work", title: "Work", color: "#1BADF8")]
    var saved: [EventDraft] = []
    var deleted: [String] = []
    var writeResult = CalendarWriteResult.done(startMs: nil)

    func detail(id: String, startMs: Int, _ done: @escaping (EventDetailInput?) -> Void) {
        done(details["\(startMs)-\(id)"])
    }

    func writableCalendars(_ done: @escaping ([CalendarChoice], String?) -> Void) {
        done(choices, choices.first?.id)
    }

    func save(_ draft: EventDraft, _ done: @escaping (CalendarWriteResult) -> Void) {
        saved.append(draft)
        done(writeResult)
    }

    func delete(id: String, startMs: Int, _ done: @escaping (CalendarWriteResult) -> Void) {
        deleted.append("\(startMs)-\(id)")
        done(writeResult)
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
            CalendarEventInput(
                id: "e1", title: "Stand-up", startMs: 10, endMs: 20, calendar: "Work",
                color: "#FF3B30", location: "Room 3"),
            CalendarEventInput(id: "e2", title: "Lunch", startMs: 30, endMs: 40),
        ])
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.encode().utf8)) as? [String: Any])
        XCTAssertEqual(sent["cmd"] as? String, "calendar_events")
        let events = try XCTUnwrap(sent["events"] as? [[String: Any]])
        XCTAssertEqual(
            events[0] as NSDictionary,
            [
                "id": "e1", "title": "Stand-up", "start_ms": 10, "end_ms": 20, "all_day": false,
                "calendar": "Work", "color": "#FF3B30", "location": "Room 3",
            ] as NSDictionary)
        XCTAssertTrue(events[1]["color"] is NSNull)
    }

    func testCalendarSettingsRoundTripInSnakeCase() throws {
        var settings = try fixture("idle").settings
        settings.calendar = CalendarConfig(enabled: true, alertMinutes: 15, alertAtStart: false)
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(ShellCommand.setSettings(settings).encode().utf8)) as? [String: Any])
        let calendar = try XCTUnwrap((sent["settings"] as? [String: Any])?["calendar"] as? [String: Any])
        XCTAssertEqual(
            calendar as NSDictionary,
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
            return Format.eventTime(
                startMs: start, endMs: start + minutes * 60_000, nowMs: now,
                calendar: utc, locale: locale)
        }
        XCTAssertEqual(time(startHours: 2, minutes: 30), "14:00 \u{2013} 14:30")
        XCTAssertEqual(time(startHours: -1, minutes: 90), "11:00 \u{2013} 12:30", "one that is running")
        XCTAssertEqual(time(startHours: 23, minutes: 60), "Tomorrow 11:00 \u{2013} 12:00")
        XCTAssertEqual(time(startHours: 47, minutes: 60), "Sat 11:00 \u{2013} 12:00")

        let event = CalendarEvent(
            id: "e", title: "Review", startMs: now + 2 * 3_600_000,
            endMs: now + 3 * 3_600_000, location: "Room 3")
        XCTAssertEqual(
            CalendarText.detail(event, nowMs: now, calendar: utc, locale: locale),
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
        -> (AppModel, MockBridge, FakeCalendar, CalendarObserver)
    {
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
        defer {
            observer.stop()
            _ = model
        }
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

    func testACalendarNotificationOpensItsEventAndSettingsHaveACalendarSection() throws {
        let model = AppModel(bridge: MockBridge())
        model.apply(try fixture("calendar"))
        let panel = model.primary
        panel.selectTab(.clipboard)
        let reminder = try XCTUnwrap(model.view?.inbox.history.first { $0.source == "calendar" })
        let first = try XCTUnwrap(model.view?.calendar.events.first)
        XCTAssertEqual(reminder.open, .tab(.calendar, pane: first.key))
        panel.follow(reminder.open)
        XCTAssertEqual(panel.tab, .calendar)
        XCTAssertEqual(panel.calendarPage, .event(first.key))
        XCTAssertTrue(panel.expanded)
        panel.follow(.tab(.calendar, pane: nil))
        XCTAssertEqual(panel.calendarPage, .list)

        panel.follow(.tab(.settings, pane: "calendar"))
        XCTAssertEqual(panel.settingsSection, .calendar)
        XCTAssertEqual(SettingsSection.calendar.title, "Calendar")
        XCTAssertEqual(Format.featureName("calendar_alert"), "Calendar reminders")
    }

    // MARK: The Calendar tab

    func testTheDetailFixtureDecodes() throws {
        let vm = try fixture("calendar-detail")
        let d = try XCTUnwrap(vm.calendar.detail)
        XCTAssertEqual(d.key, vm.calendar.events[0].key)
        XCTAssertEqual(d.attendees.map(\.status), [.accepted, .accepted, .tentative, .pending])
        XCTAssertTrue(d.attendees[1].me)
        XCTAssertTrue(d.canEdit && d.recurring)
        XCTAssertTrue(d.notes.contains("\n"))
    }

    func testTheCalendarTabIsInTheBarOnlyWhileTheCalendarIsOn() {
        XCTAssertEqual(TabBar.right(calendar: false), [.inbox, .settings])
        XCTAssertEqual(TabBar.right(calendar: true), [.calendar, .inbox, .settings])
        XCTAssertFalse(TabBar.left.contains(.calendar), "no room for a sixth icon left of a hardware notch")
    }

    func testOpeningAnEventSendsItsDetailBoundedAndClosingSaysSo() throws {
        let (model, bridge, source, observer) = try make(access: .granted, enabled: true)
        defer {
            observer.stop()
            _ = model
        }
        source.details["\(t0)-e1"] = EventDetailInput(
            id: "e1", title: "Stand-up", startMs: t0, endMs: t0 + 60_000,
            notes: String(repeating: "n", count: 20_000),
            attendees: Array(repeating: (name: "P", status: .accepted, me: false), count: 500),
            canEdit: true)
        observer.open(id: "e1", startMs: t0)
        observer.open(id: "gone", startMs: t0)
        drain()
        let sent = bridge.sentObjects.filter { $0["cmd"] as? String == "calendar_detail" }
        XCTAssertEqual(sent.count, 1, "an event that is gone sends nothing")
        let detail = try XCTUnwrap(sent.first?["detail"] as? [String: Any])
        XCTAssertEqual((detail["notes"] as? String)?.count, EventDetailInput.maxNotes)
        XCTAssertEqual((detail["attendees"] as? [Any])?.count, EventDetailInput.maxAttendees)
        XCTAssertEqual(detail["can_edit"] as? Bool, true)
        XCTAssertEqual((detail["attendees"] as? [[String: Any]])?.first?["status"] as? String, "accepted")

        observer.close()
        XCTAssertEqual(bridge.sentObjects.last?["cmd"] as? String, "calendar_detail_close")
    }

    func testNothingIsReadOrWrittenWhileTheCalendarIsOffOrNotAllowed() throws {
        for (access, enabled) in [(CalendarAccess.granted, false), (.denied, true)] {
            let (model, bridge, source, observer) = try make(access: access, enabled: enabled)
            defer { _ = model }
            source.details["\(t0)-e1"] = EventDetailInput(id: "e1", title: "S", startMs: t0, endMs: t0 + 1)
            observer.open(id: "e1", startMs: t0)
            var results: [CalendarWriteResult] = []
            observer.save(.new(now: Date(), calendarId: "work")) { results.append($0) }
            observer.delete(id: "e1", startMs: t0) { results.append($0) }
            var listed: [CalendarChoice]?
            observer.calendars { list, _ in listed = list }
            drain()
            observer.stop()
            XCTAssertFalse(bridge.sentObjects.contains { $0["cmd"] as? String == "calendar_detail" })
            XCTAssertTrue(source.saved.isEmpty && source.deleted.isEmpty)
            XCTAssertEqual(results.count, 2)
            XCTAssertTrue(results.allSatisfy { if case .failed = $0 { true } else { false } })
            XCTAssertEqual(listed, [])
        }
    }

    func testSavingAndDeletingGoThroughTheSourceAndReadTheListAgain() throws {
        let (model, bridge, source, observer) = try make(access: .granted, enabled: true)
        defer { observer.stop() }
        XCTAssertTrue(model.calendarEditor === observer)
        let reads = source.reads.count
        var draft = EventDraft.new(now: Date(ms: t0), calendarId: "work")
        draft.title = "Focus block"
        var results: [CalendarWriteResult] = []
        observer.save(draft) { results.append($0) }
        drain()
        observer.delete(id: "e1", startMs: t0) { results.append($0) }
        drain()
        XCTAssertEqual(source.saved.map(\.title), ["Focus block"])
        XCTAssertEqual(source.deleted, ["\(t0)-e1"])
        XCTAssertEqual(results, [.done(startMs: nil), .done(startMs: nil)])
        XCTAssertEqual(source.reads.count, reads + 2, "each write reads the list at once")
        _ = bridge

        source.writeResult = .failed("nope")
        observer.save(draft) { results.append($0) }
        drain()
        XCTAssertEqual(results.last, .failed("nope"))
        XCTAssertEqual(source.reads.count, reads + 2, "a failed write changes nothing to read")
        var listed: ([CalendarChoice], String?)?
        observer.calendars { listed = ($0, $1) }
        drain()
        XCTAssertEqual(listed?.0.map(\.id), ["work"])
        XCTAssertEqual(listed?.1, "work")
        observer.stop()
        XCTAssertNil(model.calendarEditor)
    }

    // MARK: Drafts

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testANewEventStartsAtTheNextHalfHourAndLastsHalfAnHour() {
        // 2026-11-12 14:00 UTC.
        let base = 1_794_477_600_000 + 4 * 3_600_000
        let at = { (mins: Int) in EventDraft.new(now: Date(ms: base + mins * 60_000), calendarId: "c", calendar: self.utc) }
        XCTAssertEqual(at(0).start.ms, base + 30 * 60_000)
        XCTAssertEqual(at(10).start.ms, base + 30 * 60_000)
        XCTAssertEqual(at(30).start.ms, base + 60 * 60_000)
        XCTAssertEqual(at(59).start.ms, base + 60 * 60_000)
        XCTAssertEqual(at(10).end.timeIntervalSince(at(10).start), 30 * 60)
        XCTAssertTrue(at(0).isNew)
    }

    func testADraftSaysWhyItCannotBeSaved() {
        var d = EventDraft.new(now: Date(ms: t0), calendarId: "c")
        XCTAssertEqual(d.problem, "Add a title")
        d.title = "   "
        XCTAssertEqual(d.problem, "Add a title")
        d.title = "Plan"
        XCTAssertNil(d.problem)
        d.title = String(repeating: "x", count: EventDraft.maxTitle + 1)
        XCTAssertEqual(d.problem, "The title is too long")
        d.title = "Plan"
        d.location = String(repeating: "x", count: EventDraft.maxLocation + 1)
        XCTAssertEqual(d.problem, "The location is too long")
        d.location = ""
        d.end = d.start
        XCTAssertEqual(d.problem, "It ends before it starts")
        d.end = d.start.addingTimeInterval(EventDraft.maxLength + 60)
        XCTAssertEqual(d.problem, "Events here can last up to 14 days")
        d.end = d.start.addingTimeInterval(3600)
        d.calendarId = nil
        XCTAssertEqual(d.problem, "No calendar to add it to")
    }

    func testMovingTheStartKeepsTheLength() {
        var d = EventDraft.new(now: Date(ms: t0), calendarId: "c")
        d.end = d.start.addingTimeInterval(45 * 60)
        d.moveStart(to: d.start.addingTimeInterval(3600))
        XCTAssertEqual(d.end.timeIntervalSince(d.start), 45 * 60)
    }

    func testAChangeWritesOnlyTheFieldsTheUserChanged() throws {
        let detail = try XCTUnwrap(try fixture("calendar-detail").calendar.detail)
        var d = EventDraft.editing(detail)
        XCTAssertFalse(d.isNew)
        XCTAssertNil(d.calendarId)
        XCTAssertFalse(d.isChanged, "an untouched form writes nothing, so a shortened title is not saved")
        XCTAssertTrue(d.changes.isEmpty)
        d.title = "  \(detail.title)  "
        XCTAssertFalse(d.isChanged, "spaces around it are not a change")
        d.location = "Room 4"
        XCTAssertEqual(d.changes, EventDraft.Changes(title: nil, start: nil, end: nil, location: "Room 4"))
        d.moveStart(to: d.start.addingTimeInterval(900))
        XCTAssertNotNil(d.changes.start)
        XCTAssertNotNil(d.changes.end)
        XCTAssertNil(d.problem)
    }

    func testEventDetailIsSentInTheShapeTheCoreReads() throws {
        let command = ShellCommand.calendarDetail(
            EventDetailInput(
                id: "e1", title: "T", startMs: 10, endMs: 20, calendar: "Work", color: nil, location: "L",
                notes: "a\nb", url: "https://x.example", organizer: "O",
                attendees: [(name: "A", status: .tentative, me: true)], recurring: true, canEdit: false))
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.encode().utf8)) as? [String: Any])
        XCTAssertEqual(sent["cmd"] as? String, "calendar_detail")
        let d = try XCTUnwrap(sent["detail"] as? [String: Any])
        XCTAssertEqual(
            Set(d.keys),
            [
                "id", "title", "start_ms", "end_ms", "calendar", "color", "location", "notes", "url", "organizer",
                "attendees", "recurring", "can_edit",
            ])
        XCTAssertTrue(d["color"] is NSNull)
        XCTAssertEqual(
            (d["attendees"] as? [[String: Any]])?.first as NSDictionary?,
            ["name": "A", "status": "tentative", "me": true] as NSDictionary)
        XCTAssertEqual(ShellCommand.calendarDetailClose.encode(), #"{"cmd":"calendar_detail_close"}"#)
    }

    // MARK: Text for the tab

    func testTheListGroupsByDayAndARunningEventCountsAsToday() {
        let locale = Locale(identifier: "en_GB")
        // 2026-11-12 12:00 UTC, a Thursday.
        let now = 1_794_477_600_000 + 2 * 3_600_000
        let h = 3_600_000
        let events = [
            CalendarEvent(id: "a", title: "Overnight", startMs: now - 14 * h, endMs: now + h),
            CalendarEvent(id: "b", title: "Lunch", startMs: now + h, endMs: now + 2 * h),
            CalendarEvent(id: "c", title: "Early", startMs: now + 20 * h, endMs: now + 21 * h),
            CalendarEvent(id: "d", title: "Sat", startMs: now + 46 * h, endMs: now + 47 * h),
        ]
        let days = CalendarText.days(events, nowMs: now, calendar: utc, locale: locale)
        XCTAssertEqual(days.map(\.title), ["Today", "Tomorrow", "Saturday 14 Nov"])
        XCTAssertEqual(days.map { $0.events.map(\.id) }, [["a", "b"], ["c"], ["d"]])
    }

    func testTimesAndLengthsReadNaturally() {
        let locale = Locale(identifier: "en_GB")
        let noon = 1_794_477_600_000 + 2 * 3_600_000
        let h = 3_600_000
        XCTAssertEqual(
            CalendarText.timeRange(startMs: noon, endMs: noon + h / 2, calendar: utc, locale: locale),
            "12:00 \u{2013} 12:30")
        XCTAssertFalse(
            CalendarText.timeRange(startMs: noon, endMs: noon + 12 * h, calendar: utc, locale: locale).contains("Fri"),
            "ending at midnight is still the same evening")
        XCTAssertEqual(
            CalendarText.timeRange(startMs: noon, endMs: noon + 22 * h, calendar: utc, locale: locale),
            "12:00 \u{2013} Fri 10:00")
        XCTAssertEqual(CalendarText.length(startMs: 0, endMs: 30 * 60_000), "30 min")
        XCTAssertEqual(CalendarText.length(startMs: 0, endMs: h), "1 h")
        XCTAssertEqual(CalendarText.length(startMs: 0, endMs: h + 15 * 60_000), "1 h 15 min")
        XCTAssertEqual(CalendarText.length(startMs: 0, endMs: 51 * h), "2 d 3 h")
        XCTAssertEqual(
            CalendarText.when(startMs: noon + h, endMs: noon + 2 * h, nowMs: noon, calendar: utc, locale: locale),
            "Today, 13:00 \u{2013} 14:00 \u{b7} 1 h")
        XCTAssertEqual(
            CalendarText.place(CalendarEvent(id: "", title: "", startMs: 0, endMs: 1, calendar: "Work", location: "Room 3")),
            "Room 3 \u{b7} Work")
    }

    func testGuestsSayWhoIsTheUserAndWhoOrganizes() {
        let sam = Attendee(name: "Sam", status: .accepted, me: false)
        let me = Attendee(name: "Jo", status: .accepted, me: true)
        XCTAssertEqual(CalendarText.guestName(sam, organizer: "Sam"), "Sam (organizer)")
        XCTAssertEqual(CalendarText.guestName(sam, organizer: ""), "Sam")
        XCTAssertEqual(CalendarText.guestName(me, organizer: "Jo"), "Jo (you)")
    }

    func testAChangeIsConfirmedOnTheListForAFewSeconds() {
        let panel = AppModel(bridge: MockBridge()).primary
        panel.showCalendarNotice("Added", for: 0.05)
        XCTAssertEqual(panel.calendarNotice, "Added")
        panel.showCalendarNotice("Deleted", for: 0.2)
        let gone = expectation(description: "cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(panel.calendarNotice, "Deleted", "a newer notice is not cut short by the older timer")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertNil(panel.calendarNotice)
                gone.fulfill()
            }
        }
        wait(for: [gone], timeout: 2)
    }

    /// From review: a form left open came back on a later hover with its
    /// title field ready to take the keyboard, so typing meant for another
    /// app could end up in an event, and Return would save it.
    func testAFormLeftOpenIsDroppedWhenThePanelClosesAndHoverNeverTakesTheKeyboard() throws {
        let model = AppModel(bridge: MockBridge())
        model.apply(try fixture("calendar-detail"))
        let p = model.primary
        let key = try XCTUnwrap(model.view?.calendar.detail?.key)
        p.selectTab(.calendar)
        p.open()
        p.requestKeyboard(true)
        p.calendarPage = .new
        p.close()
        XCTAssertEqual(p.calendarPage, .list)
        XCTAssertFalse(p.keyboardRequested)
        p.calendarPage = .edit(key)
        p.open()
        p.close()
        XCTAssertEqual(p.calendarPage, .event(key), "an edit goes back to its event, unsaved")
        p.hoverChanged(true)
        XCTAssertFalse(p.keyboardRequested)
    }

    func testCalendarNamesAreCleanedAndTwinsSayTheirAccount() {
        let list = EventKitSource.choices([
            (id: "a", title: "Home", account: "iCloud", color: nil),
            (id: "b", title: "Ho\u{202E}me\n", account: "Google", color: nil),
            (id: "c", title: "Home", account: "Shared by Pat", color: nil),
            (id: "d", title: "Work", account: "iCloud", color: nil),
        ])
        XCTAssertEqual(
            list.map(\.title), ["Home \u{b7} iCloud", "Home \u{b7} Shared by Pat", "Ho\u{FFFD}me", "Work"])
    }
}
