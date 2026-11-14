import AppKit
import SwiftUI

/// Renders fixtures to PNG with `ImageRenderer`; no window involved.
public enum SnapshotRenderer {
    /// "Now" for snapshots: 90 s after the fixtures' base timestamp.
    public static let snapshotNowMs = 1_794_400_090_000

    @MainActor
    public static func renderAll(fixturesDir: URL, outDir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var written: [URL] = []
        let canvas = CGSize(width: 680, height: 320)
        func add(_ name: String, _ vm: ViewModel, expanded: Bool = true, tab: Tab = .home,
                 section: SettingsSection = .general, pane: AgentsPane = .sessions,
                 timerPane: TimerPane = .focus, clipPreview: Int? = nil,
                 accessibilityNeeded: Bool = false, notchless: Bool = false) throws {
            // A pending approval opens the panel whatever `expanded` says;
            // a short canvas would show it cut off.
            let open = NotchPresentation.mode(expanded: expanded, view: vm) == .expanded
            let size = open ? canvas : CGSize(width: canvas.width, height: 110)
            if let u = try write(vm, expanded: expanded, tab: tab, section: section, pane: pane,
                                 timerPane: timerPane, clipPreview: clipPreview,
                                 accessibilityNeeded: accessibilityNeeded, notchless: notchless, size: size,
                                 to: outDir.appendingPathComponent("\(name).png")) { written.append(u) }
        }
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            let vm = try ViewModel.decode(Data(contentsOf: f))
            try add("\(name)-closed", vm, expanded: false)
            if ["idle", "pomodoro", "media", "banner"].contains(name) {
                // The floating style, with a notch and on a 24 pt menu bar without one.
                var floating = vm
                floating.settings.appearance.notchStyle = .floating
                try add("floating-\(name)-closed", floating, expanded: false)
                try add("floating-notchless-\(name)-closed", floating, expanded: false, notchless: true)
                if name == "pomodoro" {
                    try add("floating-pomodoro-expanded-home", floating)
                    try add("floating-notchless-pomodoro-expanded-home", floating, notchless: true)
                }
            }
            if name == "approval" {
                var long = vm
                long.agents.pending[0].truncated = true
                long.agents.pending[0].detail = String(repeating: "rm -rf build && cargo build --release --target aarch64-apple-darwin && ", count: 8)
                long.agents.pending.append(long.agents.pending[0])
                long.agents.pending[1].id = "req-2"
                try add("approval-truncated-expanded", long)
            }
            for tab in Tab.allCases {
                try add("\(name)-expanded-\(tab.rawValue)", vm, tab: tab)
            }
            try add("\(name)-expanded-agents-usage", vm, tab: .agents, pane: .usage)
            if name == "pomodoro" {
                try add("pomodoro-expanded-timer-meeting", vm, tab: .timer, timerPane: .meeting)
                try add("timer-stopped-expanded-timer", vm, tab: .timer, timerPane: .countdown)
                var running = vm
                running.pomodoro = vm.pomodoro
                running.timer.runState = .running
                running.timer.endsAtMs = snapshotNowMs + 4 * 60_000 + 12_000
                running.compact = CompactView(kind: .timer, title: "Timer", value: "",
                                              endsAtMs: running.timer.endsAtMs, totalSecs: 300, count: 0)
                try add("timer-running-expanded-timer", running, tab: .timer, timerPane: .countdown)
                try add("timer-running-closed", running, expanded: false)
                var done = vm
                done.timer.runState = .done
                done.timer.remainingSecs = 0
                try add("timer-done-expanded-timer", done, tab: .timer, timerPane: .countdown)
                for state in ["running", "over", "paused", "finished"] {
                    let m = meeting(vm, state)
                    try add("meeting-\(state)-expanded-timer", m, tab: .timer, timerPane: .meeting)
                    if state != "finished" { try add("meeting-\(state)-closed", m, expanded: false) }
                }
                try add("meeting-running-expanded-home", meeting(vm, "running"))
                var long = vm
                long.meeting.items[1].name = "A very long agenda item name that will not fit in the row"
                long.meeting.title = "Quarterly planning with the platform team"
                try add("meeting-long-expanded-timer", long, tab: .timer, timerPane: .meeting)
                try add("meeting-long-running-expanded-timer", meeting(long, "over"), tab: .timer, timerPane: .meeting)
                var light = meeting(vm, "running")
                light.settings.appearance.theme = .light
                try add("light-meeting-running-expanded-timer", light, tab: .timer, timerPane: .meeting)
                try add("light-meeting-running-closed", light, expanded: false)
                light.meeting = vm.meeting
                try add("light-pomodoro-expanded-timer-meeting", light, tab: .timer, timerPane: .meeting)
            }
            if name == "banner" {
                var light = vm
                light.settings.appearance.theme = .light
                try add("light-banner-closed", light, expanded: false)
                light.settings.appearance.closedNotch = .theme
                try add("light-matched-banner-closed", light, expanded: false, notchless: true)
            }
            // "Closed notch: Match theme" in the light theme: every closed
            // activity, plus the toast above. Without a notch: with one the
            // closed shape stays black.
            if name != "banner" && name != "idle" {
                var matched = vm
                matched.settings.appearance.theme = .light
                matched.settings.appearance.closedNotch = .theme
                try add("light-matched-\(name)-closed", matched, expanded: false, notchless: true)
                var darkMatched = vm
                darkMatched.settings.appearance.theme = .dark
                darkMatched.settings.appearance.closedNotch = .theme
                try add("dark-matched-\(name)-closed", darkMatched, expanded: false, notchless: true)
            }
            if name == "media" {
                var colored = vm
                colored.colors = ["#FF9E0A", "#0A84FF", "#30D158", "#1E1E1E", "#F5F5F7", "#BF5AF2"]
                try add("media-expanded-clipboard-colors", colored, tab: .clipboard)
                if let img = vm.clipboard.items.first(where: { $0.kind == .image }) {
                    try add("media-expanded-clipboard-preview-image", vm, tab: .clipboard, clipPreview: img.id)
                }
                if let f = vm.clipboard.items.first(where: { $0.kind == .files }) {
                    try add("media-expanded-clipboard-preview-files", vm, tab: .clipboard, clipPreview: f.id)
                }
                var light = colored
                light.settings.appearance.theme = .light
                for tab in [Tab.home, .music, .timer, .clipboard, .inbox] {
                    try add("light-media-expanded-\(tab.rawValue)", light, tab: tab)
                }
                try add("light-media-expanded-agents-usage", light, tab: .agents, pane: .usage)
                try add("light-media-expanded-agents", light, tab: .agents)
                try add("light-media-expanded-settings-general", light, tab: .settings, section: .general)
                try add("light-media-expanded-settings-keepAwake", light, tab: .settings, section: .keepAwake)
                try add("light-media-closed", light, expanded: false)
                var blue = vm
                blue.settings.appearance.accent = "#0A84FF"
                try add("accent-blue-expanded-settings-general", blue, tab: .settings, section: .general)
                try add("accent-blue-expanded-home", blue)
                var purpleLight = light
                purpleLight.settings.appearance.accent = "#BF5AF2"
                try add("accent-purple-light-expanded-home", purpleLight)
                var bad = vm
                bad.settings.appearance.accent = "not a colour"
                try add("accent-invalid-expanded-timer", bad, tab: .timer)
            }
            if name == "approval" {
                var light = vm
                light.settings.appearance.theme = .light
                try add("light-approval-expanded", light)
            }
            if name == "media" {
                for section in SettingsSection.allCases where section != .general {
                    try add("media-expanded-settings-\(section.rawValue)", vm, tab: .settings, section: section)
                }
                // Other apps' notifications switched on, permission still missing.
                var waiting = vm
                waiting.settings.notify.system = true
                try add("media-expanded-inbox-permission", waiting, tab: .inbox, accessibilityNeeded: true)
                try add("media-expanded-settings-notifications-permission", waiting, tab: .settings,
                        section: .notifications, accessibilityNeeded: true)
                // Not playing, not controllable, long names.
                var paused = vm
                paused.media?.playing = false
                paused.media?.controllable = false
                paused.media?.app = "Google Chrome"
                paused.media?.title = "A very long video title that keeps going well past the edge of the panel and then some"
                paused.media?.artist = ""
                paused.media?.album = ""
                try add("media-expanded-music-long", paused, tab: .music)
                try add("media-expanded-home-long", paused, tab: .home)
            }
            if name == "idle" {
                var empty = vm
                empty.usage.week = []; empty.usage.models = []; empty.usage.projects = []
                empty.usage.summary = ""
                empty.usage.today = TokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, messages: 0)
                try add("idle-expanded-agents-usage-empty", empty, tab: .agents, pane: .usage)
                var off = vm
                off.settings.media.enabled = false
                try add("idle-expanded-music-off", off, tab: .music)
            }
            if name == "caffeine" {
                var pending = vm
                pending.caffeine.lid = .pending
                pending.caffeine.guardText = "On battery at 18%: lid-closed mode needs power or 25% charge."
                try add("caffeine-expanded-settings-keepAwake", pending, tab: .settings, section: .keepAwake)
            }
        }
        return written
    }

    /// The fixture's agenda in one of the states the core can report.
    static func meeting(_ vm: ViewModel, _ state: String) -> ViewModel {
        var v = vm
        var m = v.meeting
        guard m.items.count >= 3 else { return v }
        let now = snapshotNowMs
        switch state {
        case "running", "over", "paused":
            m.items[0].state = .done
            m.items[0].elapsedSecs = m.items[0].plannedSecs + 45
            m.items[1].state = .running
            m.current = 1
            let stretch = 120
            if state == "paused" {
                m.runState = .paused
                m.items[1].elapsedSecs = 300
                m.endsAtMs = nil
                m.runningSinceMs = nil
                m.remainingSecs = m.items[1].plannedSecs - 300
            } else {
                m.runState = .running
                m.runningSinceMs = now - stretch * 1000
                let spent = state == "over" ? m.items[1].plannedSecs + 65 : 300
                m.items[1].elapsedSecs = spent - stretch
                m.endsAtMs = now + (m.items[1].plannedSecs - spent) * 1000
                m.remainingSecs = 0
            }
            m.totalElapsedSecs = m.items[0].elapsedSecs + m.items[1].elapsedSecs
        case "finished":
            m.runState = .finished
            m.current = nil
            for i in m.items.indices {
                m.items[i].state = .done
                m.items[i].elapsedSecs = m.items[i].plannedSecs + (i % 2 == 0 ? 75 : -110)
            }
            m.totalElapsedSecs = m.items.reduce(0) { $0 + $1.elapsedSecs }
        default:
            break
        }
        v.meeting = m
        if MeetingMath.isActive(m), let item = MeetingMath.currentItem(m) {
            v.compact = CompactView(kind: .meeting, title: item.name, value: m.runState == .paused ? "Paused" : "",
                                    endsAtMs: m.endsAtMs, totalSecs: item.plannedSecs, count: 0)
        }
        return v
    }

    @MainActor
    static func write(_ vm: ViewModel, expanded: Bool, tab: Tab, section: SettingsSection = .general,
                      pane: AgentsPane = .sessions, timerPane: TimerPane = .focus, clipPreview: Int? = nil,
                      accessibilityNeeded: Bool = false, notchless: Bool = false,
                      size: CGSize, to url: URL) throws -> URL? {
        let model = AppModel(bridge: MockBridge())
        if notchless {
            model.primary.notch = NotchGeometry.fallbackSize
            model.primary.hasNotch = false
            model.primary.menuBarHeight = 24
        }
        model.setForSnapshot(vm, expanded: expanded, tab: tab, section: section, pane: pane,
                             timerPane: timerPane, clipPreview: clipPreview,
                             accessibilityNeeded: accessibilityNeeded)
        let offset = snapshotNowMs - Int(Date().timeIntervalSince1970 * 1000)
        // "System" renders dark; light variants set the theme explicitly.
        let scheme: ColorScheme = vm.settings.appearance.theme == .light ? .light : .dark
        let root = NotchRootView(model: model.primary)
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.clockOffsetMs, offset)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(white: 0.5))
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try data.write(to: url)
        return url
    }
}
