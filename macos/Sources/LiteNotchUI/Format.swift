import Foundation

/// Text formatting shared by the views; pure so it can be unit tested.
public enum Format {
    /// Same shape as the core's `mmss`: `0:00`, `1:05`, `60:00`.
    /// A typed timer length in seconds, or nil if it makes no sense.
    /// `25` is minutes; `1:30` is minutes and seconds; `1:05:00` adds hours;
    /// units also work: `90s`, `45m`, `1h`, `1h 30m`, `2m30s`.
    /// The result is between 1 second and 24 hours.
    public static func parseDuration(_ text: String) -> Int? {
        let s = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        var total = 0
        if s.allSatisfy({ $0.isNumber || $0 == ":" }) {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.contains(where: { $0 == nil }) else { return nil }
            let n = parts.compactMap { $0 }
            switch n.count {
            case 1: total = n[0] * 60
            case 2: guard n[1] < 60 else { return nil }; total = n[0] * 60 + n[1]
            case 3: guard n[1] < 60, n[2] < 60 else { return nil }; total = n[0] * 3600 + n[1] * 60 + n[2]
            default: return nil
            }
        } else {
            var number = ""
            var seen = Set<Character>()
            for c in s {
                if c.isNumber { number.append(c); continue }
                guard let value = Int(number), "hms".contains(c), !seen.contains(c) else { return nil }
                seen.insert(c)
                total += value * (c == "h" ? 3600 : c == "m" ? 60 : 1)
                number = ""
            }
            // A trailing bare number after hours means minutes: `1h30`.
            if !number.isEmpty {
                guard let value = Int(number), seen.contains("h"), !seen.contains("m") else { return nil }
                total += value * 60
            }
        }
        return (1...86_400).contains(total) ? total : nil
    }

