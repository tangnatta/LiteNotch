import SwiftUI

struct AgentsTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState
    @Environment(\.clockOffsetMs) private var offset

    private var send: (ShellCommand) -> Void { model.send }
    private var anyConnected: Bool { AgentsText.anyConnected(vm.agents) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SegmentedPill(
                    options: [(AgentsPane.sessions, "Sessions"), (AgentsPane.usage, "Usage")],
                    selection: $model.agentsPane, label: "Agents view")
                Spacer(minLength: 4)
                // Disconnecting lives in Settings › Agents; here only the way in.
                if model.agentsPane == .sessions && !anyConnected && !vm.agents.sessions.isEmpty {
                    connectButton
                }
            }
            .frame(height: 24)
            switch model.agentsPane {
            case .sessions:
                if vm.agents.sessions.isEmpty {
                    empty
                } else {
                    sessions
                }
            case .usage:
                UsagePane(usage: vm.usage, statusline: vm.agents.statuslineInstalled, send: send)
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if anyConnected {
            EmptyState(
                symbol: "terminal", title: "No sessions yet",
                hint: "Start a connected agent in a terminal and it shows up here.")
        } else {
            EmptyState(
                symbol: "terminal", title: "No coding agent connected",
                hint: "Connect Claude Code, Codex, Gemini CLI or Antigravity to see their sessions here."
            ) {
                connectButton
            }
        }
    }

    private var connectButton: some View {
        TextPill(title: "Connect an agent", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
            model.openSettings(.agents)
        }
        .help("Opens Settings \u{203A} Agents, with every agent LiteNotch can connect to")
    }

    private var sessions: some View {
        let now = nowMs(Date(), offset: offset)
        return NotchScroll {
            ForEach(Array(vm.agents.sessions.enumerated()), id: \.element.id) { i, s in
                Button {
                    model.openSession(s)
                } label: {
                    SessionRow(session: s, now: now)
                }
                .buttonStyle(.plain)
                .rowHover()
                .help(s.app == nil ? "Its terminal is not known yet" : "Show this session\u{2019}s window")
                if i < vm.agents.sessions.count - 1 { Hairline().padding(.horizontal, 6) }
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, -6)
    }
}

