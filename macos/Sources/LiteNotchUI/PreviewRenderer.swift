import AppKit
import SwiftUI

/// Renders the README's previews: for each feature a short run of frames,
/// one per second of the clock, drawn by the real views from the fixtures.
/// `scripts/previews.sh` turns each folder of frames into a GIF.
public enum PreviewRenderer {
    /// One stretch of a preview: a screen held for some seconds while the
    /// clock runs, so countdowns tick.
    struct Shot {
        var vm: ViewModel
        var secs: Int
        var expanded = true
        var tab: Tab = .home
        var section: SettingsSection = .general
        var pane: AgentsPane = .sessions
        var timerPane: TimerPane = .focus
        var clipPreview: Int?
        var calendarPage: CalendarPage = .list
        var notchless = false
        /// A question form already part-answered.
        var draft: QuestionDraft?
        /// The clock at the shot's first frame, where the scene's own
        /// running clock would be wrong for the fixture.
        var at: Int?
        /// Words a scrolling title moves on per frame (it scrolls in the
        /// app; a still frame would cut it off).
        var scroll = 0
    }

    /// A closed notch is a thin strip in a 680 pt wide frame; enlarged it
    /// can be read at the README's width.
    static let closedZoom: CGFloat = 1.6

    struct Scene {
        var name: String
        /// 110 for previews that never open the panel.
        var height: CGFloat = 320
        /// How much a closed notch is enlarged; a peek is too wide for more.
        var zoom: CGFloat = closedZoom
        var shots: [Shot]
    }

