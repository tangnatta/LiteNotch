import AppKit
import Combine
import EventKit
import Foundation

// The user's calendars, through EventKit: whatever accounts the Calendar app
// shows (iCloud, Google, Exchange, …). Read-only. Event-driven: the events
// are read again when the calendar database says it changed, on a new day
// and after waking, never on a timer. The core decides when to alert.

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

/// What the observer needs from the calendar store; tests use a fake.
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    /// Asks the user. `done` may be called on any thread.
    func requestAccess(_ done: @escaping (Bool) -> Void)
    /// Timed events overlapping the range. `done` may be called on any thread.
    func events(from: Date, to: Date, _ done: @escaping ([CalendarEventInput]) -> Void)
    /// Called (on any thread) when the calendars changed.
    var onChange: (() -> Void)? { get set }
}

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
            startMs: Int(start.timeIntervalSince1970 * 1000),
            endMs: Int(end.timeIntervalSince1970 * 1000),
            calendar: e.calendar?.title ?? "",
            color: e.calendar.flatMap { ColorMath.hex(of: $0.color) },
            location: e.location ?? "")
    }
}

/// Follows `settings.calendar.enabled`: asks for access once, then keeps the
/// core's list of upcoming events current.
public final class CalendarObserver {
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
