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
            // One list, not three cards: the now-playing card is the only
            // container on this screen.
            VStack(spacing: 0) {
                timerRow
                Hairline()
                agentsRow
                Hairline()
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
                                .nfont(.title).foregroundStyle(NT.text1)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            VText(m.artist.isEmpty ? m.app : m.artist)
                                .nfont(.body).foregroundStyle(NT.text2).lineLimit(1)
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
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: m.playing ? "play.fill" : "pause.fill")
                                    .glyph(9, .bold).foregroundStyle(NT.text3)
                                VText(m.playing ? "Playing in \(m.app)" : "Paused in \(m.app)")
                                    .nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
                            }
                            Text(verbatim: MediaText.notControllable)
                                .nfont(.caption).foregroundStyle(NT.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    MediaProgress(media: m, showTimes: false, height: 3)
                }
            } else {
                VStack(spacing: 6) {
                    ArtworkView(path: nil, size: 56, radius: 10, dimmed: true)
                    Text(verbatim: vm.settings.media.enabled ? "Nothing playing" : "Now playing is off")
                        .nfont(.emphasis).foregroundStyle(NT.text2)
                    Text(verbatim: vm.settings.media.enabled ? "Play something in Music, Spotify or a browser and it shows up here."
                                                             : "Turn it on in Settings \u{203A} Music.")
                        .nfont(.caption).foregroundStyle(NT.text3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
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
                    .nfont(.heading).monospacedDigit()
                    .foregroundStyle(NT.text1)
            }
            Text(verbatim: running ? "Timer" : "Timer paused")
                .nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
        } trailing: {
            Button { model.send(.timerToggle) } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .glyph(11, .bold).foregroundStyle(NT.onAccent)
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
            HStack(spacing: 6) {
                VText(running ? MeetingMath.currentItem(m)?.name ?? m.title : "Paused")
                    .nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: MeetingMath.position(m))
                    .nfont(.caption).monospacedDigit().foregroundStyle(NT.text3).lineLimit(1).fixedSize()
            }
        } trailing: {
            Button { model.send(.meetingToggle) } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .glyph(11, .bold).foregroundStyle(NT.onAccent)
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
        OverrunText(left: left, font: .heading)
    }

    private var pomodoroRow: some View {
        let p = vm.pomodoro
        let running = p.runState == .running
        return HomeRow(symbol: "timer", tint: p.phase == .focus ? NT.accent : NT.text2) {
            EverySecond { now in
                let left = running && p.endsAtMs != nil
                    ? Format.secondsLeft(until: p.endsAtMs ?? now, nowMs: now) : p.remainingSecs
                Text(verbatim: Format.countdown(seconds: left))
                    .nfont(.heading).monospacedDigit()
                    .foregroundStyle(NT.text1)
            }
            Text(verbatim: p.runState == .paused ? "Paused" : (p.phase == .idle ? "Timer ready" : Format.phaseLabel(p.phase)))
                .nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
        } trailing: {
            Button { model.send(.pomodoroToggle) } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .glyph(11, .bold).foregroundStyle(NT.onAccent)
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
        let detail = Format.agentsDetail(vm.usage)
        return HomeRow(symbol: "terminal", tint: waiting ? NT.accent : NT.text2) {
            VText(Format.agentsHeadline(vm.agents.sessions))
                .nfont(.emphasis).foregroundStyle(NT.text1).lineLimit(1)
            Text(verbatim: detail.tokens)
                .nfont(.caption).monospacedDigit().foregroundStyle(NT.text2).lineLimit(1)
        } trailing: {
            if let limit = detail.limit {
                Text(verbatim: limit)
                    .nfont(.caption).monospacedDigit().foregroundStyle(NT.text3).lineLimit(1).fixedSize()
                    .help("Share of the 5-hour usage limit used")
            }
            Chevron()
        }
        .opens(.agents, "Agents", model)
    }

    private var inboxRow: some View {
        let latest = vm.inbox.banner ?? vm.inbox.history.first
        let now = nowMs(Date(), offset: offset)
        return HomeRow(symbol: "bell", tint: vm.inbox.unread > 0 ? NT.accent : NT.text2) {
            if let n = latest {
                VText(n.title).nfont(.emphasis).foregroundStyle(NT.text1).lineLimit(1)
                VText(Format.sourceTag(n.source) ?? "LiteNotch").nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
            } else {
                Text(verbatim: "No notifications").nfont(.emphasis).foregroundStyle(NT.text2)
                Text(verbatim: "You\u{2019}re all caught up").nfont(.caption).foregroundStyle(NT.text3)
            }
        } trailing: {
            if let n = latest {
                Text(verbatim: Format.relative(from: n.createdMs, nowMs: now))
                    .nfont(.caption).foregroundStyle(NT.text3).lineLimit(1).fixedSize()
            }
            if vm.inbox.unread > 0 {
                Text(verbatim: vm.inbox.unread > 9 ? "9+" : "\(vm.inbox.unread)")
                    .nfont(.badge)
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
        Image(systemName: "chevron.right").glyph(NGlyph.small)
            .foregroundStyle(NT.text3)
            .accessibilityHidden(true)
    }
}

/// Icon, two lines, something on the right; one row of the Home list.
private struct HomeRow<Lines: View, Trailing: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var lines: Lines
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .glyph(NGlyph.regular).foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) { lines }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rowHover()
    }
}

private extension View {
    /// Makes a whole block jump to `tab`. Buttons inside keep their own clicks.
    func opens(_ tab: Tab, _ name: String, _ model: PanelState) -> some View {
        opens(name, model) { model.selectTab(tab) }
    }

    func opens(_ name: String, _ model: PanelState, _ go: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: go)
            .help("Open \(name)")
            .accessibilityAction(named: Text(verbatim: "Open \(name)"), go)
    }
}
