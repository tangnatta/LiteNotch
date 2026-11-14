import Combine
import Foundation
import AppKit
import SwiftUI

/// The shell's only way to reach the core. The app's `main` implements this on
/// top of the Rust FFI; tests use `MockBridge`.
public protocol CoreBridge: AnyObject {
    /// `commandJSON` is one `Command` serialized as `{"cmd": "...", ...}`.
    func send(_ commandJSON: String)
}

/// Records everything sent to it.
public final class MockBridge: CoreBridge {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public func send(_ commandJSON: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(commandJSON)
    }

    public var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Sent commands parsed to dictionaries.
    public var sentObjects: [[String: Any]] {
        sent.compactMap { s in
            (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
        }
    }
}

/// One agenda line as `meeting_set` takes it.
public struct AgendaLine: Equatable {
    public var name: String
    public var minutes: Int
    public init(name: String, minutes: Int) { self.name = name; self.minutes = minutes }
}

/// Every command the UI sends, typed. `encode()` produces the exact JSON the
/// Rust `Command` enum deserializes.
public enum ShellCommand: Equatable {
    case pomodoroToggle, pomodoroSkip, pomodoroReset
    case clipCopy(id: Int)
    /// Copy without the formatting it was copied with.
    case clipCopyPlain(id: Int)
    case clipPin(id: Int, pinned: Bool)
    case clipRemove(id: Int)
    case clipClear
    case clipQuery(String)
    case notifyDismissBanner
    case notifyDismiss(id: Int)
    case notifyMarkRead
    /// A notification was clicked, so it counts as read.
    case notifyOpened(id: Int)
    case notifyClear
    case media(MediaAction)
    /// Another app's notification, captured by `SystemNotificationObserver`.
    case notifySystem(app: String, title: String, body: String)
    case agentDecide(requestId: String, decision: Decision)
    case caffeineToggle
    case caffeineActivate(mode: AwakeMode, durationSecs: Int?)
    case caffeineLid(on: Bool)
    case setSettings(Settings)
    case panelOpened
    case tabOpened(Tab)
    case analyticsClear
    case setUtcOffset(secs: Int)
    case refresh
    case meetingLoad(preset: String)
    /// The whole agenda; the core honours it only while no meeting runs.
    case meetingSet(title: String, items: [AgendaLine])
    case meetingToggle, meetingNext, meetingReset
    /// The plain countdown timer.
    case timerSet(secs: Int)
    case timerToggle, timerReset
    case timerAdd(secs: Int)
    /// A colour from the screen sampler: the core copies and remembers it.
    case colorPicked(hex: String)
    /// Not part of the Rust `Command` enum: the app's bridge handles these
    /// (writing/removing the Claude Code hook entries) itself.
    case hooksInstall, hooksUninstall
    /// Makes LiteNotch Claude Code's status line (wrapping the one there),
    /// which is where usage limits come from; and the reverse.
    case statuslineInstall, statuslineUninstall

