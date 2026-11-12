import SwiftUI

// MARK: - Logic (pure, unit tested)

/// Live meeting numbers. The view model carries timestamps, not ticking
/// values, so everything that moves is derived here from `nowMs`.
public enum MeetingMath {
    public static let maxItems = 12
    public static let minutes: ClosedRange<Int> = 1...120

    public static func isActive(_ m: MeetingView) -> Bool {
        m.runState == .running || m.runState == .paused
    }

    /// Seconds of the current stretch not yet in `elapsed_secs`.
    public static func liveStretch(_ m: MeetingView, nowMs: Int) -> Int {
        guard m.runState == .running, let since = m.runningSinceMs else { return 0 }
        return max(0, nowMs - since) / 1000
    }

    /// Time spent on item `i` so far.
    public static func elapsed(_ m: MeetingView, item i: Int, nowMs: Int) -> Int {
        guard m.items.indices.contains(i) else { return 0 }
        return m.items[i].elapsedSecs + (i == m.current ? liveStretch(m, nowMs: nowMs) : 0)
    }

    public static func totalElapsed(_ m: MeetingView, nowMs: Int) -> Int {
        m.totalElapsedSecs + liveStretch(m, nowMs: nowMs)
    }

    /// The current item's time left; negative when over.
    public static func currentLeft(_ m: MeetingView, nowMs: Int) -> Int {
        if m.runState == .running, let end = m.endsAtMs {
            return Format.signedSecondsLeft(until: end, nowMs: nowMs)
        }
        return m.remainingSecs
    }

    public static func currentItem(_ m: MeetingView) -> MeetingItem? {
        guard let i = m.current, m.items.indices.contains(i) else { return nil }
        return m.items[i]
    }

    /// `Item 2 of 5`.
    public static func position(_ m: MeetingView) -> String {
        guard let i = m.current, m.items.indices.contains(i) else { return "\(m.items.count) items" }
        return "Item \(i + 1) of \(m.items.count)"
    }

    /// The Next button finishes the meeting on the last item.
    public static func nextTitle(_ m: MeetingView) -> String {
        guard let i = m.current else { return "Next" }
        return i >= m.items.count - 1 ? "Finish" : "Next"
    }

    /// The agenda as `meeting_set` takes it; unnamed lines are left out and
    /// minutes are clamped like the core does.
    public static func agenda(_ lines: [(name: String, minutes: Int)]) -> [AgendaLine] {
        lines.compactMap { l in
            let name = l.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return AgendaLine(name: name, minutes: min(max(l.minutes, minutes.lowerBound), minutes.upperBound))
        }
        .prefix(maxItems).map { $0 }
    }

    /// The agenda currently in the view model, in the same shape.
    public static func agenda(of m: MeetingView) -> [AgendaLine] {
        m.items.map { AgendaLine(name: $0.name, minutes: max(1, ($0.plannedSecs + 30) / 60)) }
    }
}

extension Format {
    /// Like `secondsLeft`, but negative once `endMs` has passed (whole
    /// seconds over, rounded down).
    public static func signedSecondsLeft(until endMs: Int, nowMs: Int) -> Int {
        let d = endMs - nowMs
        return d > 0 ? (d + 999) / 1000 : -((-d) / 1000)
    }

    /// `4:59` while time is left, `+1:05` over time.
    public static func signedCountdown(_ secs: Int) -> String {
        secs < 0 ? "+" + countdown(seconds: -secs) : countdown(seconds: secs)
    }
}

// MARK: - Views