    /// `1 min`, `30 min`, `1 h`, `1 h 30 min`.
    public static func timerPreset(_ secs: Int) -> String {
        let h = secs / 3600, m = secs / 60 % 60
        if h == 0 { return secs >= 60 ? "\(m) min" : "\(secs) s" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Tooltip for something clickable that goes to `target`.
    public static func openHelp(_ target: OpenTarget?) -> String {
        switch target {
        case .app?, .appNamed?: return "Open the app"
        case .tab(let t, _)?: return "Open \(t.rawValue.capitalized)"
        case nil: return ""
        }
    }

    public static func countdown(seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Whole seconds left until `endMs`, rounded up like the core does.
    public static func secondsLeft(until endMs: Int, nowMs: Int) -> Int {
        max(0, (endMs - nowMs + 999) / 1000)
    }

    /// `just now`, `5m ago`, `3h ago`, `2d ago`.
    public static func relative(from ms: Int, nowMs: Int) -> String {
        let s = max(0, (nowMs - ms) / 1000)
        switch s {
        case ..<45: return "just now"
        case ..<3600: return "\(max(1, (s + 30) / 60))m ago"
        case ..<86_400: return "\(s / 3600)h ago"
        default: return "\(s / 86_400)d ago"
        }
    }

    /// `resets in 2h 14m`, `resets in 5m`, `resets in 3d 4h`.
    public static func resetsIn(resetsAtMs: Int, nowMs: Int) -> String {
        let s = (resetsAtMs - nowMs) / 1000
        if s <= 0 { return "resetting now" }
        let minutes = (s + 59) / 60
        if minutes < 60 { return "resets in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m == 0 ? "resets in \(hours)h" : "resets in \(hours)h \(m)m"
        }
        let d = hours / 24, h = hours % 24
        return h == 0 ? "resets in \(d)d" : "resets in \(d)d \(h)h"
    }

    /// Compact token count: 950, 12.3k, 4.2M.
    public static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k")
        default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    public static func percent(_ v: Double) -> String {
        "\(Int(max(0, v).rounded()))%"
    }

    public static func phaseLabel(_ p: Phase) -> String {
        switch p {
        case .idle, .unknown: return "Pomodoro"
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long break"
        }
    }

    /// `agent_request` becomes `Agent request`.
    public static func featureName(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    public static func statusLabel(_ s: AgentStatus) -> String {
        switch s {
        case .working: return "Working"
        case .waitingApproval: return "Needs approval"
        case .waitingInput: return "Needs input"
        case .idle: return "Idle"
        case .ended: return "Ended"
        case .unknown: return "Unknown"
        }
    }

    /// Fraction of a media track played, extrapolated while playing.
    public static func mediaPosition(_ m: MediaView, nowMs: Int) -> Int? {
        guard let p = m.positionMs else { return nil }
        let elapsed = m.playing ? max(0, nowMs - m.positionAtMs) : 0
        let pos = p + elapsed
        if let d = m.durationMs, d > 0 { return min(pos, d) }
        return pos
    }

    public static func clock(ms: Int) -> String { countdown(seconds: ms / 1000) }

    /// `25 min focus · 5 min break · long break 15 min every 4`.
    public static func schedule(_ p: PomodoroConfig) -> String {
        "\(p.focusSecs / 60) min focus \u{00B7} \(p.shortBreakSecs / 60) min break \u{00B7} "
            + "long break \(p.longBreakSecs / 60) min every \(p.roundsBeforeLong)"
    }

    /// `0m`, `45m`, `1h 20m`, `2h`.
    public static func duration(secs: Int) -> String {
        let m = max(0, secs) / 60
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// First letter of the weekday a usage day falls on. The middle of the
    /// day is used so a small clock-offset mismatch cannot shift the day.
    public static func weekdayInitial(dayStartMs: Int, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(dayStartMs) / 1000 + 12 * 3600)
        let index = calendar.component(.weekday, from: date) - 1
        let names = ["S", "M", "T", "W", "T", "F", "S"]
        return names.indices.contains(index) ? names[index] : ""
    }

    /// Sessions that are still going (anything but ended).
    public static func activeSessions(_ sessions: [AgentSession]) -> Int {
        sessions.filter { $0.status != .ended && $0.status != .unknown }.count
    }

    /// One line for the Home tab: who is waiting, else how many are active.
    public static func agentsHeadline(_ sessions: [AgentSession]) -> String {
        if let s = sessions.first(where: { $0.status == .waitingApproval }) {
            return "\(s.project) needs approval"
        }
        if let s = sessions.first(where: { $0.status == .waitingInput }) {
            return "\(s.project) needs input"
        }
        let n = activeSessions(sessions)
        switch n {
        case 0: return "No active sessions"
        case 1: return "1 active session"
        default: return "\(n) active sessions"
        }
    }

    /// `5-hour 42% · 184.6k tokens today`.
    public static func agentsDetail(_ u: UsageSnapshot) -> String {
        var parts: [String] = []
        if let w = u.fiveHour { parts.append("5-hour \(percent(w.usedPct))") }
        let today = u.today.input + u.today.output
        if today > 0 || parts.isEmpty { parts.append("\(tokens(today)) tokens today") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// False when the token breakdown has nothing to draw.
    public static func hasTokenData(_ u: UsageSnapshot) -> Bool {
        u.week.contains { $0.tokens > 0 } || !u.models.isEmpty || !u.projects.isEmpty
            || u.today.input + u.today.output > 0
    }
}

/// Decisions about approval prompts. Kept out of the views so the safety rules
/// are unit tested.
public struct ApprovalPresentation: Equatable {
    public let showAllow: Bool
    public let showTruncatedNotice: Bool
    public let detail: String
    public let summary: String
    public static let truncatedNotice = "Command too long to review here \u{2014} answer in the terminal"

    public init(_ r: PermissionRequest) {
        showAllow = !r.truncated
        showTruncatedNotice = r.truncated
        detail = ApprovalPresentation.visible(r.detail)
        summary = ApprovalPresentation.visible(r.summary)
    }

    /// Decisions the UI may offer. Allow is never offered for a truncated
    /// command; Deny and Pass always are.
    public var offeredDecisions: [Decision] {
        showAllow ? [.deny, .pass, .allow] : [.deny, .pass]
    }

    /// Replaces bidirectional-override and other invisible formatting scalars
    /// so a command cannot be visually reordered to disguise what it does.
    public static func visible(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200F, 0x2060, 0xFEFF:
                out.append("\u{FFFD}")
            default:
                out.append(u)
            }
        }
        return String(out)
    }
}