    var object: [String: Any] {
        func c(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var d = extra
            d["cmd"] = name
            return d
        }
        switch self {
        case .pomodoroToggle: return c("pomodoro_toggle")
        case .pomodoroSkip: return c("pomodoro_skip")
        case .pomodoroReset: return c("pomodoro_reset")
        case .clipCopy(let id): return c("clip_copy", ["id": id])
        case .clipCopyPlain(let id): return c("clip_copy_plain", ["id": id])
        case .timerSet(let secs): return c("timer_set", ["secs": secs])
        case .timerToggle: return c("timer_toggle")
        case .timerReset: return c("timer_reset")
        case .timerAdd(let secs): return c("timer_add", ["secs": secs])
        case .clipPin(let id, let pinned): return c("clip_pin", ["id": id, "pinned": pinned])
        case .clipRemove(let id): return c("clip_remove", ["id": id])
        case .clipClear: return c("clip_clear")
        case .clipQuery(let q): return c("clip_query", ["query": q])
        case .notifyDismissBanner: return c("notify_dismiss_banner")
        case .notifyDismiss(let id): return c("notify_dismiss", ["id": id])
        case .notifyMarkRead: return c("notify_mark_read")
        case .notifyOpened(let id): return c("notify_opened", ["id": id])
        case .notifyClear: return c("notify_clear")
        case .media(let a): return c("media", ["action": a.rawValue])
        case .notifySystem(let app, let title, let body):
            return c("notify_system", ["app": app, "title": title, "body": body])
        case .agentDecide(let id, let d): return c("agent_decide", ["request_id": id, "decision": d.rawValue])
        case .caffeineToggle: return c("caffeine_toggle")
        case .caffeineActivate(let mode, let secs):
            return c("caffeine_activate", ["mode": mode.rawValue, "duration_secs": secs.map { $0 as Any } ?? NSNull()])
        case .caffeineLid(let on): return c("caffeine_lid", ["on": on])
        case .setSettings(let s):
            let e = JSONEncoder()
            e.keyEncodingStrategy = .convertToSnakeCase
            let data = (try? e.encode(s)) ?? Data("{}".utf8)
            let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
            return c("set_settings", ["settings": obj])
        case .panelOpened: return c("panel_opened")
        case .tabOpened(let t): return c("tab_opened", ["tab": t.rawValue])
        case .analyticsClear: return c("analytics_clear")
        case .setUtcOffset(let s): return c("set_utc_offset", ["secs": s])
        case .refresh: return c("refresh")
        case .meetingLoad(let id): return c("meeting_load", ["preset": id])
        case .meetingSet(let title, let items):
            return c("meeting_set", ["title": title,
                                     "items": items.map { ["name": $0.name, "minutes": $0.minutes] as [String: Any] }])
        case .meetingToggle: return c("meeting_toggle")
        case .meetingNext: return c("meeting_next")
        case .meetingReset: return c("meeting_reset")
        case .colorPicked(let hex): return c("color_picked", ["hex": hex])
        case .hooksInstall: return c("hooks_install")
        case .hooksUninstall: return c("hooks_uninstall")
        case .statuslineInstall: return c("statusline_install")
        case .statuslineUninstall: return c("statusline_uninstall")
        }
    }

    public func encode() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// Categories of the Settings tab.
public enum SettingsSection: String, CaseIterable, Equatable {
    case general, timer, music, notifications, clipboard, agents, keepAwake, privacy
}

/// The two halves of the Agents tab.
public enum AgentsPane: String, CaseIterable, Equatable {
    case sessions, usage
}

/// The two halves of the Timer tab.
public enum TimerPane: String, CaseIterable, Equatable {
    case focus, meeting, countdown
}

// MARK: - Screen colour sampler

/// Picks one colour from the screen; `done` gets upper-case sRGB `#RRGGBB`,
/// or nil when the user cancelled. Injected so `AppModel` is testable.
public protocol ColorSampling: AnyObject {
    func sample(_ done: @escaping (String?) -> Void)
}

/// `NSColorSampler`: the system loupe, the same one the colour panel uses.
public final class SystemColorSampler: ColorSampling {
    private var sampler: NSColorSampler?

    public init() {}

    public func sample(_ done: @escaping (String?) -> Void) {
        guard sampler == nil else { return }
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] color in
            DispatchQueue.main.async {
                self?.sampler = nil
                done(color.flatMap(ColorMath.hex(of:)))
            }
        }
    }
}

// MARK: - Shared model

/// State shared by every notch panel: the latest view model, the bridge to
/// the core and app-level actions. What each panel shows (open or not,
/// which tab, its notch size) lives in its `PanelState`.
public final class AppModel: ObservableObject {
    @Published public private(set) var view: ViewModel?
    /// True while "show other apps' notifications" is on but LiteNotch has
    /// not been allowed under Privacy & Security › Accessibility.
    @Published public var accessibilityNeeded = false
    /// One per notch; the first always exists (tests and snapshots use it).
    @Published public private(set) var panels: [PanelState] = []
    /// Fires whenever any panel goes from closed to open.
    public let panelOpened = PassthroughSubject<Void, Never>()

