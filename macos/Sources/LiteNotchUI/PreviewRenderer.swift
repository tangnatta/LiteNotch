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
        var notchless = false
        /// A question form already part-answered.
        var draft: QuestionDraft?
        /// The clock at the shot's first frame, where the scene's own
        /// running clock would be wrong for the fixture.
        var at: Int?
    }

    struct Scene {
        var name: String
        /// 110 for previews that never open the panel.
        var height: CGFloat = 320
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
                    _ = try SnapshotRenderer.write(
                        shot.vm, expanded: shot.expanded, tab: shot.tab, section: shot.section,
                        pane: shot.pane, timerPane: shot.timerPane, clipPreview: shot.clipPreview,
                        notchless: shot.notchless,
                        nowMs: clock, backdrop: true,
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
        let approval = try load("approval")
        let checking = try load("update-checking")
        let available = try load("update-available")
        let upToDate = try load("update-current")
        let day = try load("day")
        let banner = try load("banner")
        let caffeine = try load("caffeine")
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
        var shrunk = idle
        shrunk.settings.appearance.shrink = .whenEmpty
        var light = media
        light.settings.appearance.theme = .light
        var purple = light
        purple.settings.appearance.accent = "#BF5AF2"
        var blue = media
        blue.settings.appearance.accent = "#0A84FF"

        var colored = media
        colored.colors = ["#FF9E0A", "#0A84FF", "#30D158", "#1E1E1E", "#F5F5F7", "#BF5AF2"]
        let image = media.clipboard.items.first { $0.kind == .image }?.id
        let files = media.clipboard.items.first { $0.kind == .files }?.id

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
        func asIsland(_ vm: ViewModel) -> ViewModel {
            var v = vm
            v.settings.appearance.notchStyle = .island
            return v
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
        var daySettings = day
        daySettings.settings.day.icons = .tree

        var truncated = approval
        truncated.agents.pending[0].truncated = true
        truncated.agents.pending[0].detail = String(
            repeating: "rm -rf build && cargo build --release --target aarch64-apple-darwin && ", count: 8)

        return [
            // The island style: a capsule inside the menu bar, on a Mac with a
            // notch and then on a display without one.
            Scene(
                name: "island",
                shots: [
                    Shot(vm: asIsland(idle), secs: 1, expanded: false),
                    Shot(vm: asIsland(media), secs: 2, expanded: false),
                    Shot(vm: asIsland(pomodoro), secs: 2, expanded: false),
                    Shot(vm: asIsland(pair), secs: 2, expanded: false),
                    Shot(vm: asIsland(banner), secs: 2, expanded: false),
                    Shot(vm: asIsland(media), secs: 3),
                    Shot(vm: asIsland(pomodoro), secs: 2, tab: .timer),
                    Shot(vm: asIsland(asking([single])), secs: 3),
                    Shot(vm: asIsland(pair), secs: 2, expanded: false, notchless: true),
                    Shot(vm: asIsland(media), secs: 3, notchless: true),
                ]),
            Scene(
                name: "approvals",
                shots: [
                    Shot(vm: approval, secs: 3),
                    Shot(vm: truncated, secs: 3),
                ]),
            Scene(
                name: "question-single",
                shots: [
                    Shot(vm: asking([single]), secs: 3),
                    Shot(vm: asking([single]), secs: 2, draft: draft([single]) { $0.toggle("SQLite", in: 0) }),
                ]),
            Scene(
                name: "question-multi",
                shots: [
                    Shot(vm: asking([multi]), secs: 2),
                    Shot(vm: asking([multi]), secs: 2, draft: draft([multi]) { $0.toggle("Unit tests", in: 0) }),
                    Shot(
                        vm: asking([multi]), secs: 3,
                        draft: draft([multi]) {
                            $0.toggle("Unit tests", in: 0)
                            $0.toggle("Clippy", in: 0)
                        }),
                    Shot(
                        vm: asking([multi]), secs: 3,
                        draft: draft([multi]) {
                            $0.toggle("Unit tests", in: 0)
                            $0.type("Accessibility audit", in: 0)
                            $0.commit(0)
                            $0.type("Manual smoke test", in: 0)
                        }),
                ]),
            Scene(
                name: "question-open",
                shots: [
                    Shot(vm: asking([open]), secs: 2),
                    Shot(vm: asking([open]), secs: 3, draft: draft([open]) { $0.type("greet", in: 0) }),
                ]),
            Scene(
                name: "question-steps",
                shots: [
                    Shot(vm: asking([single, multi, open]), secs: 2),
                    Shot(
                        vm: asking([single, multi, open]), secs: 2,
                        draft: draft([single, multi, open]) {
                            $0.toggle("SQLite", in: 0)
                            $0.next()
                        }),
                    Shot(
                        vm: asking([single, multi, open]), secs: 2,
                        draft: draft([single, multi, open]) {
                            $0.toggle("SQLite", in: 0)
                            $0.next()
                            $0.toggle("Clippy", in: 1)
                            $0.next()
                        }),
                    Shot(
                        vm: asking([single, multi, open]), secs: 3,
                        draft: draft([single, multi, open]) {
                            $0.toggle("SQLite", in: 0)
                            $0.next()
                            $0.toggle("Clippy", in: 1)
                            $0.next()
                            $0.type("greet", in: 2)
                        }),
                ]),
            Scene(
                name: "update",
                shots: [
                    Shot(vm: media, secs: 2, tab: .settings, section: .general),
                    Shot(vm: checking, secs: 2, tab: .settings, section: .general),
                    Shot(vm: available, secs: 4, tab: .settings, section: .general),
                    Shot(vm: upToDate, secs: 3, tab: .settings, section: .general),
                ]),
            Scene(
                name: "settings",
                shots: SettingsSection.allCases.map {
                    Shot(vm: media, secs: 2, tab: .settings, section: $0)
                }),
            Scene(
                name: "overview",
                shots: [
                    Shot(vm: idle, secs: 1, expanded: false),
                    Shot(vm: media, secs: 2, expanded: false),
                    Shot(vm: media, secs: 3),
                    Shot(vm: media, secs: 2, tab: .timer),
                    Shot(vm: media, secs: 2, tab: .clipboard),
                    Shot(vm: media, secs: 2, tab: .agents),
                ]),
            Scene(
                name: "music",
                shots: [
                    Shot(vm: track, secs: 2, expanded: false),
                    Shot(vm: media, secs: 2, expanded: false),
                    Shot(vm: media, secs: 3, tab: .music),
                ]),
            Scene(
                name: "focus",
                shots: [
                    Shot(vm: pomodoro, secs: 3, expanded: false),
                    Shot(vm: pomodoro, secs: 3, tab: .timer),
                    Shot(vm: warning, secs: 2, expanded: false, at: fiveLeft),
                    Shot(vm: quote, secs: 2, expanded: false),
                ]),
            Scene(
                name: "meeting",
                shots: [
                    Shot(vm: pomodoro, secs: 2, tab: .timer, timerPane: .meeting),
                    Shot(vm: running, secs: 3, tab: .timer, timerPane: .meeting),
                    Shot(vm: running, secs: 2, expanded: false),
                    Shot(vm: over, secs: 2, expanded: false),
                    Shot(vm: over, secs: 2, tab: .timer, timerPane: .meeting),
                ]),
            Scene(
                name: "countdown",
                shots: [
                    Shot(vm: pomodoro, secs: 2, tab: .timer, timerPane: .countdown),
                    Shot(vm: countdown, secs: 3, tab: .timer, timerPane: .countdown),
                    Shot(vm: countdown, secs: 3, expanded: false),
                ]),
            Scene(
                name: "calendar",
                shots: [
                    Shot(vm: calendar, secs: 3),
                    Shot(vm: calendar, secs: 3, expanded: false),
                    Shot(vm: pair, secs: 2, expanded: false),
                    Shot(vm: starting, secs: 3, expanded: false),
                ]),
            Scene(
                name: "clipboard",
                shots: [
                    Shot(vm: media, secs: 2, tab: .clipboard),
                    Shot(vm: media, secs: 2, tab: .clipboard, clipPreview: image),
                    Shot(vm: media, secs: 2, tab: .clipboard, clipPreview: files),
                    Shot(vm: colored, secs: 2, tab: .clipboard),
                ]),
            Scene(
                name: "agents",
                shots: [
                    Shot(vm: media, secs: 2, tab: .agents),
                    Shot(vm: dot, secs: 2, expanded: false),
                    Shot(vm: media, secs: 3, tab: .agents, pane: .usage),
                ]),
            Scene(
                name: "notch-priority",
                shots: [
                    Shot(vm: pair, secs: 3, expanded: false),
                    Shot(vm: pair, secs: 4, tab: .settings, section: .notch),
                ]),
            Scene(
                name: "peeks", height: 110,
                shots: [
                    Shot(vm: track, secs: 2, expanded: false),
                    Shot(vm: warning, secs: 2, expanded: false, at: fiveLeft),
                    Shot(vm: eye, secs: 2, expanded: false),
                    Shot(vm: move, secs: 3, expanded: false),
                    Shot(vm: quote, secs: 3, expanded: false),
                ]),
            Scene(
                name: "appearance",
                shots: [
                    Shot(vm: pomodoro, secs: 2),
                    Shot(vm: island, secs: 2),
                    Shot(vm: islandPair, secs: 2, expanded: false, notchless: true),
                    Shot(vm: shrunk, secs: 1, expanded: false, notchless: true),
                    Shot(vm: light, secs: 2),
                    Shot(vm: purple, secs: 2),
                    Shot(vm: blue, secs: 3, tab: .settings, section: .general),
                ]),
            Scene(
                name: "inbox",
                shots: [
                    Shot(vm: banner, secs: 3, expanded: false),
                    Shot(vm: banner, secs: 3, tab: .inbox),
                ]),
            // Day progress: the sun and moon through the day, then the tree
            // growing (seed, leaves, sapling, young tree, full tree).
            Scene(
                name: "day",
                shots: [
                    Shot(vm: dayAt(-1.5), secs: 2, expanded: false),
                    Shot(vm: dayAt(3), secs: 2, expanded: false),
                    Shot(vm: dayAt(3), secs: 3),
                    Shot(vm: dayAt(10.5), secs: 2, expanded: false),
                    Shot(vm: dayAt(-1.5, tree: true), secs: 1, expanded: false),
                    Shot(vm: dayAt(1.5, tree: true), secs: 1, expanded: false),
                    Shot(vm: dayAt(4, tree: true), secs: 1, expanded: false),
                    Shot(vm: dayAt(6.5, tree: true), secs: 1, expanded: false),
                    Shot(vm: dayAt(9, tree: true), secs: 2, expanded: false),
                    Shot(vm: dayAt(4, tree: true), secs: 3),
                    Shot(vm: daySettings, secs: 3, tab: .settings, section: .day),
                ]),
            Scene(
                name: "keep-awake",
                shots: [
                    Shot(vm: caffeine, secs: 2, expanded: false),
                    Shot(vm: caffeine, secs: 3, tab: .settings, section: .keepAwake),
                ]),
        ]
    }
}
