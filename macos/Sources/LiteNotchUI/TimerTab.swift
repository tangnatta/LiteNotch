import SwiftUI

/// Focus: the pomodoro timer, today's totals and the schedule in use.
/// Meeting: an agenda with a time box per item.
/// Timer: a plain countdown.
struct TimerTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    var body: some View {
        VStack(spacing: 8) {
            TimerHeader(vm: vm, model: model)
            switch model.timerPane {
            case .focus: focus
            case .meeting: MeetingPane(vm: vm, model: model)
            case .countdown: CountdownPane(t: vm.timer, model: model)
            }
        }
    }

    private var focus: some View {
        HStack(alignment: .top, spacing: 16) {
            PomodoroCard(p: vm.pomodoro, send: model.send)
                .frame(width: 226)
            VStack(alignment: .leading, spacing: 12) {
                today
                Hairline()
                schedule
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Today's totals; the captions say what they count, so no label.
    private var today: some View {
        HStack(alignment: .top, spacing: 0) {
            stat("\(vm.pomodoro.completedToday)",
                 vm.pomodoro.completedToday == 1 ? "focus session today" : "focus sessions today")
            stat(Format.duration(secs: vm.pomodoro.focusSecsToday), "focused today")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value).nfont(.display)
                .foregroundStyle(NT.text1).lineLimit(1)
            Text(verbatim: caption).nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var schedule: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel(text: "Schedule")
                ForEach(Format.scheduleLines(vm.settings.pomodoro), id: \.self) { line in
                    Text(verbatim: line).nfont(.body).foregroundStyle(NT.text2).lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
            }
            Spacer(minLength: 4)
            TextPill(title: "Edit", tint: NT.text1, height: 22) { model.openSettings(.timer) }
                .help("Change the lengths in Settings \u{203A} Timer")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The mode switch and, for a meeting that has not started, the presets.
/// It must fit the panel's width in every mode (a test checks this).
struct TimerHeader: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    var body: some View {
        HStack(spacing: 8) {
            SegmentedPill(options: [(TimerPane.focus, "Focus"), (TimerPane.meeting, "Meeting"),
                                    (TimerPane.countdown, "Timer")],
                          selection: $model.timerPane, label: "Timer view")
            Spacer(minLength: 4)
            if model.timerPane == .meeting
                && (vm.meeting.runState == .stopped || vm.meeting.runState == .unknown) {
                MeetingPresets(m: vm.meeting, send: model.send)
            }
        }
        .frame(height: 24)
    }
}

// MARK: - Pomodoro

struct PomodoroCard: View {
    let p: PomodoroView
    let send: (ShellCommand) -> Void

    var body: some View {
        Card(padding: 10, expand: true) {
            VStack(spacing: 8) {
                ring
                dots
                controls
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var tint: Color { p.phase == .focus ? NT.accent : NT.text1 }

    private var ring: some View {
        EverySecond { now in
            let left = p.runState == .running && p.endsAtMs != nil
                ? Format.secondsLeft(until: p.endsAtMs ?? now, nowMs: now) : p.remainingSecs
            let progress = p.phase == .idle || p.totalSecs <= 0 ? 0 : 1 - Double(left) / Double(p.totalSecs)
            ZStack {
                Circle().stroke(NT.fillHi, lineWidth: 5)
                Circle().trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(verbatim: Format.countdown(seconds: left))
                        .nfont(.display)
                        .foregroundStyle(NT.text1)
                    Text(verbatim: p.runState == .paused ? "Paused" : Format.phaseLabel(p.phase))
                        .nfont(.caption).foregroundStyle(NT.text2)
                }
            }
            .frame(width: 100, height: 100)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(Format.phaseLabel(p.phase)), \(Format.countdown(seconds: left)) left"))
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(1, min(p.roundsBeforeLong, 12)), id: \.self) { i in
                Circle()
                    .fill(i < p.round ? NT.text1 : (i == p.round && p.phase == .focus ? NT.accent : NT.fillHi))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Round \(p.round) of \(p.roundsBeforeLong)"))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            circleButton("arrow.counterclockwise", label: "Reset", size: 28, fill: NT.fill, tint: NT.text2) {
                send(.pomodoroReset)
            }
            circleButton(p.runState == .running ? "pause.fill" : "play.fill",
                         label: p.runState == .running ? "Pause" : "Start",
                         size: 36, fill: NT.accent, tint: NT.onAccent) { send(.pomodoroToggle) }
            circleButton("forward.end.fill", label: "Skip to the next phase", size: 28, fill: NT.fill, tint: NT.text2) {
                send(.pomodoroSkip)
            }
        }
    }

    private func circleButton(_ symbol: String, label: String, size: CGFloat, fill: Color,
                              tint: Color, action: @escaping () -> Void) -> some View {
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
}

// MARK: - Countdown

struct CountdownPane: View {
    let t: CountdownView
    @ObservedObject var model: PanelState
    /// The time being typed into the circle; nil when not typing.
    @State private var typed: String?
    @FocusState private var focused: Bool

    private var send: (ShellCommand) -> Void { model.send }
    private var editable: Bool { !t.isActive }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            clock.frame(width: 226)
            VStack(alignment: .leading, spacing: 12) {
                if editable {
                    presets
                    Hairline()
                    length
                } else {
                    // Lengths only change while stopped, so they are not
                    // shown at all rather than shown disabled.
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Set for \(Format.timerPreset(t.durationSecs))")
                            .nfont(.title).foregroundStyle(NT.text1)
                        Text(verbatim: "Reset the timer to change its length.")
                            .nfont(.caption).foregroundStyle(NT.text3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func left(_ now: Int) -> Int {
        if t.runState == .running, let end = t.endsAtMs { return Format.secondsLeft(until: end, nowMs: now) }
        return t.remainingSecs
    }

    private var clock: some View {
        Card(padding: 10, expand: true) {
            VStack(spacing: 10) {
                EverySecond { now in
                    let l = left(now)
                    let progress = t.durationSecs > 0 ? 1 - Double(l) / Double(t.durationSecs) : 0
                    ZStack {
                        Circle().stroke(NT.fillHi, lineWidth: 5)
                        Circle().trim(from: 0, to: max(0, min(1, progress)))
                            .stroke(NT.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 1) {
                            if typed != nil {
                                timeField
                            } else if !editable {
                                // Plain text while running: a disabled
                                // button would draw the digits greyed out.
                                Text(verbatim: Format.countdown(seconds: l))
                                    .nfont(.display).foregroundStyle(NT.text1)
                            } else {
                                Button(action: beginTyping) {
                                    Text(verbatim: Format.countdown(seconds: l))
                                        .nfont(.display)
                                        .foregroundStyle(NT.text1)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!editable)
                                .help(editable ? "Click to type a time, e.g. 25, 1:30 or 1h 15m" : "")
                                .accessibilityLabel(Text(verbatim: "Set the time"))
                            }
                            Text(verbatim: typed != nil ? typingHint : status).nfont(.caption)
                                .foregroundStyle(typed != nil && invalid ? NT.deny
                                                 : (t.runState == .done ? NT.accentText : NT.text2))
                        }
                    }
                    .frame(width: 104, height: 104)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "Timer, \(Format.countdown(seconds: l)) left, \(status)"))
                }
                HStack(spacing: 10) {
                    round("arrow.counterclockwise", "Reset", 28, NT.fill, NT.text2) { send(.timerReset) }
                    round(t.runState == .running ? "pause.fill" : "play.fill",
                          t.runState == .running ? "Pause" : "Start", 36, NT.accent, NT.onAccent) {
                        send(.timerToggle)
                    }
                    Button { send(.timerAdd(secs: 60)) } label: {
                        Text(verbatim: "+1m").nfont(.captionStrong).foregroundStyle(NT.text2)
                            .frame(width: 28, height: 28)
                            .background(NT.fill, in: Circle())
                            .contentShape(Circle())
                            .controlHover(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "Add one minute"))
                    .help("Add one minute")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// What was typed parses (empty means "keep the current length").
    private var invalid: Bool {
        guard let typed, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return Format.parseDuration(typed) == nil
    }

    private var typingHint: String { invalid ? "e.g. 25 or 1:30" : "Return to set" }

    private var timeField: some View {
        TextField("", text: Binding(get: { typed ?? "" }, set: { typed = $0 }),
                  prompt: Text(verbatim: Format.countdown(seconds: t.durationSecs)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(NType.display.font)
            .foregroundStyle(invalid ? NT.deny : NT.text1)
            .frame(width: 90)
            .focused($focused)
            .onSubmit(commitTyping)
            .onExitCommand(perform: cancelTyping)
            .onChange(of: focused) { _, f in if !f { cancelTyping() } }
    }

    private func beginTyping() {
        guard editable else { return }
        typed = ""
        model.requestKeyboard(true)
        DispatchQueue.main.async { focused = true }
    }

    private func commitTyping() {
        if let text = typed, let secs = Format.parseDuration(text) {
            send(.timerSet(secs: secs))
        } else if invalid {
            return
        }
        cancelTyping()
    }

    private func cancelTyping() {
        typed = nil
        focused = false
        model.requestKeyboard(false)
    }

    private var status: String {
        switch t.runState {
        case .running: return "Running"
        case .paused: return "Paused"
        case .done: return "Done"
        case .stopped, .unknown: return "Timer"
        }
    }

    /// Preset lengths; they read as times, so no label.
    private var presets: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(t.presets, id: \.self) { secs in
                let selected = secs == t.durationSecs
                Button { send(.timerSet(secs: secs)) } label: {
                    Text(verbatim: Format.timerPreset(secs))
                        .nfont(selected ? .emphasis : .bodyMedium)
                        .foregroundStyle(selected ? NT.text1 : NT.text2)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selected ? NT.fillHi : NT.fill, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? NT.text3 : Color.clear, lineWidth: 1))
                        .contentShape(Capsule())
                        .controlHover(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("Set the timer to \(Format.timerPreset(secs))")
                .accessibilityLabel(Text(verbatim: "Set timer to \(Format.timerPreset(secs))"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var length: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Length in minutes")
                Text(verbatim: "Or click the time to type one")
                    .nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            MiniStepper(value: Binding(get: { max(1, t.durationSecs / 60) },
                                       set: { send(.timerSet(secs: $0 * 60)) }),
                        range: 1...240, label: "Timer minutes")
        }
    }

    private func round(_ symbol: String, _ label: String, _ size: CGFloat, _ fill: Color, _ tint: Color,
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
}