/// The Meeting half of the Timer tab.
struct MeetingPane: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    private var m: MeetingView { vm.meeting }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch m.runState {
                case .finished: MeetingSummaryCard(m: m, send: model.send)
                case .running, .paused: MeetingRunCard(m: m, send: model.send)
                case .stopped, .unknown: MeetingStartCard(m: m, send: model.send)
                }
            }
            .frame(width: 226)
            if m.runState == .stopped || m.runState == .unknown {
                AgendaEditor(meeting: m, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AgendaList(m: m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Preset pills shown beside the Focus | Meeting switch while stopped.
struct MeetingPresets: View {
    let m: MeetingView
    let send: (ShellCommand) -> Void

    /// Short names so all presets fit beside the mode switch.
    static func shortTitle(_ p: MeetingPreset) -> String {
        switch p.id {
        case "standup": return "Stand-up"
        case "sprint_review": return "Review"
        case "sprint_planning": return "Planning"
        case "retro": return "Retro"
        default: return p.title
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(m.presets.enumerated()), id: \.offset) { _, p in
                let on = p.title == m.title
                Button { send(.meetingLoad(preset: p.id)) } label: {
                    VText(Self.shortTitle(p)).nfont(on ? .captionStrong : .caption)
                        .foregroundStyle(on ? NT.text1 : NT.text2)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(on ? NT.fillHi : NT.fill, in: Capsule())
                        .contentShape(Capsule())
                        .controlHover(Capsule())
                }
                .buttonStyle(.plain)
                .help("Load the \(p.title) agenda")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

private func roundButton(_ symbol: String, label: String, size: CGFloat, fill: Color, tint: Color,
                         action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .glyph(size * 0.38, .bold)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .contentShape(Circle())
            .controlHover(Circle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(Text(verbatim: label))
}

/// Before the meeting: the agenda's title and length, and Start.
struct MeetingStartCard: View {
    let m: MeetingView
    let send: (ShellCommand) -> Void

    var body: some View {
        Card(padding: 12, expand: true) {
            VStack(alignment: .leading, spacing: 2) {
                VText(m.title.isEmpty ? "Untitled meeting" : m.title)
                    .nfont(.title).foregroundStyle(NT.text1).lineLimit(1)
                Text(verbatim: Format.countdown(seconds: m.totalPlannedSecs))
                    .nfont(.display)
                    .foregroundStyle(NT.text1).lineLimit(1)
                    .padding(.top, 2)
                Text(verbatim: m.items.count == 1 ? "1 item planned" : "\(m.items.count) items planned")
                    .nfont(.caption).foregroundStyle(NT.text2)
                Spacer(minLength: 6)
                TextPill(title: "Start meeting", tint: NT.onAccent, background: NT.accent, height: 30,
                         weight: .semibold) { send(.meetingToggle) }
                    .disabled(m.items.isEmpty)
                    .opacity(m.items.isEmpty ? 0.4 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// During the meeting: the current item's countdown and the controls.
struct MeetingRunCard: View {
    let m: MeetingView
    let send: (ShellCommand) -> Void

    var body: some View {
        let running = m.runState == .running
        Card(padding: 12, expand: true) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VText(MeetingMath.currentItem(m)?.name ?? m.title)
                        .nfont(.title).foregroundStyle(NT.text1).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: running ? MeetingMath.position(m) : "Paused")
                        .nfont(running ? .caption : .captionStrong).monospacedDigit()
                        .foregroundStyle(running ? NT.text3 : NT.accentText)
                        .lineLimit(1).fixedSize()
                }
                if running {
                    EverySecond { now in numbers(now: now) }
                } else {
                    numbers(now: 0)
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    roundButton("arrow.counterclockwise", label: "Reset meeting", size: 28,
                                fill: NT.fill, tint: NT.text2) { send(.meetingReset) }
                    roundButton(running ? "pause.fill" : "play.fill", label: running ? "Pause" : "Resume",
                                size: 36, fill: NT.accent, tint: NT.onAccent) { send(.meetingToggle) }
                    Spacer(minLength: 0)
                    TextPill(title: MeetingMath.nextTitle(m), height: 28, weight: .semibold) {
                        send(.meetingNext)
                    }
                    .help(MeetingMath.nextTitle(m) == "Finish" ? "Finish the meeting" : "Finish this item and start the next")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func numbers(now: Int) -> some View {
        let left = MeetingMath.currentLeft(m, nowMs: now)
        let total = MeetingMath.totalElapsed(m, nowMs: now)
        return VStack(alignment: .leading, spacing: 2) {
            OverrunText(left: left, font: .display)
                .padding(.top, 2)
            Text(verbatim: "\(Format.countdown(seconds: total)) of \(Format.countdown(seconds: m.totalPlannedSecs)) planned")
                .nfont(.caption).monospacedDigit().foregroundStyle(NT.text2).lineLimit(1)
        }
    }
}

/// After the meeting: the total against the plan, and a way to start over.
struct MeetingSummaryCard: View {
    let m: MeetingView
    let send: (ShellCommand) -> Void

    var body: some View {
        let over = m.totalElapsedSecs > m.totalPlannedSecs
        Card(padding: 12, expand: true) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VText(m.title.isEmpty ? "Meeting" : m.title)
                        .nfont(.title).foregroundStyle(NT.text1).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: "Finished").nfont(.caption).foregroundStyle(NT.text3).fixedSize()
                }
                Text(verbatim: Format.countdown(seconds: m.totalElapsedSecs))
                    .nfont(.display)
                    .padding(.top, 2)
                    .foregroundStyle(over ? NT.deny : NT.text1).lineLimit(1)
                Text(verbatim: "Planned \(Format.countdown(seconds: m.totalPlannedSecs))")
                    .nfont(.caption).monospacedDigit().foregroundStyle(NT.text2)
                Spacer(minLength: 6)
                TextPill(title: "New meeting", tint: NT.onAccent, background: NT.accent, height: 30,
                         weight: .semibold) { send(.meetingReset) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The agenda while a meeting runs or after it: planned and actual times.
struct AgendaList: View {
    let m: MeetingView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: m.runState == .finished ? "Planned vs actual" : "Agenda")
                Spacer(minLength: 4)
                if m.runState == .finished {
                    Text(verbatim: "\(Format.countdown(seconds: m.totalElapsedSecs)) / \(Format.countdown(seconds: m.totalPlannedSecs))")
                        .nfont(.caption).monospacedDigit()
                        .foregroundStyle(m.totalElapsedSecs > m.totalPlannedSecs ? NT.deny : NT.text2)
                }
            }
            .padding(.horizontal, 8)
            NotchScroll {
                VStack(spacing: 2) {
                    ForEach(Array(m.items.enumerated()), id: \.offset) { i, item in
                        row(i, item)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func row(_ i: Int, _ item: MeetingItem) -> some View {
        let current = i == m.current && m.runState != .finished
        let done = item.state == .done
        return HStack(spacing: 8) {
            Group {
                if done {
                    Image(systemName: "checkmark").glyph(9, .bold).foregroundStyle(NT.text2)
                } else if current {
                    Circle().fill(NT.accent).frame(width: 7, height: 7)
                } else {
                    Circle().stroke(NT.text3, lineWidth: 1).frame(width: 7, height: 7)
                }
            }
            .frame(width: 12)
            VText(item.name).nfont(current ? .emphasis : .body)
                .foregroundStyle(NT.text1).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if done || current {
                if current && m.runState == .running {
                    EverySecond { now in actual(MeetingMath.elapsed(m, item: i, nowMs: now), item) }
                } else {
                    actual(MeetingMath.elapsed(m, item: i, nowMs: 0), item)
                }
            } else {
                Text(verbatim: planned(item))
                    .nfont(.caption).monospacedDigit().foregroundStyle(NT.text3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(current ? NT.fill : Color.clear, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        .opacity(done && m.runState != .finished ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private func planned(_ item: MeetingItem) -> String { "\(max(1, (item.plannedSecs + 30) / 60))m" }

    /// `26:05 / 25m`: time spent against the plan, red with a mark when over.
    private func actual(_ secs: Int, _ item: MeetingItem) -> some View {
        let over = secs > item.plannedSecs
        return HStack(spacing: 4) {
            if over {
                Image(systemName: "exclamationmark.circle").glyph(NGlyph.small)
                    .accessibilityLabel(Text(verbatim: "Over time"))
            }
            Text(verbatim: "\(Format.countdown(seconds: secs)) / \(planned(item))")
        }
        .nfont(.caption).monospacedDigit()
        .foregroundStyle(over ? NT.deny : NT.text2)
    }
}

/// The agenda before the meeting starts: rename, retime, add and remove
/// items. Edits are sent whole, debounced, like Settings.
struct AgendaEditor: View {
    let meeting: MeetingView
    @ObservedObject var model: PanelState

    struct Line: Identifiable, Equatable {
        let id: Int
        var name: String
        var minutes: Int
    }

    @Environment(\.isSnapshot) private var snapshot
    @State private var lines: [Line]
    @State private var nextId: Int
    @State private var pending: DispatchWorkItem?
    @FocusState private var focused: Int?

    init(meeting: MeetingView, model: PanelState) {
        self.meeting = meeting
        self.model = model
        let l = Self.lines(from: meeting)
        _lines = State(initialValue: l)
        _nextId = State(initialValue: l.count)
    }

    static func lines(from m: MeetingView) -> [Line] {
        MeetingMath.agenda(of: m).enumerated().map { Line(id: $0.offset, name: $0.element.name, minutes: $0.element.minutes) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Agenda")
                Spacer(minLength: 4)
                Text(verbatim: "\(lines.reduce(0) { $0 + $1.minutes }) min")
                    .nfont(.caption).monospacedDigit().foregroundStyle(NT.text3)
            }
            .padding(.horizontal, 4)
            NotchScroll {
                VStack(spacing: 4) {
                    ForEach($lines) { $line in
                        row($line)
                    }
                    if lines.count < MeetingMath.maxItems {
                        Button(action: add) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus").glyph(9, .bold)
                                Text(verbatim: "Add item").nfont(.bodyMedium)
                            }
                            .foregroundStyle(NT.text2)
                            .padding(.horizontal, 8).frame(height: 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .rowHover(inset: 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 4)
        .onChange(of: lines) { _, new in schedule(new) }
        .onChange(of: meeting) { _, incoming in
            // Take the core's version (cleaned names, a loaded preset) unless
            // the user is in the middle of an edit.
            guard pending == nil, focused == nil else { return }
            let fresh = Self.lines(from: incoming)
            if fresh.map(\.name) != lines.map(\.name) || fresh.map(\.minutes) != lines.map(\.minutes) {
                lines = fresh
                nextId = fresh.count
            }
        }
        .onChange(of: focused) { _, f in model.requestKeyboard(f != nil) }
        .onDisappear { model.requestKeyboard(false) }
    }

    private func row(_ line: Binding<Line>) -> some View {
        let id = line.wrappedValue.id
        return HStack(spacing: 6) {
            Group {
                if snapshot {
                    VText(line.wrappedValue.name).nfont(.body).foregroundStyle(NT.text1).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: line.name,
                              prompt: Text(verbatim: "Item name").foregroundColor(NT.text3))
                        .textFieldStyle(.plain)
                        .font(NType.body.font)
                        .foregroundStyle(NT.text1)
                        .focused($focused, equals: id)
                        .onSubmit { focused = nil }
                        .simultaneousGesture(TapGesture().onEnded { model.requestKeyboard(true) })
                        .accessibilityLabel(Text(verbatim: "Item name"))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
            MiniStepper(value: line.minutes, range: MeetingMath.minutes, label: "Minutes")
            Text(verbatim: "min").nfont(.caption).foregroundStyle(NT.text3)
            IconButton(symbol: "minus.circle", label: "Remove item", size: 11, tint: NT.text3) {
                lines.removeAll { $0.id == id }
            }
            // 28 pt to click, without making the row taller.
            .padding(.vertical, -2)
        }
    }

    private func add() {
        guard lines.count < MeetingMath.maxItems else { return }
        let id = nextId
        nextId += 1
        lines.append(Line(id: id, name: "", minutes: 5))
        model.requestKeyboard(true)
        DispatchQueue.main.async { focused = id }
    }

    private func schedule(_ new: [Line]) {
        pending?.cancel()
        pending = nil
        let agenda = MeetingMath.agenda(new.map { ($0.name, $0.minutes) })
        guard agenda != MeetingMath.agenda(of: meeting) else { return }
        let title = meeting.title
        let send = model.send
        let work = DispatchWorkItem { pending = nil; send(.meetingSet(title: title, items: agenda)) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// A time box's time left, or `1:05 over` in red with a mark once it ran out.
struct OverrunText: View {
    let left: Int
    var font: NType = .display

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if left < 0 {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: font.size * 0.7, weight: .semibold))
            }
            Text(verbatim: Format.overrun(left)).font(font.font).monospacedDigit()
        }
        .foregroundStyle(left < 0 ? NT.deny : NT.text1)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: left < 0
            ? "\(Format.countdown(seconds: -left)) over time" : "\(Format.countdown(seconds: left)) left"))
    }
}
