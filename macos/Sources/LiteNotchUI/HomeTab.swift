import SwiftUI

/// At-a-glance dashboard: now playing on the left, then timer, agents and
/// inbox. Every block opens its tab; nothing else lives here.
struct HomeTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState
    @Environment(\.clockOffsetMs) private var offset

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            nowPlaying
                .frame(width: 236)
            VStack(spacing: 8) {
                timerRow
                agentsRow
                inboxRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        Card(padding: 12, expand: true) {
            if let m = vm.media {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        ArtworkView(path: m.artworkPath, size: 56, radius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            VText(m.title.isEmpty ? "Unknown title" : m.title)
                                .nfont(13, .semibold).foregroundStyle(NT.text1)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            VText(m.artist.isEmpty ? m.app : m.artist)
                                .nfont(11.5).foregroundStyle(NT.text2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    if m.controllable {
                        MediaControls(media: m, size: 34, spacing: 12, send: model.send)
                            .frame(maxWidth: .infinity)
                    } else {
                        // No controls for this player: say what is playing
                        // where, instead of leaving a hole.
                        HStack(spacing: 6) {
                            Image(systemName: m.playing ? "play.fill" : "pause.fill")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(NT.text3)
                            VText(m.playing ? "Playing in \(m.app)" : "Paused in \(m.app)")
                                .nfont(11).foregroundStyle(NT.text2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    MediaProgress(media: m, showTimes: false, height: 3)
                }
            } else {
                VStack(spacing: 8) {
                    ArtworkView(path: nil, size: 56, radius: 10, dimmed: true)
                    Text(verbatim: vm.settings.media.enabled ? "Nothing playing" : "Now playing is off")
                        .nfont(12).foregroundStyle(NT.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opens(.music, "Music", model)
    }

    // MARK: Rows

    @ViewBuilder private var timerRow: some View {
        if MeetingMath.isActive(vm.meeting) {
            meetingRow
        } else if vm.timer.isActive {
            countdownRow
        } else {
            pomodoroRow
        }
    }

    /// Replaces the pomodoro while the plain timer is running or paused.
    private var countdownRow: some View {
        let t = vm.timer
        let running = t.runState == .running
        return HomeRow(symbol: "hourglass", tint: NT.accent) {
            EverySecond { now in
                let left = running && t.endsAtMs != nil
                    ? Format.secondsLeft(until: t.endsAtMs ?? now, nowMs: now) : t.remainingSecs
                Text(verbatim: Format.countdown(seconds: left))
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(NT.text1)
            }
            Text(verbatim: running ? "Timer" : "Timer paused")
                .nfont(11).foregroundStyle(NT.text2).lineLimit(1)
        } trailing: {
            Button { model.send(.timerToggle) } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(NT.onAccent)
                    .frame(width: 28, height: 28)
                    .background(NT.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: running ? "Pause timer" : "Resume timer"))
        }
        .opens("Timer", model) { model.openTimer(.countdown) }
    }

    /// Replaces the pomodoro while a meeting is running or paused.
    private var meetingRow: some View {
        let m = vm.meeting
        let running = m.runState == .running
        return HomeRow(symbol: "person.2.fill", tint: NT.accent) {
            if running {
                EverySecond { now in meetingClock(MeetingMath.currentLeft(m, nowMs: now)) }
            } else {
                meetingClock(MeetingMath.currentLeft(m, nowMs: 0))
            }
            VText([running ? MeetingMath.currentItem(m)?.name ?? m.title : "Paused", MeetingMath.position(m)]
                    .joined(separator: " \u{00B7} "))
                .nfont(11).foregroundStyle(NT.text2).lineLimit(1)
        } trailing: {
            Button { model.send(.meetingToggle) } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(NT.onAccent)
                    .frame(width: 28, height: 28)
                    .background(NT.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: running ? "Pause meeting" : "Resume meeting"))
        }
        .opens("Meeting", model) { model.openTimer(.meeting) }
    }

    private func meetingClock(_ left: Int) -> some View {
        Text(verbatim: Format.signedCountdown(left))
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .foregroundStyle(left < 0 ? NT.deny : NT.text1)
    }

    private var pomodoroRow: some View {
        let p = vm.pomodoro
        let running = p.runState == .running
        return HomeRow(symbol: "timer", tint: p.phase == .focus ? NT.accent : NT.text2) {
            EverySecond { now in
                let left = running && p.endsAtMs != nil
                    ? Format.secondsLeft(until: p.endsAtMs ?? now, nowMs: now) : p.remainingSecs
                Text(verbatim: Format.countdown(seconds: left))
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(NT.text1)
            }
            Text(verbatim: p.runState == .paused ? "Paused" : (p.phase == .idle ? "Timer ready" : Format.phaseLabel(p.phase)))
                .nfont(11).foregroundStyle(NT.text2).lineLimit(1)
        } trailing: {
            Button { model.send(.pomodoroToggle) } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(NT.onAccent)
                    .frame(width: 28, height: 28)
                    .background(NT.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: running ? "Pause timer" : "Start timer"))
        }
        .opens("Timer", model) { model.openTimer(.focus) }
    }

    private var agentsRow: some View {
        let waiting = vm.agents.sessions.contains { $0.status == .waitingApproval || $0.status == .waitingInput }
        return HomeRow(symbol: "sparkles", tint: waiting ? NT.accent : NT.text2) {
            VText(Format.agentsHeadline(vm.agents.sessions))
                .nfont(12.5, .semibold).foregroundStyle(NT.text1).lineLimit(1)
            Text(verbatim: Format.agentsDetail(vm.usage))
                .nfont(11).monospacedDigit().foregroundStyle(NT.text2).lineLimit(1)
        } trailing: {
            Chevron()
        }
        .opens(.agents, "Agents", model)
    }

    private var inboxRow: some View {
        let latest = vm.inbox.banner ?? vm.inbox.history.first
        let now = nowMs(Date(), offset: offset)
        return HomeRow(symbol: "bell", tint: vm.inbox.unread > 0 ? NT.accent : NT.text2) {
            if let n = latest {
                VText(n.title).nfont(12.5, .semibold).foregroundStyle(NT.text1).lineLimit(1)
                VText([n.source, Format.relative(from: n.createdMs, nowMs: now)].joined(separator: " \u{00B7} "))
                    .nfont(11).foregroundStyle(NT.text2).lineLimit(1)
            } else {
                Text(verbatim: "No notifications").nfont(12.5, .semibold).foregroundStyle(NT.text2)
                Text(verbatim: "You are all caught up").nfont(11).foregroundStyle(NT.text3)
            }
        } trailing: {
            if vm.inbox.unread > 0 {
                Text(verbatim: vm.inbox.unread > 9 ? "9+" : "\(vm.inbox.unread)")
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .foregroundStyle(NT.onAccent)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(NT.accent, in: Capsule())
                    .accessibilityLabel(Text(verbatim: "\(vm.inbox.unread) unread"))
            } else {
                Chevron()
            }
        }
        .opens(.inbox, "Inbox", model)
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NT.text3)
            .accessibilityHidden(true)
    }
}

/// Icon tile, two lines, something on the right.
private struct HomeRow<Lines: View, Trailing: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var lines: Lines
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(NT.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) { lines }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NT.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension View {
    /// Makes a whole block jump to `tab`. Buttons inside keep their own clicks.
    func opens(_ tab: Tab, _ name: String, _ model: PanelState) -> some View {
        opens(name, model) { model.selectTab(tab) }
    }

    func opens(_ name: String, _ model: PanelState, _ go: @escaping () -> Void) -> some View {
        contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture(perform: go)
            .accessibilityAction(named: Text(verbatim: "Open \(name)"), go)
    }
}
