import AppKit
import Combine
import EventKit
import Foundation

// The user's calendars, through EventKit: whatever accounts the Calendar app
// shows (iCloud, Google, Exchange, …). Event-driven: the events are read
// again when the calendar database says it changed, on a new day and after
// waking, never on a timer. The core decides when to alert. Events are
// written only from the Calendar tab, on the user's click (`CalendarEditing`).

/// Whether LiteNotch may read the calendars.
public enum CalendarAccess: Equatable {
    /// Not asked yet.
    case unknown
    case granted
    /// Refused, restricted, or allowed to add events only.
    case denied
}

/// One event as `calendar_events` takes it.
public struct CalendarEventInput: Equatable {
    public var id: String
    public var title: String
    public var startMs: Int
    public var endMs: Int
    public var allDay: Bool
    public var calendar: String
    /// `#RRGGBB`.
    public var color: String?
    public var location: String

    public init(
        id: String, title: String, startMs: Int, endMs: Int, allDay: Bool = false,
        calendar: String = "", color: String? = nil, location: String = ""
    ) {
        self.id = id
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
        self.allDay = allDay
        self.calendar = calendar
        self.color = color
        self.location = location
    }

    var object: [String: Any] {
        [
            "id": id, "title": title, "start_ms": startMs, "end_ms": endMs, "all_day": allDay,
            "calendar": calendar, "color": color.map { $0 as Any } ?? NSNull(), "location": location,
        ]
    }
}

/// One event in full as `calendar_detail` takes it. Bounded here so the
/// command stays small; the core sanitizes and caps it again.
public struct EventDetailInput: Equatable {
    public var id: String
    public var title: String
    public var startMs: Int
    public var endMs: Int
    public var calendar: String = ""
    public var color: String? = nil
    public var location: String = ""
    public var notes: String = ""
    public var url: String = ""
    public var organizer: String = ""
    public var attendees: [(name: String, status: AttendeeStatus, me: Bool)] = []
    public var recurring = false
    public var canEdit = false

    /// Far more than the core keeps (2000 characters, 30 people); only a bound.
    static let maxNotes = 8000
    static let maxAttendees = 200

    public static func == (a: Self, b: Self) -> Bool {
        a.object as NSDictionary == b.object as NSDictionary
    }

    var object: [String: Any] {
        [
            "id": id, "title": title, "start_ms": startMs, "end_ms": endMs, "calendar": calendar,
            "color": color.map { $0 as Any } ?? NSNull(), "location": location,
            "notes": String(notes.prefix(Self.maxNotes)), "url": url, "organizer": organizer,
            "attendees": attendees.prefix(Self.maxAttendees).map {
                ["name": $0.name, "status": $0.status.rawValue, "me": $0.me] as [String: Any]
            },
            "recurring": recurring, "can_edit": canEdit,
        ]
    }
}

/// What the observer needs from the calendar store; tests use a fake.
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    /// Asks the user. `done` may be called on any thread.
    func requestAccess(_ done: @escaping (Bool) -> Void)
    /// Timed events overlapping the range. `done` may be called on any thread.
    func events(from: Date, to: Date, _ done: @escaping ([CalendarEventInput]) -> Void)
    /// Called (on any thread) when the calendars changed.
    var onChange: (() -> Void)? { get set }
    /// One occurrence in full; nil when it is gone. `done` on any thread.
    func detail(id: String, startMs: Int, _ done: @escaping (EventDetailInput?) -> Void)
    /// Calendars that take new events, and the default one's id.
    func writableCalendars(_ done: @escaping ([CalendarChoice], String?) -> Void)
    func save(_ draft: EventDraft, _ done: @escaping (CalendarWriteResult) -> Void)
    func delete(id: String, startMs: Int, _ done: @escaping (CalendarWriteResult) -> Void)
}

/// Said when the occurrence asked for is no longer there.
let eventGone = "This event changed in Calendar. Open it again from the list."
/// Said when the event may not be changed here.
let eventLocked = "This event can only be changed in Calendar."