    /// What "Quit" does. Defaults to `NSApplication.terminate`.
    public var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }
    /// Brings another app forward. Tests replace it.
    public var activateApp: (OpenTarget) -> Void = AppModel.activate
    /// "Reset and ask again": clears a stale Accessibility entry and asks
    /// again. Set by the app, which owns the permission check.
    public var onResetAccessibility: () -> Void = {}

    /// What "Open Settings" (Accessibility permission) does.
    public var onOpenAccessibilitySettings: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private let bridge: CoreBridge
    private let sampler: ColorSampling
    private var openPanels: Set<ObjectIdentifier> = []

    /// Brings the app a target names to the front. A bundle id that is not
    /// running is launched only from the standard application folders, so a
    /// notification cannot start an arbitrary program by naming its id.
    public static func activate(_ target: OpenTarget) {
        let ws = NSWorkspace.shared
        switch target {
        case .app(let id, let tty):
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                // The session's own window where the terminal can be asked
                // for it; otherwise (or if that fails) just the app.
                if let tty, TerminalWindow.focus(bundleId: id, tty: tty, fallback: { running.activate() }) {
                    return
                }
                running.activate()
            } else if let url = ws.urlForApplication(withBundleIdentifier: id), mayLaunch(url) {
                ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .appNamed(let name):
            if let running = ws.runningApplications.first(where: { $0.localizedName == name }) {
                running.activate()
            }
        case .tab:
            break
        }
    }

    /// True for an app bundle in /Applications, /System/Applications or
    /// ~/Applications (symlinks resolved, no `..` tricks).
    public static func mayLaunch(_ url: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = ["/Applications", "/System/Applications",
                     home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Applications").path]
        return roots.contains { path.hasPrefix($0 + "/") } && path.hasSuffix(".app")
    }

    public init(bridge: CoreBridge, sampler: ColorSampling = SystemColorSampler()) {
        self.bridge = bridge
        self.sampler = sampler
        panels = [PanelState(app: self)]
    }

    /// The first panel: the built-in (or main) display's.
    public var primary: PanelState { panels[0] }

    /// A panel for one more display.
    public func addPanel() -> PanelState {
        let p = PanelState(app: self)
        panels.append(p)
        return p
    }

    /// Removes a panel added with `addPanel`; the primary one stays.
    public func removePanel(_ p: PanelState) {
        guard p !== primary else { return }
        p.detach()
        panels.removeAll { $0 === p }
        openPanels.remove(ObjectIdentifier(p))
    }

    // MARK: Core to UI

    /// Decodes a view model. Callable from any thread; publishes on main.
    public func receive(viewJSON: Data) {
        guard let vm = try? ViewModel.decode(viewJSON) else { return }
        if Thread.isMainThread {
            apply(vm)
        } else {
            DispatchQueue.main.async { [weak self] in self?.apply(vm) }
        }
    }

    func apply(_ vm: ViewModel) {
        let before = panels.map(\.mode)
        let after = panels.map { NotchPresentation.mode(expanded: $0.expanded, view: vm) }
        NT.setAccent(vm.settings.appearance.accent)
        if before != after {
            withAnimation(NotchPresentation.spring) { view = vm }
        } else {
            view = vm
        }
        panels.forEach { $0.syncOpenState() }
    }

    // MARK: UI to core

    public func send(_ command: ShellCommand) {
        bridge.send(command.encode())
    }

    /// Runs the screen sampler; the colour is copied and remembered by the core.
    public func pickColor() {
        sampler.sample { [weak self] hex in
            guard let self, let hex else { return }
            self.send(.colorPicked(hex: hex))
        }
    }

    /// Runs the screen sampler and makes the colour the accent.
    public func pickAccent() {
        sampler.sample { [weak self] hex in
            guard let self, let hex, var s = self.view?.settings else { return }
            s.appearance.accent = hex
            self.send(.setSettings(s))
        }
    }

    /// `panel_opened` is sent when the first panel opens, not once per
    /// display (an approval opens all of them at once).
    fileprivate func panel(_ p: PanelState, isOpen open: Bool) {
        let id = ObjectIdentifier(p)
        if open {
            let first = openPanels.isEmpty
            guard openPanels.insert(id).inserted else { return }
            if first { send(.panelOpened) }
            panelOpened.send()
        } else {
            openPanels.remove(id)
        }
    }

    // Snapshot support.
    func setForSnapshot(_ vm: ViewModel, expanded: Bool, tab: Tab,
                        section: SettingsSection = .general, pane: AgentsPane = .sessions,
                        timerPane: TimerPane = .focus, clipPreview: Int? = nil,
                        accessibilityNeeded: Bool = false) {
        NT.setAccent(vm.settings.appearance.accent)
        view = vm
        let p = primary
        p.expanded = expanded
        p.tab = tab
        p.settingsSection = section
        p.agentsPane = pane
        p.timerPane = timerPane
        p.clipPreview = clipPreview
        self.accessibilityNeeded = accessibilityNeeded
        p.syncOpenState()
    }
}

