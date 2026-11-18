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

public enum ActivityKind: String, LenientEnum, CaseIterable {
    case idle, approval, banner, pomodoro, media, caffeine, agent, meeting, timer, calendar, nudge, day, unknown
    static var unknownCase: ActivityKind { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// Why the closed notch is showing something for a moment (`compact.peek`).
public enum PeekKind: String, LenientEnum, CaseIterable {
    case trackChanged = "track_changed"
    case timeWarning = "time_warning"
    /// Blink and look away, briefly; `compact.kind` is `.nudge`.
    case eyeBreak = "eye_break"
    /// Stretch, walk or drink water; `compact.title` says which.
    case move
    /// A short line after a pomodoro break; `compact.kind` is `.nudge`.
    case quote
    /// Still at the keyboard during a break; `compact.kind` is `.nudge`.
    case stillWorking = "still_working"
    case unknown
    static var unknownCase: PeekKind { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }

    /// A wellbeing peek: a face or symbol and a short line.
    public var isNudge: Bool { self == .eyeBreak || self == .move || self == .quote || self == .stillWorking }
}

/// Something a banner offers to do in one click.
public enum BannerAction: String, LenientEnum {
    /// Pause the running focus session (a meeting is starting).
    case pauseFocus = "pause_focus"
    /// End the running break (the user kept working through it).
    case skipBreak = "skip_break"
    case unknown
    static var unknownCase: BannerAction { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum Phase: String, LenientEnum, CaseIterable {
    case idle, focus
    case shortBreak = "short_break"
    case longBreak = "long_break"
    case unknown
    static var unknownCase: Phase { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum RunState: String, LenientEnum, CaseIterable {
    case stopped, running, paused, unknown
    static var unknownCase: RunState { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum ClipKind: String, LenientEnum, CaseIterable {
    case text, files, image, unknown
    static var unknownCase: ClipKind { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum Priority: String, LenientEnum, CaseIterable {
    case low, normal, high, critical, unknown
    static var unknownCase: Priority { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum AwakeMode: String, LenientEnum, CaseIterable {
    case off, system, display, unknown
    static var unknownCase: AwakeMode { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum LidState: String, LenientEnum, CaseIterable {
    case off, pending, on, unknown
    static var unknownCase: LidState { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public enum AgentStatus: String, LenientEnum, CaseIterable {
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
    /// Look for a newer version at start and once a day (contacts GitHub).
    public var checkUpdates: Bool
}

extension GeneralSettings {
    // `all_screens` is newer than the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        persistClipboard = try c.decode(Bool.self, forKey: .persistClipboard)
        hoverToExpand = try c.decode(Bool.self, forKey: .hoverToExpand)
        usageAlerts = try c.decode(Bool.self, forKey: .usageAlerts)
        allScreens = (try? c.decodeIfPresent(Bool.self, forKey: .allScreens)) ?? false
        checkUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .checkUpdates)) ?? false
    }
}

/// Which peeks are on (`settings.peek`).
public struct PeekConfig: Codable, Equatable {
    public var trackChange: Bool
    /// 0 is off.
    public var timeWarningSecs: Int

    /// Minutes of screen time between eye breaks; 0 (the default) is off.
    public var eyeBreakMins: Int = 0
    /// Minutes of screen time between Move reminders; 0 (the default) is off.
    public var moveMins: Int = 0
    /// A short encouraging line when a pomodoro break completes.
    public var breakQuote: Bool = true
    /// Remind the user who keeps working during a break.
    public var stillWorking: Bool = true

    public static let `default` = PeekConfig(trackChange: true, timeWarningSecs: 300)

    enum CodingKeys: String, CodingKey {
        case trackChange, timeWarningSecs, eyeBreakMins, moveMins, breakQuote, stillWorking
    }
}

extension PeekConfig {
    // The reminders and the break line are newer than the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackChange = try c.decode(Bool.self, forKey: .trackChange)
        timeWarningSecs = try c.decode(Int.self, forKey: .timeWarningSecs)
        eyeBreakMins = (try? c.decodeIfPresent(Int.self, forKey: .eyeBreakMins)) ?? 0
        moveMins = (try? c.decodeIfPresent(Int.self, forKey: .moveMins)) ?? 0
        breakQuote = (try? c.decodeIfPresent(Bool.self, forKey: .breakQuote)) ?? true
        stillWorking = (try? c.decodeIfPresent(Bool.self, forKey: .stillWorking)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trackChange, forKey: .trackChange)
        try c.encode(timeWarningSecs, forKey: .timeWarningSecs)
        try c.encode(eyeBreakMins, forKey: .eyeBreakMins)
        try c.encode(moveMins, forKey: .moveMins)
        try c.encode(breakQuote, forKey: .breakQuote)
        try c.encode(stillWorking, forKey: .stillWorking)
    }
}

public enum ThemeChoice: String, LenientEnum, CaseIterable {
    case system, dark, light, unknown
    static var unknownCase: ThemeChoice { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// How the notch is drawn: hanging from the top edge in the notch's own
/// silhouette (the original look), or as an island: a capsule inside the
/// menu bar with the toast and the open panel just below it.
public enum NotchStyle: String, LenientEnum, CaseIterable {
    case attached, island, unknown
    static var unknownCase: NotchStyle { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// How the closed notch and the toast are drawn: black in every theme
/// (the default, it reads as part of the hardware notch) or like the panel.
public enum ClosedNotchChoice: String, LenientEnum, CaseIterable {
    case dark, theme, unknown
    static var unknownCase: ClosedNotchChoice { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// On a display without a notch, when the closed notch shrinks to a thin
/// strip (`appearance.shrink`). Never with a hardware notch.
public enum ShrinkChoice: String, LenientEnum, CaseIterable {
    case off
    case whenEmpty = "when_empty"
    case always, unknown
    static var unknownCase: ShrinkChoice { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// What the open panel is drawn with (`appearance.material`). Glass is the
/// macOS 26 Liquid Glass material; see `GlassSupport`.
public enum MaterialChoice: String, LenientEnum, CaseIterable {
    case solid, glass, unknown
    static var unknownCase: MaterialChoice { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

public struct AppearanceConfig: Codable, Equatable {
    public var theme: ThemeChoice
    /// `#RRGGBB`; anything unparsable falls back to the default accent.
    public var accent: String
    public var notchStyle: NotchStyle
    public var closedNotch: ClosedNotchChoice
    public var material: MaterialChoice
    public var shrink: ShrinkChoice

    // Plain names: the view model is decoded with `.convertFromSnakeCase` and
    // settings are encoded with `.convertToSnakeCase`, which map them to snake_case.
    enum CodingKeys: String, CodingKey { case theme, accent, notchStyle, closedNotch, material, shrink }

    public static let defaultAccent = "#FF9E0A"
    public static let `default` = AppearanceConfig(theme: .system, accent: defaultAccent)

    public init(theme: ThemeChoice, accent: String, notchStyle: NotchStyle = .attached,
                closedNotch: ClosedNotchChoice = .dark, material: MaterialChoice = .solid,
                shrink: ShrinkChoice = .off) {
        self.theme = theme
        self.accent = accent
        self.notchStyle = notchStyle
        self.closedNotch = closedNotch
        self.material = material
        self.shrink = shrink
    }

    // `notch_style` is newer than the rest; a missing or unknown one draws
    // the original look.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decodeIfPresent(ThemeChoice.self, forKey: .theme)) ?? .system
        accent = (try? c.decodeIfPresent(String.self, forKey: .accent)) ?? Self.defaultAccent
        notchStyle = (try? c.decodeIfPresent(NotchStyle.self, forKey: .notchStyle)) ?? .attached
        closedNotch = (try? c.decodeIfPresent(ClosedNotchChoice.self, forKey: .closedNotch)) ?? .dark
        material = (try? c.decodeIfPresent(MaterialChoice.self, forKey: .material)) ?? .solid
        shrink = (try? c.decodeIfPresent(ShrinkChoice.self, forKey: .shrink)) ?? .off
    }

    // An unknown value is left out so the core keeps its own.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if theme != .unknown { try c.encode(theme, forKey: .theme) }
        try c.encode(accent, forKey: .accent)
        if notchStyle != .unknown { try c.encode(notchStyle, forKey: .notchStyle) }
        if closedNotch != .unknown { try c.encode(closedNotch, forKey: .closedNotch) }
        if material != .unknown { try c.encode(material, forKey: .material) }
        if shrink != .unknown { try c.encode(shrink, forKey: .shrink) }
    }

    /// Whether the open panel is drawn with Liquid Glass: chosen, and this
    /// build and system can draw it.
    public var usesGlass: Bool { material == .glass && GlassSupport.available }

    /// Whether to draw the open panel as glass right now. Never while an
    /// approval is waiting: that text has to read over any wallpaper, and it
    /// is contrast-tested against the solid panel colour only.
    public func drawsGlass(approvalPending: Bool) -> Bool { usesGlass && !approvalPending }
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
    /// Keep awake with the lid closed: saved, and applied whenever keep awake is turned on.
    public var lidClosed: Bool

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if defaultMode != .unknown { try c.encode(defaultMode, forKey: .defaultMode) }
        try c.encode(batteryFloorPct, forKey: .batteryFloorPct)
        try c.encode(lidClosed, forKey: .lidClosed)
    }
}

public struct AgentConfig: Codable, Equatable {
    public var enabled: Bool
    public var approvalTimeoutSecs: Int
    public var sessionTtlSecs: Int
    /// A session with no event for this long is forgotten (no control for it).
    public var sessionKeepSecs: Int
    public var autoAllowTools: [String]
}

public struct AnalyticsConfig: Codable, Equatable {
    public var enabled: Bool
    public var share: Bool
}

/// Mirrors `state::SoundConfig`: a sound when a timer, a focus session or a
/// break ends.
public struct SoundConfig: Codable, Equatable {
    public var enabled: Bool
    /// One of `sounds`.
    public var name: String

    /// The system alert sounds; mirrors `state::SOUNDS`.
    public static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop",
                                "Purr", "Sosumi", "Submarine", "Tink"]
    public static let defaultName = "Glass"
    public static let `default` = SoundConfig(enabled: true, name: defaultName)

    public init(enabled: Bool, name: String) { self.enabled = enabled; self.name = name }
}

/// Mirrors `state::NotchConfig`: what the closed notch shows when several
/// things are running.
public struct NotchConfig: Codable, Equatable {
    /// The running activities, most important first.
    public var order: [ActivityKind]
    /// Activities kept out of the closed notch.
    public var hidden: [ActivityKind]
    /// Show the second activity beside the first.
    public var twoPlaces: Bool
    /// A dot while an agent is waiting for the user.
    public var waitingDot: Bool

    /// The default order; mirrors `state::LIVE_ORDER`.
    public static let liveOrder: [ActivityKind] = [.meeting, .calendar, .timer, .pomodoro, .media, .caffeine, .agent, .day]
    public static let `default` = NotchConfig(order: liveOrder, hidden: [], twoPlaces: true, waitingDot: true)

    public init(order: [ActivityKind], hidden: [ActivityKind], twoPlaces: Bool, waitingDot: Bool) {
        self.order = order; self.hidden = hidden; self.twoPlaces = twoPlaces; self.waitingDot = waitingDot
    }
}

/// Mirrors `calendar::CalendarConfig`.
public struct CalendarConfig: Codable, Equatable {
    public var enabled: Bool
    /// Minutes before an event to remind; 0 for no reminder.
    public var alertMinutes: Int
    public var alertAtStart: Bool

    public static let `default` = CalendarConfig(enabled: false, alertMinutes: 5, alertAtStart: true)
}

/// What the big card on the left of Home shows (`day::HomeCard`).
public enum HomeCard: String, Codable, Equatable, CaseIterable {
    case media, day, auto
    public init(from decoder: Decoder) throws {
        self = HomeCard(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .auto
    }
}

/// Mirrors `day::DayIcons`: sun and moon, or a growing plant.
public enum DayIcons: String, Codable, Equatable, CaseIterable {
    case sun, tree
    public init(from decoder: Decoder) throws {
        self = DayIcons(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .sun
    }
}

/// Mirrors `day::DayConfig`: fixed office hours.
public struct DayConfig: Codable, Equatable {
    public var enabled: Bool
    /// Minutes after local midnight.
    public var startMin: Int
    public var endMin: Int
    /// Working days, bit 0 = Monday … bit 6 = Sunday.
    public var days: Int
    public var homeCard: HomeCard = .auto
    public var icons: DayIcons = .sun

    public static let `default` = DayConfig(enabled: false, startMin: 600, endMin: 1080, days: 0b001_1111)

    /// Whether Home's left card shows the day instead of now playing.
    public static func showsDayCard(_ vm: ViewModel) -> Bool {
        guard vm.day != nil else { return false }
        switch vm.settings.day.homeCard {
        case .media: return false
        case .day: return true
        case .auto: return !(vm.media?.playing ?? false)
        }
    }
}

extension DayConfig {
    // `home_card` and `icons` are newer than the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        startMin = try c.decode(Int.self, forKey: .startMin)
        endMin = try c.decode(Int.self, forKey: .endMin)
        days = try c.decode(Int.self, forKey: .days)
        homeCard = (try? c.decodeIfPresent(HomeCard.self, forKey: .homeCard)) ?? .auto
        icons = (try? c.decodeIfPresent(DayIcons.self, forKey: .icons)) ?? .sun
    }
}

/// Today's office hours (`day::DayView`).
public struct DayView: Codable, Equatable {
    public var startMs: Int
    public var endMs: Int
    public var line: String

    public init(startMs: Int, endMs: Int, line: String) {
        self.startMs = startMs; self.endMs = endMs; self.line = line
    }
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
    public var calendar: CalendarConfig
    public var notch: NotchConfig
    public var peek: PeekConfig = .default
    public var sound: SoundConfig = .default
    public var day: DayConfig = .default
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
        calendar = (try? c.decodeIfPresent(CalendarConfig.self, forKey: .calendar)) ?? .default
        notch = (try? c.decodeIfPresent(NotchConfig.self, forKey: .notch)) ?? .default
        peek = (try? c.decodeIfPresent(PeekConfig.self, forKey: .peek)) ?? .default
        sound = (try? c.decodeIfPresent(SoundConfig.self, forKey: .sound)) ?? .default
        day = (try? c.decodeIfPresent(DayConfig.self, forKey: .day)) ?? .default
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
    /// Set while this is shown for a moment only.
    public var peek: PeekKind?

    public init(kind: ActivityKind, title: String, value: String, endsAtMs: Int?, totalSecs: Int?,
                count: Int, peek: PeekKind? = nil) {
        self.kind = kind
        self.title = title
        self.value = value
        self.endsAtMs = endsAtMs
        self.totalSecs = totalSecs
        self.count = count
        self.peek = peek
    }
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
    /// Bring an app forward by bundle id (a session's terminal). With `tty`
    /// (`ttys003`), the window and tab on that terminal device, in terminals
    /// that can be asked for one (`TerminalWindow`).
    case app(bundleId: String, tty: String? = nil)
    /// Bring an app forward by name (another app's notification).
    case appNamed(String)
    /// A tab in the notch, and a sub-view of it where there is one.
    case tab(Tab, pane: String?)

    private enum Keys: String, CodingKey { case kind, bundleId, name, tab, pane, tty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "app":
            // Anything that is not a terminal device name is dropped.
            let tty = ((try? c.decodeIfPresent(String.self, forKey: .tty)) ?? nil).flatMap {
                TerminalWindow.validTTY($0) ? $0 : nil
            }
            self = .app(bundleId: try c.decode(String.self, forKey: .bundleId), tty: tty)
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
        case .app(let id, let tty):
            try c.encode("app", forKey: .kind); try c.encode(id, forKey: .bundleId)
            try c.encodeIfPresent(tty, forKey: .tty)
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
    /// A button the banner offers.
    public var action: BannerAction?

    public init(id: Int, source: String, title: String, body: String, priority: Priority, group: String?,
                ttlSecs: Int?, createdMs: Int, read: Bool, open: OpenTarget? = nil,
                action: BannerAction? = nil) {
        self.id = id; self.source = source; self.title = title; self.body = body; self.priority = priority
        self.group = group; self.ttlSecs = ttlSecs; self.createdMs = createdMs; self.read = read; self.open = open
        self.action = action
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
        action = (try? c.decodeIfPresent(BannerAction.self, forKey: .action)) ?? nil
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
    /// The terminal device it runs on (`ttys003`), when known.
    public var tty: String?

    public init(id: String, project: String, cwd: String, status: AgentStatus, lastEventMs: Int,
                lastMessage: String? = nil, app: String? = nil, tty: String? = nil) {
        self.id = id; self.project = project; self.cwd = cwd; self.status = status
        self.lastEventMs = lastEventMs; self.lastMessage = lastMessage; self.app = app; self.tty = tty
    }
}

public struct QuestionOption: Codable, Equatable {
    public var label: String
    public var description: String
    public init(label: String, description: String = "") { self.label = label; self.description = description }
}

/// One question of Claude Code's `AskUserQuestion`, as the core cleaned it.
public struct AgentQuestion: Codable, Equatable {
    public var header: String
    public var question: String
    public var multiSelect: Bool
    public var options: [QuestionOption]
    public init(header: String, question: String, multiSelect: Bool = false, options: [QuestionOption]) {
        self.header = header; self.question = question; self.multiSelect = multiSelect; self.options = options
    }
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
    /// Not empty for a question: the prompt shows choices instead of Allow / Deny.
    public var questions: [AgentQuestion]

    public init(id: String, sessionId: String, project: String, toolName: String,
                summary: String, detail: String, truncated: Bool = false,
                createdMs: Int, expiresMs: Int, questions: [AgentQuestion] = []) {
        self.questions = questions
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
        questions = try c.decodeIfPresent([AgentQuestion].self, forKey: .questions) ?? []
    }
}

public struct AgentsView: Codable, Equatable {
    public var sessions: [AgentSession]
    public var pending: [PermissionRequest]
    public var hooksInstalled: Bool?
    /// LiteNotch is Claude Code's status line (the source of usage limits);
    /// nil when not known.
    public var statuslineInstalled: Bool? = nil
    /// Other copies of LiteNotch still registered with Claude Code (a test
    /// build, an old location); each runs on every event as well.
    public var otherCopies: Int? = nil
    /// How many of those no longer exist on disk.
    public var otherCopiesMissing: Int? = nil
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

/// One upcoming (or running) calendar event.
public struct CalendarEvent: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var startMs: Int
    public var endMs: Int
    public var calendar: String
    /// The calendar's colour, `#RRGGBB`.
    public var color: String?
    public var location: String

    public init(id: String, title: String, startMs: Int, endMs: Int, calendar: String = "",
                color: String? = nil, location: String = "") {
        self.id = id; self.title = title; self.startMs = startMs; self.endMs = endMs
        self.calendar = calendar; self.color = color; self.location = location
    }
}

public struct CalendarView: Codable, Equatable {
    /// Soonest first; may still hold one that ended since it was sent.
    public var events: [CalendarEvent]
    public static let empty = CalendarView(events: [])

    /// The event to show at `nowMs`: the first that has not ended.
    public func current(nowMs: Int) -> CalendarEvent? { events.first { $0.endMs > nowMs } }
    /// How many more follow it.
    public func later(nowMs: Int) -> Int { max(0, events.filter { $0.endMs > nowMs }.count - 1) }
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

/// Where the check for a newer version stands (`update.status`).
public enum UpdateStatus: String, LenientEnum, CaseIterable {
    case idle, checking, available, failed, unknown
    case upToDate = "up_to_date"
    static var unknownCase: UpdateStatus { .unknown }
    public init(from decoder: Decoder) throws { self = try decodeLenient(decoder) }
}

/// This build's version and what the last check found (`update`).
public struct UpdateView: Codable, Equatable {
    public var current: String
    public var status: UpdateStatus
    /// The newest version, when `available`.
    public var latest: String?
    /// Its release page, when `available`.
    public var url: String?
    public var checkedMs: Int?
    /// What to run to update a Homebrew install (fixed text from the core).
    public var command: String

    public static let none = UpdateView(current: "", status: .idle, latest: nil, url: nil,
                                        checkedMs: nil, command: "")
}

public struct ViewModel: Codable, Equatable {
    public var compact: CompactView
    /// A second running activity shown beside `compact`.
    public var compactSecondary: CompactView?
    /// An agent is waiting for the user: the closed notch shows a dot.
    public var waiting: Bool
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
    public var calendar: CalendarView
    /// Today's office hours, on a working day with day progress on.
    public var day: DayView? = nil
    /// Colours picked from the screen, newest first.
    public var colors: [String]
    public var analytics: [FeatureCount]
    /// This build's version and the state of the check for a newer one.
    public var update: UpdateView = .none
    public var settings: Settings
}

extension ViewModel {
    // `meeting` and `colors` are newer than the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compact = try c.decode(CompactView.self, forKey: .compact)
        compactSecondary = try? c.decodeIfPresent(CompactView.self, forKey: .compactSecondary)
        waiting = (try? c.decodeIfPresent(Bool.self, forKey: .waiting)) ?? false
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
        calendar = (try? c.decodeIfPresent(CalendarView.self, forKey: .calendar)) ?? .empty
        day = try? c.decodeIfPresent(DayView.self, forKey: .day)
        colors = (try? c.decodeIfPresent([String].self, forKey: .colors)) ?? []
        analytics = try c.decode([FeatureCount].self, forKey: .analytics)
        update = (try? c.decodeIfPresent(UpdateView.self, forKey: .update)) ?? .none
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
