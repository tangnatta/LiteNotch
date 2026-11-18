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
            if ["idle", "pomodoro", "media", "banner", "pair", "peek-track", "peek-warning", "calendar"].contains(name) {
                // Without a notch: one row, no gap in the middle.
                try add("notchless-\(name)-closed", vm, expanded: false, notchless: true)
            }
            if ["idle", "pomodoro", "media", "banner", "pair"].contains(name) {
                // The island style, with a notch and on a 24 pt menu bar without one.
                var island = vm
                island.settings.appearance.notchStyle = .island
                try add("island-\(name)-closed", island, expanded: false)
                try add("island-notchless-\(name)-closed", island, expanded: false, notchless: true)
                if name == "idle" {
                    // Shrink when empty, without a notch: the strip, in both styles.
                    var shrunk = vm
                    shrunk.settings.appearance.shrink = .whenEmpty
                    try add("notchless-idle-shrunk-closed", shrunk, expanded: false, notchless: true)
                    shrunk.settings.appearance.notchStyle = .island
                    try add("island-notchless-idle-shrunk-closed", shrunk, expanded: false, notchless: true)
                }
                if name == "pomodoro" {
                    // Shrink always: the strip even with a timer running.
                    var shrunk = vm
                    shrunk.settings.appearance.shrink = .always
                    try add("notchless-pomodoro-shrunk-closed", shrunk, expanded: false, notchless: true)
                }
                if name == "pomodoro" {
                    try add("island-pomodoro-expanded-home", island)
                    try add("island-notchless-pomodoro-expanded-home", island, notchless: true)
                }
            }
            if name == "pair" {
                try add("pair-expanded-settings-notch", vm, tab: .settings, section: .notch)
                // The meeting starts: the banner offers to pause the focus session.
                var starting = vm
                starting.inbox.banner = NotificationItem(id: 99, source: "calendar", title: "Design review",
                                                         body: "Starting now \u{b7} Room 3", priority: .high, group: nil,
                                                         ttlSecs: nil, createdMs: snapshotNowMs, read: false,
                                                         open: .tab(.home, pane: nil), action: .pauseFocus)
                try add("pair-starting-toast", starting, expanded: false)
                // Only the dot: nothing running, an agent waiting.
                var dot = vm
                dot.compact = CompactView(kind: .idle, title: "", value: "", endsAtMs: nil, totalSecs: nil, count: 0)
                dot.compactSecondary = nil
                try add("waiting-dot-closed", dot, expanded: false)
                var island = vm
                island.settings.appearance.notchStyle = .island
                try add("island-pair-closed", island, expanded: false)
                try add("island-notchless-pair-closed", island, expanded: false, notchless: true)
                try add("island-pair-expanded-settings-notch", island, tab: .settings, section: .notch)
                // The same pane on a display without a camera housing: one row.
                try add("island-notchless-pair-expanded-settings-notch", island, tab: .settings, section: .notch, notchless: true)
                try add("notchless-pair-expanded-settings-notch", vm, tab: .settings, section: .notch, notchless: true)
            }
            if name == "calendar" {
                try add("calendar-expanded-settings-calendar", vm, tab: .settings, section: .calendar)
            }
            if name == "day" {
                // An 8-hour day seen at four times: morning, midday,
                // afternoon and evening (each icon and sign once).
                let hour = 3_600_000
                for (label, hoursIn) in [("morning", -1.5), ("midday", 3.0), ("afternoon", 6.0), ("evening", 10.5)] {
                    var at = vm
                    let start = snapshotNowMs - Int(hoursIn * Double(hour))
                    at.day?.startMs = start
                    at.day?.endMs = start + 8 * hour
                    at.compact.endsAtMs = start + 8 * hour
                    at.compact.totalSecs = 8 * 3600
                    try add("day-\(label)-closed", at, expanded: false)
                    try add("notchless-day-\(label)-closed", at, expanded: false, notchless: true)
                    try add("day-\(label)-expanded-home", at)
                    var tree = at
                    tree.settings.day.icons = .tree
                    try add("day-tree-\(label)-closed", tree, expanded: false)
                    try add("day-tree-\(label)-expanded-home", tree)
                }
                try add("day-expanded-settings-home", vm, tab: .settings, section: .home)
                var treeSettings = vm
                treeSettings.settings.day.enabled = true
                treeSettings.settings.day.icons = .tree
                try add("day-expanded-settings-day", treeSettings, tab: .settings, section: .day)
                var music = vm
                music.settings.day.homeCard = .media
                try add("day-music-card-expanded-home", music)
            }
            if name == "approval" {
                var long = vm
                long.agents.pending[0].truncated = true
                long.agents.pending[0].detail = String(repeating: "rm -rf build && cargo build --release --target aarch64-apple-darwin && ", count: 8)
                long.agents.pending.append(long.agents.pending[0])
                long.agents.pending[1].id = "req-2"
                try add("approval-truncated-expanded", long)
                func asking(_ qs: [AgentQuestion]) -> ViewModel {
                    var v = vm
                    v.agents.pending[0].toolName = "AskUserQuestion"
                    v.agents.pending[0].questions = qs
                    return v
                }
                let pg = QuestionOption(label: "Postgres", description: "Relational, what the team already runs")
                let lite = QuestionOption(label: "SQLite", description: "Embedded, one file")
                let single = AgentQuestion(header: "Database", question: "Which database should the service use?",
                                           options: [pg, lite, QuestionOption(label: "DynamoDB", description: "Managed key-value")])
                let multi = AgentQuestion(header: "Checks", question: "Which checks should run before merging?", multiSelect: true,
                                          options: [QuestionOption(label: "Unit tests", description: "cargo test"),
                                                    QuestionOption(label: "Clippy", description: "-D warnings"),
                                                    QuestionOption(label: "Benchmarks", description: "scripts/bench.sh")])
                let open = AgentQuestion(header: "Name", question: "What should the new command be called?", options: [])
                try add("question-single-expanded", asking([single]))
                try add("question-multi-expanded", asking([multi]))
                try add("question-open-expanded", asking([open]))
                try add("question-steps-expanded", asking([single, multi, open]))
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
                // A colour that is no preset: the hue strip shows, knob on purple.
                var custom = vm
                custom.settings.appearance.accent = "#BF5AF2"
                try add("accent-custom-expanded-settings-general", custom, tab: .settings, section: .general)
                // Black/white: white on the dark panel, black on the light one.
                var mono = vm
                mono.settings.appearance.accent = "mono"
                try add("accent-mono-expanded-settings-general", mono, tab: .settings, section: .general)
                try add("accent-mono-expanded-home", mono)
                var monoLight = light
                monoLight.settings.appearance.accent = "mono"
                try add("accent-mono-light-expanded-settings-general", monoLight, tab: .settings, section: .general)
                try add("accent-mono-light-expanded-home", monoLight)
                // Liquid Glass chosen. ImageRenderer draws no glass (the
                // window server makes it), so these show the Solid fallback
                // and the Settings row as this build and system offer it.
                var glass = vm
                glass.settings.appearance.material = .glass
                try add("glass-media-expanded-home", glass)
                try add("glass-media-expanded-settings-general", glass, tab: .settings, section: .general)
                try add("glass-media-closed", glass, expanded: false)
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
                      nowMs: Int = snapshotNowMs, backdrop: Bool = false,
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
        let offset = nowMs - Int(Date().timeIntervalSince1970 * 1000)
        // "System" renders dark; light variants set the theme explicitly.
        let scheme: ColorScheme = vm.settings.appearance.theme == .light ? .light : .dark
        let root = NotchRootView(model: model.primary)
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.clockOffsetMs, offset)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(backdrop ? AnyView(PreviewRenderer.backdrop) : AnyView(Color(white: 0.5)))
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try data.write(to: url)
        return url
    }
}
