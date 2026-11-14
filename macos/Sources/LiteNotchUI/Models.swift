import Foundation

// Mirrors `crates/core/src/state.rs`. Keys are snake_case on the wire; the
// shared `ViewModel.decoder` / `encoder` convert to and from camelCase.

// MARK: - Lenient enums

/// Decoding an unrecognised string yields `.unknown` instead of throwing, so a
/// newer core can never crash an older shell.
protocol LenientEnum: RawRepresentable, Codable, Equatable where RawValue == String {
    static var unknownCase: Self { get }
}

private func decodeLenient<E: LenientEnum>(_ decoder: Decoder) throws -> E {
    let raw = try decoder.singleValueContainer().decode(String.self)
    return E(rawValue: raw) ?? E.unknownCase
}

public enum ActivityKind: String, LenientEnum {
    case idle, approval, banner, pomodoro, media, caffeine, agent, meeting, timer, unknown
    static var unknownCase: ActivityKind { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum Phase: String, LenientEnum {
    case idle, focus
    case shortBreak = "short_break"
    case longBreak = "long_break"
    case unknown
    static var unknownCase: Phase { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum RunState: String, LenientEnum {
    case stopped, running, paused, unknown
    static var unknownCase: RunState { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum ClipKind: String, LenientEnum {
    case text, files, image, unknown
    static var unknownCase: ClipKind { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum Priority: String, LenientEnum {
    case low, normal, high, critical, unknown
    static var unknownCase: Priority { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum AwakeMode: String, LenientEnum {
    case off, system, display, unknown
    static var unknownCase: AwakeMode { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum LidState: String, LenientEnum {
    case off, pending, on, unknown
    static var unknownCase: LidState { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum AgentStatus: String, LenientEnum {
    case working
    case waitingApproval = "waiting_approval"
    case waitingInput = "waiting_input"
    case idle, ended, unknown
    static var unknownCase: AgentStatus { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum Decision: String, Codable, Equatable {
    case allow, deny, pass
}

public enum MediaAction: String, Codable, Equatable {
    case playPause = "play_pause"
    case next, previous
}

public enum Tab: String, Codable, CaseIterable, Equatable {
    case home, music, timer, clipboard, agents, inbox, settings
}

// MARK: - Settings (sent back whole, so every field is mirrored)

public struct GeneralSettings: Codable, Equatable {
    public var persistClipboard: Bool
    public var hoverToExpand: Bool
    public var usageAlerts: Bool
    /// One notch per display instead of only the built-in (or main) one.
    public var allScreens: Bool
}

extension GeneralSettings {
    // `all_screens` is newer than the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        persistClipboard = try c.decode(Bool.self, forKey: .persistClipboard)
        hoverToExpand = try c.decode(Bool.self, forKey: .hoverToExpand)
        usageAlerts = try c.decode(Bool.self, forKey: .usageAlerts)
        allScreens = (try? c.decodeIfPresent(Bool.self, forKey: .allScreens)) ?? false
    }
}

public enum ThemeChoice: String, LenientEnum {
    case system, dark, light, unknown
    static var unknownCase: ThemeChoice { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// What the open panel is drawn with (`appearance.material`). Glass is the
/// macOS 26 Liquid Glass material; see `GlassSupport`.
public enum MaterialChoice: String, LenientEnum {
    case solid, glass, unknown
    static var unknownCase: MaterialChoice { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public struct AppearanceConfig: Codable, Equatable {
    public var theme: ThemeChoice
    /// `#RRGGBB`; anything unparsable falls back to the default accent.
    public var accent: String
    public var material: MaterialChoice

    enum CodingKeys: String, CodingKey { case theme, accent, material }

    public static let defaultAccent = "#FF9E0A"
    public static let `default` = AppearanceConfig(theme: .system, accent: defaultAccent)

    public init(theme: ThemeChoice, accent: String, material: MaterialChoice = .solid) {
        self.theme = theme
        self.accent = accent
        self.material = material
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decodeIfPresent(ThemeChoice.self, forKey: .theme)) ?? .system
        accent = (try? c.decodeIfPresent(String.self, forKey: .accent)) ?? Self.defaultAccent
        material = (try? c.decodeIfPresent(MaterialChoice.self, forKey: .material)) ?? .solid
    }

    // An unknown theme or material is left out so the core keeps its own value.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if theme != .unknown { try c.encode(theme, forKey: .theme) }
        try c.encode(accent, forKey: .accent)
        if material != .unknown { try c.encode(material, forKey: .material) }
    }

    /// Whether the open panel is drawn with Liquid Glass: chosen, and this
    /// build and system can draw it.
    public var usesGlass: Bool { material == .glass && GlassSupport.available }
}

public struct PomodoroConfig: Codable, Equatable {
    public var focusSecs: Int
    public var shortBreakSecs: Int
    public var longBreakSecs: Int
    public var roundsBeforeLong: Int
    public var autoStartBreaks: Bool
    public var autoStartFocus: Bool
    public var utcOffsetSecs: Int
}

public struct ClipboardConfig: Codable, Equatable {
    public var enabled: Bool
    public var maxItems: Int
    public var maxItemBytes: Int
    public var maxTotalBytes: Int
    public var ignoreConcealed: Bool
    public var excludedApps: [String]
}

public struct MediaConfig: Codable, Equatable {
    public var enabled: Bool
}

public struct NotifyConfig: Codable, Equatable {
    public var enabled: Bool
    /// Show other apps' notifications (captured by the shell).
    public var system: Bool
    public var bannerSecs: Int
    public var maxHistory: Int
    public var dndDuringFocus: Bool
    public var dndMinPriority: Priority

    enum CodingKeys: String, CodingKey {
        case enabled, system, bannerSecs, maxHistory, dndDuringFocus, dndMinPriority
    }

    // An unknown enum value is left out so the core keeps its own default
    // instead of rejecting the whole settings object.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(system, forKey: .system)
        try c.encode(bannerSecs, forKey: .bannerSecs)
        try c.encode(maxHistory, forKey: .maxHistory)
        try c.encode(dndDuringFocus, forKey: .dndDuringFocus)
        if dndMinPriority != .unknown { try c.encode(dndMinPriority, forKey: .dndMinPriority) }
    }
}

extension NotifyConfig {
    // `system` is new; an older core that leaves it out must not break decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        system = try c.decodeIfPresent(Bool.self, forKey: .system) ?? false
        bannerSecs = try c.decode(Int.self, forKey: .bannerSecs)
        maxHistory = try c.decode(Int.self, forKey: .maxHistory)
        dndDuringFocus = try c.decode(Bool.self, forKey: .dndDuringFocus)
        dndMinPriority = try c.decode(Priority.self, forKey: .dndMinPriority)
    }
}

public struct CaffeineConfig: Codable, Equatable {
    public var defaultMode: AwakeMode
    public var batteryFloorPct: Int
    public var lidBatteryFloorPct: Int
    public var lidRequiresAc: Bool

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if defaultMode != .unknown { try c.encode(defaultMode, forKey: .defaultMode) }
        try c.encode(batteryFloorPct, forKey: .batteryFloorPct)
        try c.encode(lidBatteryFloorPct, forKey: .lidBatteryFloorPct)
        try c.encode(lidRequiresAc, forKey: .lidRequiresAc)
    }
}

public struct AgentConfig: Codable, Equatable {
    public var enabled: Bool
    public var approvalTimeoutSecs: Int
    public var sessionTtlSecs: Int
    public var autoAllowTools: [String]
}

public struct AnalyticsConfig: Codable, Equatable {
    public var enabled: Bool
    public var share: Bool
}

public struct Settings: Codable, Equatable {
    public var general: GeneralSettings
    public var appearance: AppearanceConfig
    public var pomodoro: PomodoroConfig
    public var clipboard: ClipboardConfig
    public var media: MediaConfig
    public var notify: NotifyConfig
    public var caffeine: CaffeineConfig
    public var agent: AgentConfig
    public var analytics: AnalyticsConfig
}

extension Settings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = try c.decode(GeneralSettings.self, forKey: .general)
        appearance = (try? c.decodeIfPresent(AppearanceConfig.self, forKey: .appearance)) ?? .default
        pomodoro = try c.decode(PomodoroConfig.self, forKey: .pomodoro)
        clipboard = try c.decode(ClipboardConfig.self, forKey: .clipboard)
        media = try c.decodeIfPresent(MediaConfig.self, forKey: .media) ?? MediaConfig(enabled: true)
        notify = try c.decode(NotifyConfig.self, forKey: .notify)
        caffeine = try c.decode(CaffeineConfig.self, forKey: .caffeine)
        agent = try c.decode(AgentConfig.self, forKey: .agent)
        analytics = try c.decode(AnalyticsConfig.self, forKey: .analytics)
    }
}

// MARK: - View model

public struct CompactView: Codable, Equatable {
    public var kind: ActivityKind
    public var title: String
    public var value: String
    public var endsAtMs: Int?
    public var totalSecs: Int?
    public var count: Int
}

public struct PomodoroView: Codable, Equatable {
    public var phase: Phase
    public var runState: RunState
    public var remainingSecs: Int
    public var totalSecs: Int
    public var endsAtMs: Int?
    public var round: Int
    public var roundsBeforeLong: Int
    public var completedToday: Int
    public var focusSecsToday: Int
}

public struct MediaView: Codable, Equatable {
    public var app: String
    public var title: String
    public var artist: String
    public var album: String
    public var playing: Bool
    public var durationMs: Int?
    public var positionMs: Int?
    public var positionAtMs: Int
    public var controllable: Bool
    /// Absolute path of the current artwork image; changes with the art.
    public var artworkPath: String?
}

public struct ClipView: Codable, Equatable, Identifiable {
    public var id: Int
    public var kind: ClipKind
    public var preview: String
    public var sourceApp: String?
    public var createdMs: Int
    public var pinned: Bool
    /// For an image: a PNG or TIFF in the app's data directory.
    public var imagePath: String?
    /// For files: up to four absolute paths.
    public var files: [String]
    /// Text copied with formatting; "copy as plain text" leaves it out.
    public var rich: Bool

    public init(id: Int, kind: ClipKind, preview: String, sourceApp: String?, createdMs: Int,
                pinned: Bool, imagePath: String? = nil, files: [String] = [], rich: Bool = false) {
        self.id = id; self.kind = kind; self.preview = preview; self.sourceApp = sourceApp
        self.createdMs = createdMs; self.pinned = pinned; self.imagePath = imagePath; self.files = files
        self.rich = rich
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        preview = try c.decode(String.self, forKey: .preview)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        createdMs = try c.decode(Int.self, forKey: .createdMs)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        imagePath = (try? c.decodeIfPresent(String.self, forKey: .imagePath)) ?? nil
        files = (try? c.decodeIfPresent([String].self, forKey: .files)) ?? []
        rich = (try? c.decodeIfPresent(Bool.self, forKey: .rich)) ?? false
    }
}

public struct ClipboardView: Codable, Equatable {
    public var items: [ClipView]
    public var total: Int
    public var query: String
}

/// Where clicking a notification or session takes the user.
public enum OpenTarget: Codable, Equatable {
    /// Bring an app forward by bundle id (a session's terminal).
    case app(bundleId: String)
    /// Bring an app forward by name (another app's notification).
    case appNamed(String)
    /// A tab in the notch, and a sub-view of it where there is one.
    case tab(Tab, pane: String?)

    private enum Keys: String, CodingKey { case kind, bundleId, name, tab, pane }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "app": self = .app(bundleId: try c.decode(String.self, forKey: .bundleId))
        case "app_named": self = .appNamed(try c.decode(String.self, forKey: .name))
        case "tab":
            guard let tab = Tab(rawValue: try c.decode(String.self, forKey: .tab)) else {
                throw DecodingError.dataCorruptedError(forKey: .tab, in: c, debugDescription: "unknown tab")
            }
            self = .tab(tab, pane: try c.decodeIfPresent(String.self, forKey: .pane))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown target")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .app(let id): try c.encode("app", forKey: .kind); try c.encode(id, forKey: .bundleId)
        case .appNamed(let n): try c.encode("app_named", forKey: .kind); try c.encode(n, forKey: .name)
        case .tab(let t, let p):
            try c.encode("tab", forKey: .kind); try c.encode(t.rawValue, forKey: .tab)
            try c.encodeIfPresent(p, forKey: .pane)
        }
    }
}

public struct NotificationItem: Codable, Equatable, Identifiable {
    public var id: Int
    public var source: String
    public var title: String
    public var body: String
    public var priority: Priority
    public var group: String?
    public var ttlSecs: Int?
    public var createdMs: Int
    public var read: Bool
    /// What a click opens; nil means it only opens the inbox.
    public var open: OpenTarget?

    public init(id: Int, source: String, title: String, body: String, priority: Priority, group: String?,
                ttlSecs: Int?, createdMs: Int, read: Bool, open: OpenTarget? = nil) {
        self.id = id; self.source = source; self.title = title; self.body = body; self.priority = priority
        self.group = group; self.ttlSecs = ttlSecs; self.createdMs = createdMs; self.read = read; self.open = open
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        priority = try c.decode(Priority.self, forKey: .priority)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        ttlSecs = try c.decodeIfPresent(Int.self, forKey: .ttlSecs)
        createdMs = try c.decode(Int.self, forKey: .createdMs)
        read = try c.decode(Bool.self, forKey: .read)
        // A target this shell does not know just means "no target".
        open = (try? c.decodeIfPresent(OpenTarget.self, forKey: .open)) ?? nil
    }
}

public struct InboxView: Codable, Equatable {
    public var banner: NotificationItem?
    public var history: [NotificationItem]
    public var unread: Int
    public var dnd: Bool
}

public struct AgentSession: Codable, Equatable, Identifiable {
    public var id: String
    public var project: String
    public var cwd: String
    public var status: AgentStatus
    public var lastEventMs: Int
    public var lastMessage: String?
    /// Bundle id of the terminal or editor it runs in, when known.
    public var app: String?
}

public struct PermissionRequest: Codable, Equatable, Identifiable {
    public var id: String
    public var sessionId: String
    public var project: String
    public var toolName: String
    public var summary: String
    public var detail: String
    public var truncated: Bool
    public var createdMs: Int
    public var expiresMs: Int

    public init(id: String, sessionId: String, project: String, toolName: String,
                summary: String, detail: String, truncated: Bool = false,
                createdMs: Int, expiresMs: Int) {
        self.id = id; self.sessionId = sessionId; self.project = project
        self.toolName = toolName; self.summary = summary; self.detail = detail
        self.truncated = truncated; self.createdMs = createdMs; self.expiresMs = expiresMs
    }

    // `truncated` has a serde default on the Rust side, so tolerate its absence.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        project = try c.decode(String.self, forKey: .project)
        toolName = try c.decode(String.self, forKey: .toolName)
        summary = try c.decode(String.self, forKey: .summary)
        detail = try c.decode(String.self, forKey: .detail)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        createdMs = try c.decode(Int.self, forKey: .createdMs)
        expiresMs = try c.decode(Int.self, forKey: .expiresMs)
    }
}

public struct AgentsView: Codable, Equatable {
    public var sessions: [AgentSession]
    public var pending: [PermissionRequest]
    public var hooksInstalled: Bool?
    /// LiteNotch is Claude Code's status line (the source of usage limits);
    /// nil when not known.
    public var statuslineInstalled: Bool? = nil
}

public struct RateWindow: Codable, Equatable {
    public var usedPct: Double
    public var resetsAtMs: Int?
}

public struct TokenTotals: Codable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var messages: Int
}

public struct UsageSnapshot: Codable, Equatable {
    public var fiveHour: RateWindow?
    public var sevenDay: RateWindow?
    public var sessionCostUsd: Double?
    public var contextPct: Double?
    public var model: String?
    public var updatedMs: Int
    public var today: TokenTotals
    /// Seven days, oldest first, the last one is today.
    public var week: [UsageDay]
    /// Today, largest first, at most four of each.
    public var models: [UsageShare]
    public var projects: [UsageShare]
    /// One plain sentence; may be empty.
    public var summary: String
}

/// One day's total; `tokens` is input + output.
public struct UsageDay: Codable, Equatable {
    public var dayStartMs: Int
    public var tokens: Int
    public var messages: Int
}

public struct UsageShare: Codable, Equatable {
    public var name: String
    public var tokens: Int
}

extension UsageSnapshot {
    // The breakdown fields are newer than the rest and decode leniently:
    // missing or malformed values become empty instead of failing the view model.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(RateWindow.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(RateWindow.self, forKey: .sevenDay)
        sessionCostUsd = try c.decodeIfPresent(Double.self, forKey: .sessionCostUsd)
        contextPct = try c.decodeIfPresent(Double.self, forKey: .contextPct)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        updatedMs = try c.decode(Int.self, forKey: .updatedMs)
        today = try c.decode(TokenTotals.self, forKey: .today)
        week = (try? c.decodeIfPresent([UsageDay].self, forKey: .week)) ?? []
        models = (try? c.decodeIfPresent([UsageShare].self, forKey: .models)) ?? []
        projects = (try? c.decodeIfPresent([UsageShare].self, forKey: .projects)) ?? []
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
    }
}

public struct CaffeineView: Codable, Equatable {
    public var mode: AwakeMode
    public var lid: LidState
    public var untilMs: Int?
    public var guardText: String?

    enum CodingKeys: String, CodingKey {
        case mode, lid, untilMs
        case guardText = "guard"
    }
}

// MARK: - Meeting

public enum MeetingRunState: String, LenientEnum {
    case stopped, running, paused, finished, unknown
    static var unknownCase: MeetingRunState { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum MeetingItemState: String, LenientEnum {
    case pending, running, done, unknown
    static var unknownCase: MeetingItemState { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public struct MeetingItem: Codable, Equatable {
    public var name: String
    public var plannedSecs: Int
    /// Excludes the live stretch of a running item.
    public var elapsedSecs: Int
    public var state: MeetingItemState

    public init(name: String, plannedSecs: Int, elapsedSecs: Int = 0, state: MeetingItemState = .pending) {
        self.name = name; self.plannedSecs = plannedSecs; self.elapsedSecs = elapsedSecs; self.state = state
    }
}

public struct MeetingPreset: Codable, Equatable {
    public var id: String
    public var title: String
}

public enum TimerRunState: String, LenientEnum {
    case stopped, running, paused, done, unknown
    static var unknownCase: TimerRunState { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// The plain countdown timer.
public struct CountdownView: Codable, Equatable {
    public var durationSecs: Int
    public var runState: TimerRunState
    /// Only while running.
    public var endsAtMs: Int?
    /// Time left when not running.
    public var remainingSecs: Int
    public var presets: [Int]

    public static let empty = CountdownView(durationSecs: 300, runState: .stopped, endsAtMs: nil,
                                            remainingSecs: 300, presets: [60, 180, 300, 600, 900, 1800])

    public init(durationSecs: Int, runState: TimerRunState, endsAtMs: Int?, remainingSecs: Int, presets: [Int]) {
        self.durationSecs = durationSecs; self.runState = runState; self.endsAtMs = endsAtMs
        self.remainingSecs = remainingSecs; self.presets = presets
    }

    public var isActive: Bool { runState == .running || runState == .paused }
}

public struct MeetingView: Codable, Equatable {
    public var title: String
    public var items: [MeetingItem]
    public var current: Int?
    public var runState: MeetingRunState
    /// Planned end of the current item, only while running; may be past.
    public var endsAtMs: Int?
    /// Only while running.
    public var runningSinceMs: Int?
    /// The current item's planned time left when not running; negative when over.
    public var remainingSecs: Int
    public var totalPlannedSecs: Int
    /// Excludes the live stretch.
    public var totalElapsedSecs: Int
    public var presets: [MeetingPreset]

    public static let empty = MeetingView(title: "", items: [], current: nil, runState: .stopped,
                                          endsAtMs: nil, runningSinceMs: nil, remainingSecs: 0,
                                          totalPlannedSecs: 0, totalElapsedSecs: 0, presets: [])

    public init(title: String, items: [MeetingItem], current: Int?, runState: MeetingRunState,
                endsAtMs: Int?, runningSinceMs: Int?, remainingSecs: Int, totalPlannedSecs: Int,
                totalElapsedSecs: Int, presets: [MeetingPreset]) {
        self.title = title; self.items = items; self.current = current; self.runState = runState
        self.endsAtMs = endsAtMs; self.runningSinceMs = runningSinceMs; self.remainingSecs = remainingSecs
        self.totalPlannedSecs = totalPlannedSecs; self.totalElapsedSecs = totalElapsedSecs
        self.presets = presets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        items = (try? c.decodeIfPresent([MeetingItem].self, forKey: .items)) ?? []
        current = (try? c.decodeIfPresent(Int.self, forKey: .current)) ?? nil
        runState = (try? c.decodeIfPresent(MeetingRunState.self, forKey: .runState)) ?? .stopped
        endsAtMs = (try? c.decodeIfPresent(Int.self, forKey: .endsAtMs)) ?? nil
        runningSinceMs = (try? c.decodeIfPresent(Int.self, forKey: .runningSinceMs)) ?? nil
        remainingSecs = (try? c.decodeIfPresent(Int.self, forKey: .remainingSecs)) ?? 0
        totalPlannedSecs = (try? c.decodeIfPresent(Int.self, forKey: .totalPlannedSecs)) ?? 0
        totalElapsedSecs = (try? c.decodeIfPresent(Int.self, forKey: .totalElapsedSecs)) ?? 0
        presets = (try? c.decodeIfPresent([MeetingPreset].self, forKey: .presets)) ?? []
    }
}

public struct FeatureCount: Codable, Equatable {
    public var feature: String
    public var count: Int
}

public struct ViewModel: Codable, Equatable {
    public var compact: CompactView
    public var attention: Bool
    public var pomodoro: PomodoroView
    public var media: MediaView?
    public var clipboard: ClipboardView
    public var inbox: InboxView
    public var agents: AgentsView
    public var usage: UsageSnapshot
    public var caffeine: CaffeineView
    public var meeting: MeetingView
    public var timer: CountdownView
    /// Colours picked from the screen, newest first.
    public var colors: [String]
    public var analytics: [FeatureCount]
    public var settings: Settings
}

extension ViewModel {
    // `meeting` and `colors` are newer than the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compact = try c.decode(CompactView.self, forKey: .compact)
        attention = try c.decode(Bool.self, forKey: .attention)
        pomodoro = try c.decode(PomodoroView.self, forKey: .pomodoro)
        media = try c.decodeIfPresent(MediaView.self, forKey: .media)
        clipboard = try c.decode(ClipboardView.self, forKey: .clipboard)
        inbox = try c.decode(InboxView.self, forKey: .inbox)
        agents = try c.decode(AgentsView.self, forKey: .agents)
        usage = try c.decode(UsageSnapshot.self, forKey: .usage)
        caffeine = try c.decode(CaffeineView.self, forKey: .caffeine)
        meeting = (try? c.decodeIfPresent(MeetingView.self, forKey: .meeting)) ?? .empty
        timer = (try? c.decodeIfPresent(CountdownView.self, forKey: .timer)) ?? .empty
        colors = (try? c.decodeIfPresent([String].self, forKey: .colors)) ?? []
        analytics = try c.decode([FeatureCount].self, forKey: .analytics)
        settings = try c.decode(Settings.self, forKey: .settings)
    }
}

extension ViewModel {
    public static func decode(_ data: Data) throws -> ViewModel {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(ViewModel.self, from: data)
    }
}
