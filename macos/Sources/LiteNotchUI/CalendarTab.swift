import SwiftUI

// The Calendar tab: the next two days by day, one event in full, and a form
// to add or change an event. Shown only while Settings › Calendar is on.
// Invitation text arrives sanitized by the core and is drawn verbatim; a
// link in an event is shown and can be copied, never opened.

struct CalendarTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState
    @Environment(\.clockOffsetMs) private var offset

    var body: some View {
        Group {
            if !vm.settings.calendar.enabled {
                EmptyState(
                    symbol: "calendar", title: "Calendar is off",
                    hint: "Turn it on to see your next events here and add or change them."
                ) {
                    TextPill(title: "Turn on", tint: NT.onAccent, background: NT.accent, weight: .semibold) {
                        guard var s = model.view?.settings else { return }
                        s.calendar.enabled = true
                        model.send(.setSettings(s))
                    }
                }
            } else if model.calendarAccess == .denied {
                EmptyState(
                    symbol: "calendar.badge.exclamationmark", title: "Calendar needs permission",
                    hint: "Allow LiteNotch under Privacy & Security \u{203A} Calendars, with full access."
                ) {
                    TextPill(title: "Open Settings") { model.app?.onOpenCalendarSettings() }
                }
            } else if model.calendarAccess == .unknown && model.app?.calendarEditor != nil {
                EmptyState(
                    symbol: "calendar", title: "Waiting for permission",
                    hint: "Answer the macOS question to see your events here.")
            } else {
                switch model.calendarPage {
                case .list: CalendarList(vm: vm, model: model)
                case .event(let key): EventPage(vm: vm, model: model, key: key)
                case .edit(let key):
                    if let d = vm.calendar.detail, d.key == key, d.canEdit {
                        EventForm(model: model, draft: .editing(d), recurring: d.recurring)
                    } else {
                        EventPage(vm: vm, model: model, key: key)
                    }
                case .new:
                    EventForm(
                        model: model, draft: .new(now: Date(ms: nowMs(Date(), offset: offset)), calendarId: nil),
                        recurring: false)
                }
            }
        }
    }
}

// MARK: - List