final class EventKitSource: CalendarSource {
    private var store = EKEventStore()
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "dev.litenotch.calendar", qos: .utility)
    var onChange: (() -> Void)?

    init() { observe() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: nil
        ) { [weak self] _ in self?.onChange?() }
    }

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { [weak self] ok, _ in
            // A store made before access was granted may stay empty.
            if ok, let self {
                self.queue.sync {
                    self.store = EKEventStore()
                    self.observe()
                }
            }
            done(ok)
        }
    }

    func events(from: Date, to: Date, _ done: @escaping ([CalendarEventInput]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let predicate = self.store.predicateForEvents(withStart: from, end: to, calendars: nil)
            done(self.store.events(matching: predicate).compactMap(Self.input))
        }
    }

    /// The one occurrence of `id` that starts at `startMs`. A repeating
    /// event's occurrences share an id, so the start tells them apart. On `queue`.
    private func occurrence(id: String, startMs: Int) -> EKEvent? {
        let start = Date(ms: startMs)
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1), calendars: nil)
        let matches = store.events(matching: predicate).filter {
            $0.eventIdentifier == id && $0.startDate.map { $0.ms == startMs } == true
        }
        // Two occurrences moved onto the same start cannot be told apart:
        // change neither rather than perhaps the wrong one.
        return matches.count == 1 ? matches[0] : nil
    }

    /// A calendar that allows changes, and no guests. Changing someone
    /// else's invitation would change only the user's copy; changing or
    /// deleting one's own meeting makes the calendar server write to every
    /// guest, which deserves Calendar's own questions. Both go to Calendar.
    static func canEdit(_ e: EKEvent) -> Bool {
        guard e.calendar?.allowsContentModifications == true else { return false }
        return (e.attendees ?? []).isEmpty
    }

    static func status(_ s: EKParticipantStatus) -> AttendeeStatus {
        switch s {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .pending: return .pending
        default: return .unknown
        }
    }

    /// A person's name, or their address when the invitation has none.
    static func name(_ p: EKParticipant) -> String {
        if let n = p.name, !n.isEmpty { return n }
        let address = p.url.absoluteString
        return address.hasPrefix("mailto:") ? String(address.dropFirst(7)) : address
    }

    func detail(id: String, startMs: Int, _ done: @escaping (EventDetailInput?) -> Void) {
        queue.async { [weak self] in
            guard let self, let e = self.occurrence(id: id, startMs: startMs), let end = e.endDate else {
                return done(nil)
            }
            done(
                EventDetailInput(
                    id: id, title: e.title ?? "", startMs: startMs, endMs: end.ms,
                    calendar: e.calendar?.title ?? "",
                    color: e.calendar.flatMap { ColorMath.hex(of: $0.color) },
                    location: e.location ?? "", notes: e.notes ?? "",
                    url: e.url?.absoluteString ?? "",
                    organizer: e.organizer.map(Self.name) ?? "",
                    attendees: (e.attendees ?? []).map {
                        (name: Self.name($0), status: Self.status($0.participantStatus), me: $0.isCurrentUser)
                    },
                    recurring: e.hasRecurrenceRules, canEdit: Self.canEdit(e)))
        }
    }

    func writableCalendars(_ done: @escaping ([CalendarChoice], String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let calendars = self.store.calendars(for: .event).filter(\.allowsContentModifications)
            let list = Self.choices(
                calendars.map {
                    (
                        id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "",
                        color: ColorMath.hex(of: $0.color)
                    )
                })
            let fallback = self.store.defaultCalendarForNewEvents?.calendarIdentifier
            done(list, list.contains { $0.id == fallback } ? fallback : list.first?.id)
        }
    }

    /// A shared calendar's name is chosen by someone else, so it is cleaned
    /// like invitation text, and the account is added where two names are
    /// the same, so one cannot pass for the other.
    static func choices(_ raw: [(id: String, title: String, account: String, color: String?)]) -> [CalendarChoice] {
        func clean(_ s: String) -> String {
            // Invisible and direction marks first (shown as U+FFFD, as in
            // invitation text), then other control characters as spaces.
            let marked = ApprovalPresentation.visible(s)
            let line = String(
                String.UnicodeScalarView(
                    marked.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return String(words.prefix(60))
        }
        let titles = raw.map { clean($0.title) }
        return zip(raw, titles).map { r, title in
            let twice = titles.filter { $0 == title }.count > 1
            let account = clean(r.account)
            return CalendarChoice(
                id: r.id, title: twice && !account.isEmpty ? "\(title) \u{b7} \(account)" : title, color: r.color)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func save(_ draft: EventDraft, _ done: @escaping (CalendarWriteResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if let problem = draft.problem { return done(.failed(problem)) }
            let event: EKEvent
            if let o = draft.original {
                guard let found = self.occurrence(id: o.id, startMs: o.startMs) else {
                    return done(.failed(eventGone))
                }
                guard Self.canEdit(found) else { return done(.failed(eventLocked)) }
                event = found
            } else {
                guard let id = draft.calendarId, let calendar = self.store.calendar(withIdentifier: id),
                    calendar.allowsContentModifications
                else { return done(.failed("That calendar does not take new events.")) }
                event = EKEvent(eventStore: self.store)
                event.calendar = calendar
            }
            let c = draft.changes
            if let t = c.title { event.title = t }
            if let s = c.start { event.startDate = s }
            if let e = c.end { event.endDate = e }
            if let l = c.location { event.location = l.isEmpty ? nil : l }
            do {
                // One occurrence only: a repeating event's others stay as they are.
                try self.store.save(event, span: .thisEvent, commit: true)
                done(.done(startMs: event.startDate?.ms))
            } catch {
                self.store.reset()
                done(.failed("Calendar did not save it: \(error.localizedDescription)"))
            }
        }
    }

    func delete(id: String, startMs: Int, _ done: @escaping (CalendarWriteResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let e = self.occurrence(id: id, startMs: startMs) else { return done(.failed(eventGone)) }
            guard Self.canEdit(e) else { return done(.failed(eventLocked)) }
            do {
                try self.store.remove(e, span: .thisEvent, commit: true)
                done(.done(startMs: nil))
            } catch {
                self.store.reset()
                done(.failed("Calendar did not delete it: \(error.localizedDescription)"))
            }
        }
    }

    /// Nil for what is not worth a reminder: all-day entries, cancelled
    /// events and invitations the user declined.
    static func input(_ e: EKEvent) -> CalendarEventInput? {
        guard !e.isAllDay, e.status != .canceled, let start = e.startDate, let end = e.endDate,
            let id = e.eventIdentifier
        else { return nil }
        if let me = e.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined {
            return nil
        }
        return CalendarEventInput(
            id: id, title: e.title ?? "",
            // The same conversion as `occurrence` compares against.
            startMs: start.ms,
            endMs: end.ms,
            calendar: e.calendar?.title ?? "",
            color: e.calendar.flatMap { ColorMath.hex(of: $0.color) },
            location: e.location ?? "")
    }
}

/// Follows `settings.calendar.enabled`: asks for access once, then keeps the
/// core's list of upcoming events current. Also does what the Calendar tab
/// asks (`CalendarEditing`).
public final class CalendarObserver: CalendarEditing {
    /// How far ahead events are read. Two days, re-read every midnight, so
    /// at least a full day is always covered.
    static let horizon: TimeInterval = 48 * 3600
    /// Changes arrive in bursts (a sync touches many events).
    static let settle: TimeInterval = 1

    private weak var model: AppModel?
    private let source: CalendarSource
    private let now: () -> Date
    private let debounce: TimeInterval

    private var cancellables: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var wanted = false
    private var asked = false
    private var pending: DispatchWorkItem?
    /// What the core was last given, so an unchanged calendar sends nothing.
    private var sent: [CalendarEventInput]?

    public convenience init(model: AppModel) {
        self.init(model: model, source: EventKitSource(), now: Date.init, debounce: Self.settle)
    }

    init(model: AppModel, source: CalendarSource, now: @escaping () -> Date, debounce: TimeInterval) {
        self.model = model
        self.source = source
        self.now = now
        self.debounce = debounce
    }

    deinit { stop() }

    /// Starts following the setting. Main thread.
    public func start() {
        guard cancellables.isEmpty, let model else { return }
        model.calendarEditor = self
        source.onChange = { [weak self] in DispatchQueue.main.async { self?.changed() } }
        model.$view
            .map { $0?.settings.calendar.enabled ?? false }
            .removeDuplicates()
            .sink { [weak self] on in self?.settingChanged(on) }
            .store(in: &cancellables)
        // Access may have been given in System Settings meanwhile.
        model.panelOpened
            .sink { [weak self] _ in self?.accessMayHaveChanged() }
            .store(in: &cancellables)
        let day = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.changed() }
        observers.append((NotificationCenter.default, day))
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.changed() }
        observers.append((workspace, wake))
    }

    public func stop() {
        cancellables.removeAll()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        pending?.cancel()
        pending = nil
        source.onChange = nil
        if model?.calendarEditor === self { model?.calendarEditor = nil }
    }

    // MARK: The Calendar tab

    /// The calendar may be read and written: the setting is on and access given.
    private var ready: Bool { wanted && source.access == .granted }

    public func open(id: String, startMs: Int) {
        guard ready else { return }
        source.detail(id: id, startMs: startMs) { [weak self] detail in
            DispatchQueue.main.async {
                guard let self, self.ready, let detail else { return }
                self.model?.send(.calendarDetail(detail))
            }
        }
    }

    public func close() {
        model?.send(.calendarDetailClose)
    }

    public func calendars(_ done: @escaping ([CalendarChoice], String?) -> Void) {
        guard ready else { return done([], nil) }
        source.writableCalendars { list, fallback in DispatchQueue.main.async { done(list, fallback) } }
    }

    public func save(_ draft: EventDraft, _ done: @escaping (CalendarWriteResult) -> Void) {
        guard ready else { return done(.failed("Calendar access is off.")) }
        source.save(draft) { [weak self] result in
            DispatchQueue.main.async {
                // Read the list at once rather than after the change settles,
                // so the tab does not show the old times meanwhile.
                if case .done = result { self?.load() }
                done(result)
            }
        }
    }

    public func delete(id: String, startMs: Int, _ done: @escaping (CalendarWriteResult) -> Void) {
        guard ready else { return done(.failed("Calendar access is off.")) }
        source.delete(id: id, startMs: startMs) { [weak self] result in
            DispatchQueue.main.async {
                if case .done = result { self?.load() }
                done(result)
            }
        }
    }

    /// Brings Calendar forward. No link from the event is followed.
    public func showInCalendar(startMs: Int) {
        model?.activateApp(.app(bundleId: CalendarText.appBundleId, tty: nil))
    }

    private func settingChanged(_ on: Bool) {
        wanted = on
        sent = nil
        guard on else { return }
        switch source.access {
        case .granted:
            model?.calendarAccess = .granted
            load()
        case .denied:
            model?.calendarAccess = .denied
        case .unknown:
            model?.calendarAccess = .unknown
            guard !asked else { return }
            asked = true
            source.requestAccess { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.model?.calendarAccess = ok ? .granted : .denied
                    if ok && self.wanted { self.load() }
                }
            }
        }
    }

    private func accessMayHaveChanged() {
        guard wanted, let model else { return }
        let access = source.access
        guard access != model.calendarAccess, access != .unknown else { return }
        model.calendarAccess = access
        if access == .granted { load() }
    }

    /// The calendars changed, or time moved: read again, once things settle.
    func changed() {
        guard wanted, source.access == .granted else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func load() {
        let from = now()
        source.events(from: from, to: from.addingTimeInterval(Self.horizon)) { [weak self] events in
            DispatchQueue.main.async {
                guard let self, self.wanted, events != self.sent else { return }
                self.sent = events
                self.model?.send(.calendarEvents(events))
            }
        }
    }
}
