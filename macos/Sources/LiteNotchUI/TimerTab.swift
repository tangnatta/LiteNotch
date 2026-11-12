import SwiftUI

/// Focus: the pomodoro timer, today's totals and the schedule in use.
/// Meeting: an agenda with a time box per item.
struct TimerTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SegmentedPill(options: [(TimerPane.focus, "Focus"), (TimerPane.meeting, "Meeting")],
                              selection: $model.timerPane, label: "Timer view")
                Spacer(minLength: 4)
                if model.timerPane == .meeting
                    && (vm.meeting.runState == .stopped || vm.meeting.runState == .unknown) {
                    MeetingPresets(m: vm.meeting, send: model.send)
                }
            }
            .frame(height: 24)
            switch model.timerPane {
            case .focus: focus
            case .meeting: MeetingPane(vm: vm, model: model)
            }
        }
    }

    private var focus: some View {
        HStack(alignment: .top, spacing: 12) {
            PomodoroCard(p: vm.pomodoro, send: model.send)
                .frame(width: 226)
            VStack(spacing: 10) {
                today
                schedule
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var today: some View {
        Card(padding: 12, expand: true) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Today")
                HStack(alignment: .top, spacing: 0) {
                    stat("\(vm.pomodoro.completedToday)",
                         vm.pomodoro.completedToday == 1 ? "focus session" : "focus sessions")
                    stat(Format.duration(secs: vm.pomodoro.focusSecsToday), "focused")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .foregroundStyle(NT.text1).lineLimit(1)
            Text(verbatim: caption).nfont(11).foregroundStyle(NT.text2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var schedule: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(text: "Schedule")
                    Spacer(minLength: 4)
                    TextPill(title: "Edit", tint: NT.text1, height: 22) { model.openSettings(.timer) }
                        .help("Open Settings \u{203A} Timer")
                }
                Text(verbatim: Format.schedule(vm.settings.pomodoro))
                    .nfont(11.5).foregroundStyle(NT.text2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                        .font(.system(size: 23, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(NT.text1)
                    Text(verbatim: p.runState == .paused ? "Paused" : Format.phaseLabel(p.phase))
                        .nfont(10.5, .medium).foregroundStyle(NT.text2)
                }
            }
            .frame(width: 96, height: 96)
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
            circleButton("forward.end.fill", label: "Skip", size: 28, fill: NT.fill, tint: NT.text2) {
                send(.pomodoroSkip)
            }
        }
    }

    private func circleButton(_ symbol: String, label: String, size: CGFloat, fill: Color,
                              tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
    }
}
