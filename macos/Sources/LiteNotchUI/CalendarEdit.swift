import Foundation

// Adding, changing and deleting events from the Calendar tab. EventKit is
// written by the shell (it is a Swift-only API, like the reads), and only
// from the user's own clicks in that tab: nothing in the core, the socket
// or a notification can reach these calls. The rules for what may be saved
// are plain values here so they can be tested without a calendar.

/// A calendar new events can go into (one that allows changes).
public struct CalendarChoice: Equatable, Identifiable {
    public var id: String
    public var title: String
    /// `#RRGGBB`.
    public var color: String?

    public init(id: String, title: String, color: String? = nil) {
        self.id = id
        self.title = title
        self.color = color
    }
}

/// What a save or delete came to.
public enum CalendarWriteResult: Equatable {
    /// Done; for a saved event, where it now starts.
    case done(startMs: Int?)
    /// Not done; the sentence says why.
    case failed(String)
}

/// The fields of the Calendar tab's form, for a new event or one being changed.
public struct EventDraft: Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String
    /// Where a new event goes; ignored when changing one.
    public var calendarId: String?
    /// The event being changed, as it was when the form opened; nil for a new one.
    public let original: Original?

    public struct Original: Equatable {
        public var id: String
        public var startMs: Int
        public var title: String
        public var start: Date
        public var end: Date
        public var location: String
    }

    public static let maxTitle = 200
    public static let maxLocation = 200
    /// Longer events are for Calendar itself.
    public static let maxLength: TimeInterval = 14 * 24 * 3600
    /// A new event lasts this long unless changed.
    public static let defaultLength: TimeInterval = 30 * 60

    public var isNew: Bool { original == nil }

    /// A new event at the next half hour, half an hour long.
    public static func new(now: Date, calendarId: String?, calendar: Calendar = .current) -> EventDraft {
        let start = nextHalfHour(after: now, calendar: calendar)
        return EventDraft(
            title: "", start: start, end: start.addingTimeInterval(defaultLength), location: "",
            calendarId: calendarId, original: nil)
    }

    /// The form for changing `d`, filled with what it holds now.
    public static func editing(_ d: EventDetail) -> EventDraft {
        let start = Date(ms: d.startMs)
        let end = Date(ms: d.endMs)
        return EventDraft(
            title: d.title, start: start, end: end, location: d.location, calendarId: nil,
            original: Original(
                id: d.id, startMs: d.startMs, title: d.title, start: start, end: end, location: d.location))
    }

    static func nextHalfHour(after now: Date, calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let minute = c.minute ?? 0
        c.minute = minute < 30 ? 30 : 0
        c.second = 0
        let base = calendar.date(from: c) ?? now
        return minute < 30 ? base : calendar.date(byAdding: .hour, value: 1, to: base) ?? base
    }

    /// Moves the start and keeps the length, as Calendar does.
    public mutating func moveStart(to new: Date) {
        let length = end.timeIntervalSince(start)
        start = new
        end = new.addingTimeInterval(max(length, 60))
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedLocation: String { location.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why it cannot be saved, or nil when it can.
    public var problem: String? {
        if trimmedTitle.isEmpty { return "Add a title" }
        if trimmedTitle.count > Self.maxTitle { return "The title is too long" }
        if trimmedLocation.count > Self.maxLocation { return "The location is too long" }
        if end <= start { return "It ends before it starts" }
        if end.timeIntervalSince(start) > Self.maxLength { return "Events here can last up to 14 days" }
        if isNew && calendarId == nil { return "No calendar to add it to" }
        return nil
    }

    /// What a save writes. For a change, only the fields the user changed:
    /// the form shows the core's cleaned-up text, and writing that back
    /// unchanged would shorten a long title or lose characters.
    public var changes: Changes {
        guard let o = original else {
            return Changes(title: trimmedTitle, start: start, end: end, location: trimmedLocation)
        }
        return Changes(
            title: trimmedTitle != o.title ? trimmedTitle : nil,
            start: start != o.start ? start : nil,
            end: end != o.end ? end : nil,
            location: trimmedLocation != o.location ? trimmedLocation : nil)
    }

    /// Something differs from the event as it was.
    public var isChanged: Bool { !changes.isEmpty }

    public struct Changes: Equatable {
        public var title: String?
        public var start: Date?
        public var end: Date?
        public var location: String?
        public var isEmpty: Bool { title == nil && start == nil && end == nil && location == nil }
    }
}

extension Date {
    init(ms: Int) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
    var ms: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}

/// What the Calendar tab asks of the calendar. `CalendarObserver` does it
/// with EventKit; tests and snapshots have none or a fake. Main thread;
/// `done` is called on the main thread.
public protocol CalendarEditing: AnyObject {
    /// Reads one occurrence in full and hands it to the core to show.
    func open(id: String, startMs: Int)
    /// The tab went back to its list.
    func close()
    /// The calendars a new event can go into, and the default one's id.
    func calendars(_ done: @escaping ([CalendarChoice], String?) -> Void)
    func save(_ draft: EventDraft, _ done: @escaping (CalendarWriteResult) -> Void)
    /// Deletes one occurrence (of a repeating event, only that one).
    func delete(id: String, startMs: Int, _ done: @escaping (CalendarWriteResult) -> Void)
    /// Shows the event's day in Calendar, for what cannot be done here.
    func showInCalendar(startMs: Int)
}
