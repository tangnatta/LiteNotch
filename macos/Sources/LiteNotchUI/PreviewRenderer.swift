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
        LinearGradient(colors: [Color(red: 0.27, green: 0.33, blue: 0.52),
                                Color(red: 0.45, green: 0.36, blue: 0.56),
                                Color(red: 0.80, green: 0.52, blue: 0.48)],
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
        let idle = try load("idle"), media = try load("media"), pomodoro = try load("pomodoro")
        let pair = try load("pair"), calendar = try load("calendar"), approval = try load("approval")
        let banner = try load("banner"), caffeine = try load("caffeine")
        let track = try load("peek-track"), warning = try load("peek-warning")
        let eye = try load("peek-eye-break"), move = try load("peek-move"), quote = try load("peek-quote")
        let now = SnapshotRenderer.snapshotNowMs
        // The warning fixture is taken 20 minutes into a 25-minute focus.
        let fiveLeft = now - 90_000 + 20 * 60_000 + 1000

        var floating = pomodoro
        floating.settings.appearance.notchStyle = .floating
        var floatingPair = pair
        floatingPair.settings.appearance.notchStyle = .floating
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
        countdown.compact = CompactView(kind: .timer, title: "Timer", value: "",
                                        endsAtMs: countdown.timer.endsAtMs, totalSecs: 300, count: 0)

        var starting = pair
        starting.inbox.banner = NotificationItem(id: 99, source: "calendar", title: "Design review",
                                                 body: "Starting now \u{b7} Room 3", priority: .high, group: nil,
                                                 ttlSecs: nil, createdMs: now, read: false,
                                                 open: .tab(.home, pane: nil), action: .pauseFocus)
        var dot = pair
        dot.compact = CompactView(kind: .idle, title: "", value: "", endsAtMs: nil, totalSecs: nil, count: 0)
        dot.compactSecondary = nil

        let running = SnapshotRenderer.meeting(pomodoro, "running")
        let over = SnapshotRenderer.meeting(pomodoro, "over")

        return [
            Scene(name: "overview", shots: [
                Shot(vm: idle, secs: 1, expanded: false),
                Shot(vm: media, secs: 2, expanded: false),
                Shot(vm: media, secs: 3),
                Shot(vm: media, secs: 2, tab: .timer),
                Shot(vm: media, secs: 2, tab: .clipboard),
                Shot(vm: media, secs: 2, tab: .agents),
            ]),
            Scene(name: "music", shots: [
                Shot(vm: track, secs: 2, expanded: false),
                Shot(vm: media, secs: 2, expanded: false),
                Shot(vm: media, secs: 3, tab: .music),
            ]),
            Scene(name: "focus", shots: [
                Shot(vm: pomodoro, secs: 3, expanded: false),
                Shot(vm: pomodoro, secs: 3, tab: .timer),
                Shot(vm: warning, secs: 2, expanded: false, at: fiveLeft),
                Shot(vm: quote, secs: 2, expanded: false),
            ]),
            Scene(name: "meeting", shots: [
                Shot(vm: pomodoro, secs: 2, tab: .timer, timerPane: .meeting),
                Shot(vm: running, secs: 3, tab: .timer, timerPane: .meeting),
                Shot(vm: running, secs: 2, expanded: false),
                Shot(vm: over, secs: 2, expanded: false),
                Shot(vm: over, secs: 2, tab: .timer, timerPane: .meeting),
            ]),
            Scene(name: "countdown", shots: [
                Shot(vm: pomodoro, secs: 2, tab: .timer, timerPane: .countdown),
                Shot(vm: countdown, secs: 3, tab: .timer, timerPane: .countdown),
                Shot(vm: countdown, secs: 3, expanded: false),
            ]),
            Scene(name: "calendar", shots: [
                Shot(vm: calendar, secs: 3),
                Shot(vm: calendar, secs: 3, expanded: false),
                Shot(vm: pair, secs: 2, expanded: false),
                Shot(vm: starting, secs: 3, expanded: false),
            ]),
            Scene(name: "clipboard", shots: [
                Shot(vm: media, secs: 2, tab: .clipboard),
                Shot(vm: media, secs: 2, tab: .clipboard, clipPreview: image),
                Shot(vm: media, secs: 2, tab: .clipboard, clipPreview: files),
                Shot(vm: colored, secs: 2, tab: .clipboard),
            ]),
            Scene(name: "agents", shots: [
                Shot(vm: approval, secs: 3),
                Shot(vm: media, secs: 2, tab: .agents),
                Shot(vm: dot, secs: 2, expanded: false),
                Shot(vm: media, secs: 3, tab: .agents, pane: .usage),
            ]),
            Scene(name: "notch-priority", shots: [
                Shot(vm: pair, secs: 3, expanded: false),
                Shot(vm: pair, secs: 4, tab: .settings, section: .notch),
            ]),
            Scene(name: "peeks", height: 110, shots: [
                Shot(vm: track, secs: 2, expanded: false),
                Shot(vm: warning, secs: 2, expanded: false, at: fiveLeft),
                Shot(vm: eye, secs: 2, expanded: false),
                Shot(vm: move, secs: 3, expanded: false),
                Shot(vm: quote, secs: 3, expanded: false),
            ]),
            Scene(name: "appearance", shots: [
                Shot(vm: pomodoro, secs: 2),
                Shot(vm: floating, secs: 2),
                Shot(vm: floatingPair, secs: 2, expanded: false, notchless: true),
                Shot(vm: shrunk, secs: 1, expanded: false, notchless: true),
                Shot(vm: light, secs: 2),
                Shot(vm: purple, secs: 2),
                Shot(vm: blue, secs: 3, tab: .settings, section: .general),
            ]),
            Scene(name: "inbox", shots: [
                Shot(vm: banner, secs: 3, expanded: false),
                Shot(vm: banner, secs: 3, tab: .inbox),
            ]),
            Scene(name: "keep-awake", shots: [
                Shot(vm: caffeine, secs: 2, expanded: false),
                Shot(vm: caffeine, secs: 3, tab: .settings, section: .keepAwake),
            ]),
        ]
    }
}