// MARK: - Per-panel state

/// What one notch panel shows: open or closed, the tab, its notch size, and
/// the hover timing. Re-publishes the shared model's changes, so views only
/// need to observe this.
public final class PanelState: ObservableObject {
    @Published public var expanded = false
    @Published public var tab: Tab = .home
    /// Which Settings category is showing; other tabs deep-link through
    /// `openSettings(_:)`.
    @Published public var settingsSection: SettingsSection = .general
    @Published public var agentsPane: AgentsPane = .sessions
    @Published public var timerPane: TimerPane = .focus
    /// The clipboard item shown large instead of the list, if any.
    @Published public var clipPreview: Int?
    /// True while a text field (clipboard search, agenda) wants to type;
    /// the panel then allows itself to become key.
    @Published public var keyboardRequested = false
    /// Size of the physical (or fallback) notch; set by the panel controller.
    @Published public var notch = CGSize(width: 183, height: 32)
    /// False when `notch` is only the stand-in on a screen without one. With
    /// a real notch the closed shape stays black whatever `closed_notch` says.
    @Published public var hasNotch = true
    /// Height of this screen's menu bar; 0 when hidden or unknown.
    @Published public var menuBarHeight: CGFloat = 0

    public private(set) weak var app: AppModel?
    /// Monotonic seconds; replaced in tests.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var forward: AnyCancellable?
    private var pointerInside = false
    private var hoverWork: DispatchWorkItem?
    private var wasOpen = false
    /// When the panel was last opened by hovering (see `stripClicked`).
    private var hoverOpenedAt: TimeInterval?
    /// Set by a click that closed the panel: the pointer is still on the
    /// notch, and hovering must not reopen it until it has left once.
    private var hoverSuppressed = false

