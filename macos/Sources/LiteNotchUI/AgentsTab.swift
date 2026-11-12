import SwiftUI

struct AgentsTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState
    @Environment(\.clockOffsetMs) private var offset

    private var send: (ShellCommand) -> Void { model.send }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SegmentedPill(options: [(AgentsPane.sessions, "Sessions"), (AgentsPane.usage, "Usage")],
                              selection: $model.agentsPane, label: "Agents view")
                Spacer(minLength: 4)
            }
            .frame(height: 24)
            switch model.agentsPane {
            case .sessions:
                if vm.agents.sessions.isEmpty && !(vm.agents.hooksInstalled ?? false) {
                    EmptyState(symbol: "terminal", title: "Not connected to Claude Code",
                               hint: "Connect it, then start Claude Code in a terminal to see its sessions and approve its requests here.") {
                        connectButton
                    }
                } else {
                    hooksLine
                    sessions
                }
            case .usage:
                UsagePane(usage: vm.usage, statusline: vm.agents.statuslineInstalled, send: send)
            }
        }
    }

    @ViewBuilder private var hooksLine: some View {
        let installed = vm.agents.hooksInstalled ?? false
        HStack(spacing: 8) {
            Image(systemName: installed ? "checkmark.circle" : "link.badge.plus")
                .glyph(11)
                .foregroundStyle(installed ? NT.text3 : NT.accentText)
            Text(verbatim: installed
                 ? "Connected to Claude Code"
                 : "Connect Claude Code to see its sessions and approve requests here.")
                .nfont(.body).foregroundStyle(installed ? NT.text3 : NT.text2).lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 4)
            if installed {
                TextPill(title: "Disconnect", tint: NT.text2, height: 22) { send(.hooksUninstall) }
                    .help("Stop sending Claude Code sessions to LiteNotch")
            } else {
                connectButton
            }
        }
        .frame(height: 24)
    }

    private var connectButton: some View {
        TextPill(title: "Connect Claude Code", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
            send(.hooksInstall)
        }
        .help("Adds LiteNotch to Claude Code\u{2019}s settings. New sessions show up here.")
    }

    private var sessions: some View {
        let now = nowMs(Date(), offset: offset)
        return Group {
            if vm.agents.sessions.isEmpty {
                EmptyState(symbol: "terminal", title: "No sessions",
                           hint: "Start Claude Code in a terminal to see it here.")
            } else {
                NotchScroll {
                    ForEach(Array(vm.agents.sessions.enumerated()), id: \.element.id) { i, s in
                        Button { model.openSession(s) } label: {
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
    }
}

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
            if let m = session.lastMessage, !m.isEmpty {
                VText(m).nfont(.body).foregroundStyle(NT.text2).lineLimit(1)
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
}

/// Rate limits on the left; the summary, the week and today's breakdown on
/// the right.
struct UsagePane: View {
    let usage: UsageSnapshot
    /// Whether LiteNotch is Claude Code's status line; nil when unknown.
    var statusline: Bool?
    var send: (ShellCommand) -> Void = { _ in }
    @Environment(\.clockOffsetMs) private var offset

    private var hasLimits: Bool { usage.fiveHour != nil || usage.sevenDay != nil }

    var body: some View {
        if !hasLimits && !Format.hasTokenData(usage) {
            if statusline == true {
                EmptyState(symbol: "chart.bar", title: "No usage yet",
                           hint: "\(UsageText.waiting)\n\(UsageText.tokensHint)")
                    .padding(.horizontal, 40)
            } else {
                EmptyState(symbol: "chart.bar", title: "No usage yet", hint: UsageText.offer) {
                    showLimitsButton
                }
                .padding(.horizontal, 40)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                limits.frame(width: 196)
                breakdown.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Limits

    private var limits: some View {
        Card(padding: 12, expand: true) {
            let now = nowMs(Date(), offset: offset)
            VStack(alignment: .leading, spacing: 10) {
                if !hasLimits {
                    Text(verbatim: statusline == true ? UsageText.waiting : UsageText.offer)
                        .nfont(.caption).foregroundStyle(NT.text3).fixedSize(horizontal: false, vertical: true)
                    if statusline != true { showLimitsButton }
                }
                if let w = usage.fiveHour { windowRow("5-hour", w, now) }
                if let w = usage.sevenDay { windowRow("7-day", w, now) }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    stat("Today", "\(Format.tokens(usage.today.input + usage.today.output)) tokens")
                    if let c = usage.contextPct { stat("Conversation", "\(Format.percent(c)) full") }
                    if let m = usage.model { stat("Model", m) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func windowRow(_ title: String, _ w: RateWindow, _ now: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title).nfont(.bodyMedium).foregroundStyle(NT.text2)
                Spacer()
                Text(verbatim: Format.percent(w.usedPct)).nfont(.emphasis).monospacedDigit()
                    .foregroundStyle(NT.text1)
            }
            ProgressBar(value: w.usedPct / 100, tint: tint(w.usedPct))
            if let r = w.resetsAtMs {
                Text(verbatim: Format.resetsIn(resetsAtMs: r, nowMs: now).capitalizedFirst).nfont(.caption).foregroundStyle(NT.text3)
            }
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack {
            Text(verbatim: k).nfont(.caption).foregroundStyle(NT.text3)
            Spacer(minLength: 6)
            VText(v).nfont(.caption).monospacedDigit().foregroundStyle(NT.text2).lineLimit(1)
        }
    }

    // MARK: Breakdown

    @ViewBuilder private var breakdown: some View {
        if Format.hasTokenData(usage) {
            VStack(alignment: .leading, spacing: 8) {
                if !usage.summary.isEmpty {
                    VText(usage.summary).nfont(.body).foregroundStyle(NT.text1)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
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
            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, s in
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