private struct CalendarList: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState
    @Environment(\.clockOffsetMs) private var offset

    var body: some View {
        EverySecond(interval: 30) { now in
            let days = CalendarText.days(vm.calendar.upcoming(nowMs: now), nowMs: now)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(text: "Next two days")
                    if let notice = model.calendarNotice {
                        Label {
                            Text(verbatim: notice)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .nfont(.caption).foregroundStyle(NT.text2)
                        .accessibilityAddTraits(.updatesFrequently)
                    }
                    Spacer(minLength: 4)
                    TextPill(title: "New event", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                        // A click: the form may take the keyboard.
                        model.requestKeyboard(true)
                        model.calendarPage = .new
                    }
                    .help("Add an event to your calendar")
                }
                .padding(.horizontal, 4)
                if days.isEmpty {
                    EmptyState(
                        symbol: "calendar", title: "Nothing in the next two days",
                        hint: "Events from every calendar on this Mac show up here.")
                } else {
                    NotchScroll {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(days, id: \.title) { day in
                                Text(verbatim: day.title).nfont(.caption).foregroundStyle(NT.text3)
                                    .padding(.horizontal, 4).padding(.top, 4)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(day.events) { e in
                                    EventRow(event: e, nowMs: now) { model.calendarPage = .event(e.key) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let nowMs: Int
    let open: () -> Void

    var body: some View {
        let running = event.startMs <= nowMs
        Button(action: open) {
            HStack(spacing: 10) {
                Capsule().fill(event.color.map(NT.color) ?? NT.text3)
                    .frame(width: 3, height: 26)
                    .accessibilityHidden(true)
                Text(verbatim: CalendarText.timeRange(startMs: event.startMs, endMs: event.endMs))
                    .nfont(.body).monospacedDigit()
                    .foregroundStyle(running ? NT.accentText : NT.text2)
                    .lineLimit(1)
                    // 24-hour times fit 112 pt; 12-hour ones take what they need.
                    .fixedSize()
                    .frame(minWidth: 112, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    VText(event.title).nfont(.emphasis).foregroundStyle(NT.text1).lineLimit(1)
                    let place = CalendarText.place(event)
                    if !place.isEmpty {
                        VText(place).nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if running {
                    Text(verbatim: "Now").nfont(.captionStrong).foregroundStyle(NT.accentText)
                } else {
                    Text(verbatim: Format.startsIn(startMs: event.startMs, nowMs: nowMs))
                        .nfont(.caption).monospacedDigit().foregroundStyle(NT.text3).lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").glyph(NGlyph.small).foregroundStyle(NT.text3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
            .rowHover(inset: 0)
        }
        .buttonStyle(.plain)
        .help("Show this event")
        .accessibilityLabel(
            Text(
                verbatim: [
                    event.title, CalendarText.timeRange(startMs: event.startMs, endMs: event.endMs),
                    CalendarText.place(event),
                    running ? "now" : "starts \(Format.startsIn(startMs: event.startMs, nowMs: nowMs))",
                ].filter { !$0.isEmpty }.joined(separator: ", ")
            )
        )
        .accessibilityHint(Text(verbatim: "Opens the event"))
    }
}

// MARK: - One event

private struct EventPage: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState
    let key: String

    @Environment(\.clockOffsetMs) private var offset
    @State private var error: String?
    @State private var busy = false
    @State private var copied = false

    /// The core's full detail once it has come; the list's line until then.
    private var detail: EventDetail? { vm.calendar.detail.flatMap { $0.key == key ? $0 : nil } }
    private var listed: CalendarEvent? { vm.calendar.events.first { $0.key == key } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let error {
                WarningText(text: error).nfont(.caption).padding(.horizontal, 4)
            }
            if let d = detail {
                NotchScroll { fields(d) }
            } else if let e = listed {
                NotchScroll {
                    fields(
                        EventDetail(
                            id: e.id, title: e.title, startMs: e.startMs, endMs: e.endMs, calendar: e.calendar,
                            color: e.color, location: e.location, notes: "", notesTruncated: false, url: "",
                            organizer: "", attendees: [], attendeesMore: 0, recurring: false, canEdit: false))
                }
            } else {
                EmptyState(
                    symbol: "calendar.badge.minus", title: "This event is not listed any more",
                    hint: "It was deleted or moved, or it has ended.")
            }
        }
        .onAppear(perform: request)
        .onChange(of: key) { _, _ in
            copied = false
            error = nil
            request()
        }
    }

    private func request() {
        guard detail == nil, let e = listed else { return }
        model.app?.calendarEditor?.open(id: e.id, startMs: e.startMs)
    }

    private func back() {
        model.calendarPage = .list
        model.app?.calendarEditor?.close()
    }

    private var header: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", label: "Back to the list", size: NGlyph.small, action: back)
            VText(detail?.title ?? listed?.title ?? "Event")
                .nfont(.title).foregroundStyle(NT.text1).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let d = detail {
                if d.canEdit {
                    TextPill(title: "Edit", height: 22) {
                        model.requestKeyboard(true)
                        model.calendarPage = .edit(key)
                    }
                    .help("Change the title, time or place")
                    ConfirmPill(
                        title: "Delete", question: d.recurring ? "Delete this one?" : "Delete event?",
                        help: d.recurring ? "Delete this occurrence; the others stay" : "Delete it from your calendar",
                        enabled: !busy, height: 22, action: { delete(d) })
                } else {
                    TextPill(title: "Open Calendar", height: 22) {
                        model.app?.calendarEditor?.showInCalendar(startMs: d.startMs)
                    }
                    .help("An event with guests, or in a calendar that cannot be changed here")
                }
            }
        }
        .padding(.leading, -6)
        .padding(.trailing, 4)
    }

    private func delete(_ d: EventDetail) {
        guard let editor = model.app?.calendarEditor else { return }
        busy = true
        error = nil
        editor.delete(id: d.id, startMs: d.startMs) { result in
            busy = false
            switch result {
            case .done:
                model.calendarPage = .list
                model.showCalendarNotice("Deleted")
                editor.close()
            case .failed(let why): error = why
            }
        }
    }

    @ViewBuilder private func fields(_ d: EventDetail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            field("When") {
                VText(CalendarText.when(startMs: d.startMs, endMs: d.endMs, nowMs: nowMs(Date(), offset: offset)))
                    .nfont(.body).foregroundStyle(NT.text1)
                if d.recurring {
                    Text(verbatim: CalendarText.repeatsNote)
                        .nfont(.caption).foregroundStyle(NT.text3)
                }
                if !d.canEdit && !d.attendees.isEmpty {
                    Text(verbatim: "Has guests: change it in Calendar, which tells them.")
                        .nfont(.caption).foregroundStyle(NT.text3)
                }
            }
            if !d.calendar.isEmpty {
                field("Calendar") {
                    HStack(spacing: 5) {
                        if let hex = d.color {
                            Circle().fill(NT.color(hex)).frame(width: 7, height: 7).accessibilityHidden(true)
                        }
                        VText(d.calendar).nfont(.body).foregroundStyle(NT.text1).lineLimit(1)
                    }
                }
            }
            if !d.location.isEmpty {
                field("Where") { VText(d.location).nfont(.body).foregroundStyle(NT.text1).lineLimit(2) }
            }
            if !d.url.isEmpty {
                field("Link") {
                    HStack(spacing: 6) {
                        Text(verbatim: d.url).nfont(.body).foregroundStyle(NT.text2)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        TextPill(title: copied ? "Copied" : "Copy", height: 20) {
                            model.app?.copyText(d.url)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }
                        .frame(minWidth: 60, alignment: .leading)
                        .help("Copy the link. LiteNotch does not open links from invitations.")
                    }
                }
            }
            // Only when the organizer is not already one of the guests,
            // where their label says so.
            if !d.organizer.isEmpty && !d.attendees.isEmpty && !d.attendees.contains(where: { $0.name == d.organizer }) {
                field("Organizer") { VText(d.organizer).nfont(.body).foregroundStyle(NT.text1).lineLimit(1) }
            }
            if !d.attendees.isEmpty {
                field(d.attendees.count + d.attendeesMore == 1 ? "Guest" : "Guests") {
                    // Two to a row; plain stacks so the label lines up with
                    // the first row's text.
                    ForEach(Array(stride(from: 0, to: d.attendees.count, by: 2)), id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            AttendeeLabel(attendee: d.attendees[i], organizer: d.organizer).frame(maxWidth: .infinity, alignment: .leading)
                            Group {
                                if i + 1 < d.attendees.count {
                                    AttendeeLabel(attendee: d.attendees[i + 1], organizer: d.organizer)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if d.attendeesMore > 0 {
                        Text(verbatim: "and \(d.attendeesMore) more").nfont(.caption).foregroundStyle(NT.text3)
                    }
                }
            }
            if !d.notes.isEmpty {
                field("Notes") {
                    Text(verbatim: d.notes).nfont(.body).foregroundStyle(NT.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if d.notesTruncated {
                        Text(verbatim: "The rest is in Calendar.").nfont(.caption).foregroundStyle(NT.text3)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: label).nfont(.caption).foregroundStyle(NT.text3)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AttendeeLabel: View {
    let attendee: Attendee
    var organizer = ""

    var body: some View {
        let (symbol, tint, said) = CalendarText.status(attendee.status)
        let name = CalendarText.guestName(attendee, organizer: organizer)
        HStack(spacing: 5) {
            Image(systemName: symbol).glyph(9.5).foregroundStyle(tint).frame(width: 12)
            VText(name).nfont(.body).foregroundStyle(NT.text1).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(name), \(said)"))
        .help("\(name): \(said)")
    }
}

// MARK: - Form

private struct EventForm: View {
    @ObservedObject var model: PanelState
    let recurring: Bool

    @Environment(\.isSnapshot) private var snapshot
    @State private var draft: EventDraft
    @State private var choices: [CalendarChoice] = []
    @State private var choicesLoaded = false
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case title, location }

    init(model: PanelState, draft: EventDraft, recurring: Bool) {
        self.model = model
        self.recurring = recurring
        _draft = State(initialValue: draft)
    }

    private var canSave: Bool { !busy && blocked == nil }

    /// Why Save cannot be clicked, or nil when it can.
    private var blocked: String? {
        if let p = draft.problem { return p }
        return draft.isNew || draft.isChanged ? nil : "No changes yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", label: "Cancel", size: NGlyph.small, action: cancel)
                Text(verbatim: draft.isNew ? "New event" : "Edit event").nfont(.title).foregroundStyle(NT.text1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                // A failed save, else why Save cannot be clicked yet.
                if let error, !busy {
                    WarningText(text: error).nfont(.caption).lineLimit(2)
                } else if let why = blocked, !busy {
                    Text(verbatim: why).nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
                }
                TextPill(
                    title: busy ? "Saving\u{2026}" : (draft.isNew ? "Add" : "Save"),
                    tint: canSave ? NT.onAccent : NT.text2,
                    background: canSave ? NT.accent : NT.accent.opacity(0.22),
                    height: 22, weight: .semibold, action: save
                )
                .disabled(!canSave)
                .help(blocked ?? (draft.isNew ? "Add it to your calendar" : "Save the changes"))
            }
            .padding(.leading, -6)
            .padding(.trailing, 4)
            NotchScroll {
                VStack(alignment: .leading, spacing: 7) {
                    row("Title") { text($draft.title, "Event title", .title) }
                    row("Starts") {
                        date(
                            Binding(get: { draft.start }, set: { draft.moveStart(to: $0) }), label: "Starts")
                    }
                    row("Ends") {
                        date($draft.end, label: "Ends")
                        Text(verbatim: CalendarText.length(startMs: draft.start.ms, endMs: draft.end.ms))
                            .nfont(.caption).foregroundStyle(NT.text3)
                    }
                    if draft.isNew {
                        row("Calendar") { calendarMenu }
                    }
                    row("Where") { text($draft.location, "Location (optional)", .location) }
                    if recurring {
                        Text(verbatim: CalendarText.repeatsNote)
                            .nfont(.caption).foregroundStyle(NT.text3)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            // The keyboard only after a click (New event, Edit, a field):
            // never because the panel opened on this page by hovering.
            if draft.isNew { loadCalendars() }
            if draft.isNew && model.keyboardRequested { DispatchQueue.main.async { focus = .title } }
        }
        .onDisappear { model.requestKeyboard(false) }
        .onExitCommand(perform: cancel)
    }

    private func loadCalendars() {
        guard let editor = model.app?.calendarEditor else { return }
        editor.calendars { list, fallback in
            choices = list
            choicesLoaded = true
            if draft.calendarId == nil || !list.contains(where: { $0.id == draft.calendarId }) {
                draft.calendarId = fallback
            }
        }
    }

    private func cancel() {
        guard let o = draft.original else {
            model.calendarPage = .list
            return
        }
        model.calendarPage = .event("\(o.startMs)-\(o.id)")
    }

    private func save() {
        guard canSave, let editor = model.app?.calendarEditor else { return }
        busy = true
        error = nil
        let original = draft.original
        editor.save(draft) { result in
            busy = false
            switch result {
            case .done(let start):
                if let o = original {
                    let at = start ?? o.startMs
                    model.calendarPage = .event("\(at)-\(o.id)")
                    editor.open(id: o.id, startMs: at)
                    model.showCalendarNotice("Saved")
                } else {
                    model.calendarPage = .list
                    model.showCalendarNotice("Added")
                }
            case .failed(let why):
                error = why
            }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: label).nfont(.caption).foregroundStyle(NT.text3)
                .frame(width: 62, alignment: .leading)
            HStack(spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func box<C: View>(_ content: C) -> some View {
        content
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
    }

    @ViewBuilder private func text(_ value: Binding<String>, _ prompt: String, _ field: Field) -> some View {
        if snapshot {
            box(
                VText(value.wrappedValue.isEmpty ? prompt : value.wrappedValue)
                    .nfont(.body).foregroundStyle(value.wrappedValue.isEmpty ? NT.text3 : NT.text1).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading))
        } else {
            box(
                TextField("", text: value, prompt: Text(verbatim: prompt).foregroundColor(NT.text3))
                    .textFieldStyle(.plain)
                    .font(NType.body.font)
                    .foregroundStyle(NT.text1)
                    .focused($focus, equals: field)
                    .onSubmit(save)
                    .simultaneousGesture(TapGesture().onEnded { model.requestKeyboard(true) })
                    .accessibilityLabel(Text(verbatim: prompt)))
        }
    }

    @ViewBuilder private func date(_ value: Binding<Date>, label: String) -> some View {
        if snapshot {
            box(
                Text(verbatim: CalendarText.fieldDate(value.wrappedValue))
                    .nfont(.body).monospacedDigit().foregroundStyle(NT.text1))
        } else {
            DatePicker("", selection: value, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .font(NType.body.font)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: label))
        }
    }

    @ViewBuilder private var calendarMenu: some View {
        let chosen = choices.first { $0.id == draft.calendarId }
        if choices.isEmpty {
            let editor = model.app?.calendarEditor != nil
            box(
                Text(
                    verbatim: !editor ? "Default calendar" : (choicesLoaded ? "No calendar takes new events" : "Loading\u{2026}")
                )
                .nfont(.body).foregroundStyle(NT.text3))
        } else {
            Menu {
                ForEach(choices) { c in
                    Button(c.title) { draft.calendarId = c.id }
                }
            } label: {
                box(
                    HStack(spacing: 5) {
                        if let hex = chosen?.color {
                            Circle().fill(NT.color(hex)).frame(width: 7, height: 7)
                        }
                        Text(verbatim: chosen?.title ?? "Choose").nfont(.body).foregroundStyle(NT.text1)
                        Image(systemName: "chevron.up.chevron.down").glyph(8).foregroundStyle(NT.text3)
                    })
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: "Calendar"))
        }
    }
}

// MARK: - Text

extension CalendarText {
    /// One day of the list.
    public struct Day: Equatable {
        public var title: String
        public var events: [CalendarEvent]
    }

    /// The events by the day they start; one already running counts as today.
    public static func days(
        _ events: [CalendarEvent], nowMs: Int, calendar: Calendar = .current, locale: Locale = .current
    ) -> [Day] {
        let today = calendar.startOfDay(for: Date(ms: nowMs))
        var out: [Day] = []
        for e in events {
            let start = max(calendar.startOfDay(for: Date(ms: e.startMs)), today)
            let offset = calendar.dateComponents([.day], from: today, to: start).day ?? 0
            let title: String
            switch offset {
            case 0: title = "Today"
            case 1: title = "Tomorrow"
            default:
                title = start.formatted(
                    Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                        .weekday(.wide).day().month(.abbreviated))
            }
            if out.last?.title == title {
                out[out.count - 1].events.append(e)
            } else {
                out.append(Day(title: title, events: [e]))
            }
        }
        return out
    }

    /// `10:30 – 11:00`; the end's weekday too when it ends on another day.
    public static func timeRange(
        startMs: Int, endMs: Int, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let style = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let start = Date(ms: startMs)
        let end = Date(ms: endMs)
        if calendar.isDate(start, inSameDayAs: end) || end == calendar.startOfDay(for: end) && endMs - startMs <= 86_400_000 {
            return "\(start.formatted(style)) \u{2013} \(end.formatted(style))"
        }
        let weekday = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
        return "\(start.formatted(style)) \u{2013} \(end.formatted(weekday)) \(end.formatted(style))"
    }

    /// `30 min`, `1 h`, `1 h 15 min`, `2 d 3 h`.
    public static func length(startMs: Int, endMs: Int) -> String {
        let minutes = max(0, (endMs - startMs) / 60_000)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 {
            return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
        }
        return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
    }

    /// The event page's "When": the day, the times and how long.
    public static func when(
        startMs: Int, endMs: Int, nowMs: Int, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let day =
            days(
                [CalendarEvent(id: "", title: "", startMs: startMs, endMs: endMs)], nowMs: nowMs, calendar: calendar,
                locale: locale
            ).first?.title ?? ""
        let range = timeRange(startMs: startMs, endMs: endMs, calendar: calendar, locale: locale)
        return "\(day), \(range) \u{b7} \(length(startMs: startMs, endMs: endMs))"
    }

    /// Said wherever a repeating event can be changed.
    static let repeatsNote = "Repeats. Changes here apply to this occurrence only."

    /// `Sam Lee (organizer)`, `Jordan Park (you)`.
    static func guestName(_ a: Attendee, organizer: String) -> String {
        if a.me { return "\(a.name) (you)" }
        if !organizer.isEmpty && a.name == organizer { return "\(a.name) (organizer)" }
        return a.name
    }

    /// The location, then the calendar.
    public static func place(_ e: CalendarEvent) -> String {
        [e.location, e.calendar].filter { !$0.isEmpty }.joined(separator: " \u{b7} ")
    }

    /// How a snapshot draws a date field.
    static func fieldDate(_ d: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        d.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .shortened, locale: locale, calendar: calendar,
                timeZone: calendar.timeZone))
    }

    /// Icon, colour and words for an attendee's answer.
    static func status(_ s: AttendeeStatus) -> (String, Color, String) {
        switch s {
        case .accepted: return ("checkmark.circle.fill", NT.allow, "Going")
        case .declined: return ("xmark.circle.fill", NT.deny, "Not going")
        case .tentative: return ("questionmark.circle.fill", NT.warning, "Maybe")
        case .pending, .unknown: return ("circle", NT.text3, "No answer yet")
        }
    }
}