/// Project, state and age; under them which agent it is and its last words.
struct SessionRow: View {
    let session: AgentSession
    let now: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                VText(session.project).nfont(.emphasis).foregroundStyle(NT.text1).lineLimit(1)
                StatusChip(status: session.status)
                Spacer(minLength: 0)
                Text(verbatim: Format.relative(from: session.lastEventMs, nowMs: now))
                    .nfont(.caption).foregroundStyle(NT.text3)
                if session.app != nil {
                    Image(systemName: "arrow.up.forward").glyph(9)
                        .foregroundStyle(NT.text3)
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: Format.agentName(sessionId: session.id))
                    .nfont(.captionStrong).foregroundStyle(NT.text3).fixedSize()
                if let m = session.lastMessage, !m.isEmpty {
                    VText(m).nfont(.body).foregroundStyle(NT.text2).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct StatusChip: View {
    let status: AgentStatus

    var body: some View {
        let label = Format.statusLabel(status)
        switch status {
        case .waitingApproval:
            chip(label, fg: NT.onAccent, bg: NT.accent, stroke: nil)
        case .waitingInput:
            chip(label, fg: NT.accentText, bg: .clear, stroke: NT.accent)
        case .working:
            chip(label, fg: NT.text1, bg: NT.fillHi, stroke: nil)
        default:
            chip(label, fg: NT.text3, bg: NT.fill, stroke: nil)
        }
    }

    private func chip(_ t: String, fg: Color, bg: Color, stroke: Color?) -> some View {
        Text(verbatim: t).nfont(.captionStrong).foregroundStyle(fg)
            .padding(.horizontal, 7).frame(height: 17)
            .background(bg, in: Capsule())
            .overlay { if let s = stroke { Capsule().stroke(s, lineWidth: 1) } }
    }
}

// MARK: - Usage

enum UsageText {
    static let offer = "Show your Claude Code usage limits here."
    static let waiting = "Usage limits appear after your next Claude Code message."
    static let tokensHint = "Token totals appear after your first Claude Code message today."
    static let codexWaiting = "Limits reset. They update after Codex\u{2019}s next reply."
}

/// Limits on the left, one group per agent that reports them; Claude
/// Code's tokens this week on the right.
struct UsagePane: View {
    let usage: UsageSnapshot
    /// Whether LiteNotch is Claude Code's status line; nil when unknown.
    var statusline: Bool?
    var send: (ShellCommand) -> Void = { _ in }
    @Environment(\.clockOffsetMs) private var offset

    private var hasClaudeLimits: Bool { usage.fiveHour != nil || usage.sevenDay != nil }
    private var hasCodexLimits: Bool { usage.codex?.primary != nil || usage.codex?.secondary != nil }

    var body: some View {
        if !hasClaudeLimits && !hasCodexLimits && !Format.hasTokenData(usage) {
            if statusline == true {
                EmptyState(
                    symbol: "chart.bar", title: "No usage yet",
                    hint: "\(UsageText.waiting)\n\(UsageText.tokensHint)"
                )
                .padding(.horizontal, 40)
            } else {
                EmptyState(symbol: "chart.bar", title: "No usage yet", hint: UsageText.offer) {
                    showLimitsButton
                }
                .padding(.horizontal, 40)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                limits.frame(width: 220)
                breakdown.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Limits

    private var limits: some View {
        Card(padding: 12, expand: true) {
            let now = nowMs(Date(), offset: offset)
            NotchScroll {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionLabel(text: "Claude Code")
                        if let w = usage.fiveHour {
                            windowRow("5-hour", w.usedPct, w.resetsAtMs, now)
                        }
                        if let w = usage.sevenDay {
                            windowRow("7-day", w.usedPct, w.resetsAtMs, now)
                        }
                        if !hasClaudeLimits {
                            Text(verbatim: statusline == true ? UsageText.waiting : UsageText.offer)
                                .nfont(.caption).foregroundStyle(NT.text3).fixedSize(horizontal: false, vertical: true)
                            if statusline != true { showLimitsButton }
                        }
                    }
                    if let codex = usage.codex, hasCodexLimits {
                        let windows = [codex.primary, codex.secondary].compactMap { $0 }
                        VStack(alignment: .leading, spacing: 7) {
                            SectionLabel(text: "Codex")
                            // Readings come only with Codex's replies: after
                            // a quiet spell every window has reset since.
                            if windows.allSatisfy({ ($0.resetsAtMs ?? Int.max) <= now }) {
                                Text(verbatim: UsageText.codexWaiting)
                                    .nfont(.caption).foregroundStyle(NT.text3)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                                    windowRow(Format.windowName(minutes: w.windowMins), w.usedPct, w.resetsAtMs, now)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var showLimitsButton: some View {
        TextPill(title: "Show usage limits", tint: NT.onAccent, background: NT.accent, height: 24, weight: .semibold) {
            send(.statuslineInstall)
        }
        .help("Makes LiteNotch Claude Code\u{2019}s status line, keeping the one you have")
    }

    private func tint(_ pct: Double) -> Color {
        pct >= 95 ? NT.deny : (pct >= 80 ? NT.accent : NT.text1)
    }

    /// One line (name, reset, share) over a thin bar. A window whose reset
    /// time has passed shows as reset: its share is from before.
    private func windowRow(_ title: String, _ pct: Double, _ resetsAt: Int?, _ now: Int) -> some View {
        let reset = resetsAt.map { $0 <= now } ?? false
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: title).nfont(.bodyMedium).foregroundStyle(NT.text2)
                if let r = resetsAt {
                    Text(verbatim: reset ? "reset" : Format.resetsIn(resetsAtMs: r, nowMs: now))
                        .nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(verbatim: reset ? "\u{2013}" : Format.percent(pct)).nfont(.emphasis).monospacedDigit()
                    .foregroundStyle(NT.text1)
            }
            ProgressBar(value: reset ? 0 : pct / 100, tint: tint(pct))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Breakdown

    @ViewBuilder private var breakdown: some View {
        if Format.hasTokenData(usage) {
            VStack(alignment: .leading, spacing: 8) {
                // Today's total is the number on the last bar.
                SectionLabel(text: "Claude Code tokens this week")
                if !usage.week.isEmpty {
                    WeekChart(days: usage.week)
                }
                HStack(alignment: .top, spacing: 16) {
                    shares("By model", usage.models)
                    shares("By project", usage.projects)
                }
            }
        } else {
            Text(verbatim: UsageText.tokensHint)
                .nfont(.body).foregroundStyle(NT.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
        }
    }

    private func shares(_ title: String, _ items: [UsageShare]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: title)
            if items.isEmpty {
                Text(verbatim: "Nothing yet today").nfont(.caption).foregroundStyle(NT.text3)
            }
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, s in
                HStack(spacing: 6) {
                    VText(s.name).nfont(.caption).foregroundStyle(NT.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: Format.tokens(s.tokens)).nfont(.caption).monospacedDigit()
                        .foregroundStyle(NT.text1).lineLimit(1).fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Seven bars, oldest first; today is the last one and the only one with a
/// number on it.
struct WeekChart: View {
    let days: [UsageDay]
    var barHeight: CGFloat = 34

    var body: some View {
        let peak = max(1, days.map(\.tokens).max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                let today = i == days.count - 1
                VStack(spacing: 3) {
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        if today {
                            Text(verbatim: Format.tokens(d.tokens))
                                .nfont(.captionStrong).monospacedDigit()
                                .foregroundStyle(NT.accentText).lineLimit(1).fixedSize()
                        }
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(today ? NT.accent : NT.text1.opacity(d.tokens > 0 ? 0.30 : 0.12))
                            .frame(height: max(2, barHeight * CGFloat(d.tokens) / CGFloat(peak)))
                    }
                    .frame(height: barHeight + 13)
                    Text(verbatim: Format.weekdayInitial(dayStartMs: d.dayStartMs))
                        .nfont(today ? .captionStrong : .caption)
                        .foregroundStyle(today ? NT.text1 : NT.text3)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: today ? "Today" : Format.weekdayInitial(dayStartMs: d.dayStartMs)))
                .accessibilityValue(Text(verbatim: "\(Format.tokens(d.tokens)) tokens, \(d.messages) messages"))
            }
        }
    }
}