    init(app: AppModel) {
        self.app = app
        forward = app.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    fileprivate func detach() {
        forward = nil
        hoverWork?.cancel()
        hoverWork = nil
    }

    // MARK: Shared state, passed through

    public var view: ViewModel? { app?.view }
    public var accessibilityNeeded: Bool { app?.accessibilityNeeded ?? false }

    public func send(_ command: ShellCommand) { app?.send(command) }

    public var mode: NotchMode {
        NotchPresentation.mode(expanded: expanded, view: view)
    }

    public var layout: NotchLayout {
        let style = view?.settings.appearance.notchStyle ?? .attached
        return NotchLayout(style: style == .floating ? .floating : .attached,
                           notch: notch, hasNotch: hasNotch, menuBarHeight: menuBarHeight)
    }

    /// Target size of the current shape (not animated); used for hit testing.
    public var targetSize: CGSize {
        layout.size(for: mode, compact: view?.compact)
    }

    /// Whether a point (from the top-left of the shape's area) takes the
    /// pointer; see `NotchLayout.contains`.
    public func shapeContains(_ p: CGPoint) -> Bool {
        layout.contains(p, mode: mode, in: targetSize)
    }

    // MARK: Navigation

    public func selectTab(_ t: Tab) {
        guard t != tab else { return }
        tab = t
        clipPreview = nil
        send(.tabOpened(t))
    }

    /// Jumps to one category of the Settings tab.
    public func openSettings(_ section: SettingsSection) {
        settingsSection = section
        selectTab(.settings)
    }

    /// Jumps to one half of the Timer tab.
    public func openTimer(_ pane: TimerPane) {
        timerPane = pane
        selectTab(.timer)
    }

    /// Follows a notification's (or session's) target: another app is
    /// brought forward and the panel closes; a tab opens in this panel.
    public func follow(_ target: OpenTarget?) {
        switch target {
        case .app, .appNamed:
            if let target { app?.activateApp(target) }
            requestKeyboard(false)
            close()
        case .tab(let t, let pane):
            switch (t, pane) {
            case (.timer, let p?): timerPane = TimerPane(rawValue: p) ?? timerPane
            case (.agents, let p?): agentsPane = AgentsPane(rawValue: p) ?? agentsPane
            case (.settings, "keep_awake"): settingsSection = .keepAwake
            case (.settings, let p?): settingsSection = SettingsSection(rawValue: p) ?? settingsSection
            default: break
            }
            selectTab(t)
            open()
        case nil:
            selectTab(.inbox)
            open()
        }
    }

    /// A click on a notification (inbox row or toast). Going somewhere
    /// answers a showing banner; the inbox keeps the item.
    public func openNotification(_ n: NotificationItem, isBanner: Bool) {
        send(.notifyOpened(id: n.id))
        if isBanner && n.open != nil { send(.notifyDismissBanner) }
        follow(n.open)
    }

    /// A click on a session row: brings its terminal forward when known.
    public func openSession(_ s: AgentSession) {
        guard let app = s.app else { return }
        follow(.app(bundleId: app, tty: s.tty))
    }

    /// The tab-bar eyedropper: the panel gets out of the way first.
    public func pickColor() {
        requestKeyboard(false)
        close()
        app?.pickColor()
    }

    public func requestKeyboard(_ on: Bool) {
        guard keyboardRequested != on else { return }
        keyboardRequested = on
        // Typing kept the panel open; if the pointer has left meanwhile,
        // no hover event will come to close it.
        if !on && !pointerInside { hoverChanged(false) }
    }

    /// A click somewhere else on screen (another app or another panel).
    public func clickedOutside() {
        guard expanded, !(view?.agents.pending.isEmpty == false) else { return }
        requestKeyboard(false)
        close()
    }

    // MARK: Hover / click
    //
    // Hover and click both work, always. Hovering opens after a short delay
    // (when the setting is on) and closes after the pointer leaves; a click
    // on the closed notch opens at once, and a click on the open panel's top
    // strip closes it. The two only meet in one place: a click that lands
    // just after hovering opened the panel was aimed at the closed notch, so
    // it must not close what it meant to open (`clickGrace`).

    static let clickGrace: TimeInterval = 0.6

    public func hoverChanged(_ inside: Bool) {
        pointerInside = inside
        hoverWork?.cancel()
        hoverWork = nil
        if inside {
            guard !expanded, !hoverSuppressed, view?.settings.general.hoverToExpand ?? true else { return }
            schedule(after: NotchPresentation.hoverDelay) { [weak self] in
                guard let self, self.pointerInside, !self.expanded else { return }
                self.hoverOpenedAt = self.uptime()
                self.setExpanded(true)
            }
        } else {
            hoverSuppressed = false
            guard expanded, !keyboardRequested else { return }
            schedule(after: NotchPresentation.collapseDelay) { [weak self] in
                guard let self, !self.pointerInside, !self.keyboardRequested else { return }
                self.setExpanded(false)
            }
        }
    }

    /// Click on the closed shape (or a toast): opens immediately, whether or
    /// not a hover is pending.
    public func open() {
        hoverWork?.cancel()
        hoverWork = nil
        hoverOpenedAt = nil
        setExpanded(true)
    }

    public func close() {
        hoverWork?.cancel()
        hoverWork = nil
        setExpanded(false)
    }

    /// Click on the open panel's top strip (not on one of its buttons).
    public func stripClicked() {
        guard expanded else { open(); return }
        // An approval keeps the panel open until it is answered.
        guard view?.agents.pending.isEmpty ?? true else { return }
        if let t = hoverOpenedAt, uptime() - t < Self.clickGrace { return }
        // The pointer is still over the notch; without this the hover that
        // follows the shape shrinking would reopen the panel straight away.
        hoverSuppressed = pointerInside
        close()
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(NotchPresentation.spring) { expanded = value }
        if !value { keyboardRequested = false; hoverOpenedAt = nil }
        syncOpenState()
    }

    /// Reports every closed to open transition, however it happened (hover,
    /// click, or an approval arriving).
    func syncOpenState() {
        let open = mode == .expanded
        guard open != wasOpen else { return }
        wasOpen = open
        app?.panel(self, isOpen: open)
    }
}