    /// Something calmer than the snapshots' flat grey to sit behind the notch.
    static var backdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.27, green: 0.33, blue: 0.52),
                Color(red: 0.45, green: 0.36, blue: 0.56),
                Color(red: 0.80, green: 0.52, blue: 0.48),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @MainActor
    public static func renderAll(fixturesDir: URL, outDir: URL) throws -> [URL] {
        func load(_ name: String) throws -> ViewModel {
            try ViewModel.decode(Data(contentsOf: fixturesDir.appendingPathComponent("\(name).json")))
        }
        var written: [URL] = []
        for scene in try scenes(load) {
            let dir = outDir.appendingPathComponent(scene.name)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var frame = 0
            for shot in scene.shots {
                for i in 0..<shot.secs {
                    frame += 1
                    let clock = shot.at.map { $0 + i * 1000 } ?? SnapshotRenderer.snapshotNowMs + frame * 1000
                    let url = dir.appendingPathComponent(String(format: "f-%04d.png", frame))
                    QuestionForm.previewDraft = shot.draft
                    defer { QuestionForm.previewDraft = nil }
                    let open = NotchPresentation.mode(expanded: shot.expanded, view: shot.vm) == .expanded
                    _ = try SnapshotRenderer.write(
                        shot.vm, expanded: shot.expanded, tab: shot.tab, section: shot.section,
                        pane: shot.pane, timerPane: shot.timerPane, clipPreview: shot.clipPreview,
                        calendarPage: shot.calendarPage, notchless: shot.notchless,
                        nowMs: clock, backdrop: true,
                        zoom: open ? 1 : scene.zoom, marqueeShift: shot.scroll * i,
                        size: CGSize(width: 680, height: scene.height), to: url)
                }
            }
            written.append(dir)
        }
        return written
    }

    static func scenes(_ load: (String) throws -> ViewModel) throws -> [Scene] {
        let idle = try load("idle")
        let media = try load("media")
        let pomodoro = try load("pomodoro")
        let pair = try load("pair")
        let calendar = try load("calendar")
        let detail = try load("calendar-detail")
        let body = try load("body")
        let approval = try load("approval")
        let day = try load("day")
        let banner = try load("banner")
        let track = try load("peek-track")
        let warning = try load("peek-warning")
        let eye = try load("peek-eye-break")
        let move = try load("peek-move")
        let quote = try load("peek-quote")
        let now = SnapshotRenderer.snapshotNowMs
        // The warning fixture is taken 20 minutes into a 25-minute focus.
        let fiveLeft = now - 90_000 + 20 * 60_000 + 1000

        var island = pomodoro
        island.settings.appearance.notchStyle = .island
        var islandPair = pair
        islandPair.settings.appearance.notchStyle = .island
        var light = media
        light.settings.appearance.theme = .light
        var purple = light
        purple.settings.appearance.accent = "#BF5AF2"

        var colored = media
        colored.colors = ["#FF9E0A", "#0A84FF", "#30D158", "#1E1E1E", "#F5F5F7", "#BF5AF2"]
        let image = media.clipboard.items.first { $0.kind == .image }?.id

        var countdown = pomodoro
        countdown.timer.runState = .running
        countdown.timer.endsAtMs = now + 4 * 60_000 + 12_000
        countdown.compact = CompactView(
            kind: .timer, title: "Timer", value: "",
            endsAtMs: countdown.timer.endsAtMs, totalSecs: 300, count: 0)

        var starting = pair
        starting.inbox.banner = NotificationItem(
            id: 99, source: "calendar", title: "Design review",
            body: "Starting now \u{b7} Room 3", priority: .high, group: nil,
            ttlSecs: nil, createdMs: now, read: false,
            open: .tab(.home, pane: nil), action: .pauseFocus)
        var dot = pair
        dot.compact = CompactView(kind: .idle, title: "", value: "", endsAtMs: nil, totalSecs: nil, count: 0)
        dot.compactSecondary = nil

        let running = SnapshotRenderer.meeting(pomodoro, "running")
        let over = SnapshotRenderer.meeting(pomodoro, "over")

        // Questions, one scene per kind of layout.
        func asking(_ qs: [AgentQuestion]) -> ViewModel {
            var v = approval
            v.agents.pending[0].toolName = "AskUserQuestion"
            v.agents.pending[0].questions = qs
            return v
        }
        let pg = QuestionOption(label: "Postgres", description: "Relational, what the team already runs")
        let lite = QuestionOption(label: "SQLite", description: "Embedded, one file")
        let single = AgentQuestion(
            header: "Database", question: "Which database should the service use?",
            options: [pg, lite, QuestionOption(label: "DynamoDB", description: "Managed key-value")])
        let multi = AgentQuestion(
            header: "Checks", question: "Which checks should run before merging?", multiSelect: true,
            options: [
                QuestionOption(label: "Unit tests", description: "cargo test"),
                QuestionOption(label: "Clippy", description: "-D warnings"),
                QuestionOption(label: "Benchmarks", description: "scripts/bench.sh"),
            ])
        let open = AgentQuestion(header: "Name", question: "What should the new command be called?", options: [])
        func draft(_ qs: [AgentQuestion], _ edit: (inout QuestionDraft) -> Void) -> QuestionDraft {
            var d = QuestionDraft(qs)
            edit(&d)
            return d
        }
        // An 8-hour day seen `hoursIn` hours after it starts (negative: before).
        func dayAt(_ hoursIn: Double, tree: Bool = false) -> ViewModel {
            var v = day
            let start = now - Int(hoursIn * 3_600_000)
            v.day?.startMs = start
            v.day?.endMs = start + 8 * 3_600_000
            v.compact.endsAtMs = start + 8 * 3_600_000
            v.compact.totalSecs = 8 * 3600
            if tree { v.settings.day.icons = .tree }
            return v
        }

        // The gauges as the fixture took them, 5 min after a cup, moved so
        // that moment is the scene's start.
        var gauges = body
        let gaugeShift = now - ((body.body?.water?.lastMs ?? 0) + 5 * 60_000)
        func moved(_ g: GaugeView?) -> GaugeView? {
            g.map {
                var g = $0
                g.emptyAtMs = g.emptyAtMs.map { $0 + gaugeShift }
                g.lastMs = g.lastMs.map { $0 + gaugeShift }
                return g
            }
        }
        gauges.body?.water = moved(body.body?.water)
        gauges.body?.stretch = moved(body.body?.stretch)
        var gaugeClosed = gauges
        gaugeClosed.compact = CompactView(
            kind: .body, title: "Stretch", value: "", endsAtMs: gauges.body?.stretch?.emptyAtMs,
            totalSecs: (gauges.body?.stretch?.spanMs ?? 0) / 1000, count: 0)
        gaugeClosed.compactSecondary = nil
        let event = detail.calendar.detail.map { CalendarPage.event($0.key) } ?? .list
        let edit = detail.calendar.detail.map { CalendarPage.edit($0.key) } ?? .list

        var truncated = approval
        truncated.agents.pending[0].truncated = true
        truncated.agents.pending[0].detail = String(
            repeating: "rm -rf build && cargo build --release --target aarch64-apple-darwin && ", count: 8)

        // Thirteen scenes, one per README section, none longer than about
        // twelve seconds; each screen appears in one of them only.
        return [
            // The hero: closed, then the panel's main tabs, then the reason
            // to connect Claude Code.
            Scene(
                name: "overview",
                shots: [
                    Shot(vm: idle, secs: 1, expanded: false),
                    Shot(vm: media, secs: 2, expanded: false),
                    Shot(vm: media, secs: 2),
                    Shot(vm: media, secs: 2, tab: .timer),
                    Shot(vm: media, secs: 2, tab: .clipboard),
                    Shot(vm: approval, secs: 3),
                ]),
            Scene(
                name: "approvals",
                shots: [
                    Shot(vm: approval, secs: 3),
                    Shot(vm: truncated, secs: 3),
                ]),
            // Every layout in one run: a single choice, a multiple choice
            // with an answer of the user's own, then an open question.
            Scene(
                name: "questions",
                shots: [
                    Shot(vm: asking([single, multi, open]), secs: 2),
                    Shot(
                        vm: asking([single, multi, open]), secs: 2,
                        draft: draft([single, multi, open]) {
                            $0.toggle("SQLite", in: 0)
                            $0.next()
                        }),
                    Shot(
                        vm: asking([single, multi, open]), secs: 3,
                        draft: draft([single, multi, open]) {
                            $0.toggle("SQLite", in: 0)
                            $0.next()
                            $0.toggle("Clippy", in: 1)
                            $0.type("Accessibility audit", in: 1)
                            $0.commit(1)
                        }),
                    Shot(
                        vm: asking([single, multi, open]), secs: 3,
                        draft: draft([single, multi, open]) {
                            $0.toggle("SQLite", in: 0)
                            $0.next()
                            $0.toggle("Clippy", in: 1)
                            $0.type("Accessibility audit", in: 1)
                            $0.commit(1)
                            $0.next()
                            $0.type("greet", in: 2)
                        }),
                ]),
            Scene(
                name: "agents",
                shots: [
                    Shot(vm: media, secs: 2, tab: .agents),
                    Shot(vm: dot, secs: 2, expanded: false),
                    Shot(vm: media, secs: 3, tab: .agents, pane: .usage),
                ]),
            Scene(
                name: "music",
                shots: [
                    Shot(vm: media, secs: 2, expanded: false),
                    Shot(vm: media, secs: 3, tab: .music),
                ]),
            // Focus, a meeting agenda and a countdown: the Timer tab's three panes.
            Scene(
                name: "timer",
                shots: [
                    Shot(vm: pomodoro, secs: 2, expanded: false),
                    Shot(vm: pomodoro, secs: 2, tab: .timer),
                    Shot(vm: running, secs: 2, tab: .timer, timerPane: .meeting),
                    Shot(vm: over, secs: 2, expanded: false),
                    Shot(vm: countdown, secs: 2, tab: .timer, timerPane: .countdown),
                ]),
            Scene(
                name: "calendar",
                shots: [
                    Shot(vm: calendar, secs: 2, tab: .calendar),
                    Shot(vm: detail, secs: 3, tab: .calendar, calendarPage: event),
                    Shot(vm: detail, secs: 2, tab: .calendar, calendarPage: edit),
                    Shot(vm: calendar, secs: 2, expanded: false),
                    Shot(vm: starting, secs: 3, expanded: false),
                ]),
            Scene(
                name: "clipboard",
                shots: [
                    Shot(vm: media, secs: 2, tab: .clipboard),
                    Shot(vm: media, secs: 2, tab: .clipboard, clipPreview: image),
                    Shot(vm: colored, secs: 2, tab: .clipboard),
                ]),
            Scene(
                name: "inbox",
                shots: [
                    Shot(vm: banner, secs: 2, expanded: false),
                    Shot(vm: banner, secs: 3, tab: .inbox),
                ]),
            // The sun, then the tree growing, then Home's day card with each.
            Scene(
                name: "day",
                shots: [
                    Shot(vm: dayAt(3), secs: 2, expanded: false),
                    Shot(vm: dayAt(10.5), secs: 1, expanded: false),
                    Shot(vm: dayAt(-1.5, tree: true), secs: 1, expanded: false),
                    Shot(vm: dayAt(4, tree: true), secs: 1, expanded: false),
                    Shot(vm: dayAt(9, tree: true), secs: 1, expanded: false),
                    Shot(vm: dayAt(4, tree: true), secs: 2),
                    // With the sun, Home's card is a sky for the part of the day.
                    Shot(vm: dayAt(6.5), secs: 3),
                ]),
            // The gauge in the closed notch, then Home's tanks and where
            // they are set.
            Scene(
                name: "body",
                shots: [
                    Shot(vm: gaugeClosed, secs: 2, expanded: false),
                    Shot(vm: gauges, secs: 3),
                    Shot(vm: gauges, secs: 3, tab: .settings, section: .day),
                ]),
            Scene(
                name: "notch-priority",
                shots: [
                    Shot(vm: pair, secs: 3, expanded: false),
                    Shot(vm: pair, secs: 3, tab: .settings, section: .notch),
                ]),
            // A long line scrolls in the app; here it moves along per frame.
            Scene(
                name: "peeks", height: 110, zoom: 1,
                shots: [
                    Shot(vm: track, secs: 3, expanded: false, scroll: 2),
                    Shot(vm: warning, secs: 2, expanded: false, at: fiveLeft),
                    Shot(vm: eye, secs: 2, expanded: false),
                    Shot(vm: move, secs: 3, expanded: false, scroll: 2),
                    Shot(vm: quote, secs: 3, expanded: false, scroll: 2),
                ]),
            Scene(
                name: "appearance",
                shots: [
                    Shot(vm: pomodoro, secs: 2),
                    Shot(vm: island, secs: 2),
                    Shot(vm: islandPair, secs: 2, expanded: false, notchless: true),
                    Shot(vm: light, secs: 2),
                    Shot(vm: purple, secs: 2),
                ]),
        ]
    }
}
