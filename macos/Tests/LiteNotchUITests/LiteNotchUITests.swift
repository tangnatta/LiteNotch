import AppKit
import SwiftUI
import XCTest
@testable import LiteNotchUI

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
}

private func loadFixture(_ name: String) throws -> ViewModel {
    try ViewModel.decode(Data(contentsOf: fixtureURL(name)))
}

private func obj(_ s: String) throws -> NSDictionary {
    try JSONSerialization.jsonObject(with: Data(s.utf8)) as! NSDictionary
}

final class DecodingTests: XCTestCase {
    func testIdle() throws {
        let v = try loadFixture("idle")
        XCTAssertEqual(v.compact.kind, .idle)
        XCTAssertFalse(v.attention)
        XCTAssertNil(v.media)
        XCTAssertNil(v.agents.hooksInstalled)
        XCTAssertNil(v.usage.fiveHour)
        XCTAssertEqual(v.pomodoro.phase, .idle)
        XCTAssertEqual(v.pomodoro.remainingSecs, 1500)
        XCTAssertTrue(v.clipboard.items.isEmpty)
        XCTAssertEqual(v.usage.week.count, 7)
        XCTAssertEqual(v.usage.week.last?.tokens, v.usage.today.input + v.usage.today.output)
        XCTAssertFalse(v.settings.notify.system)
        XCTAssertTrue(v.settings.media.enabled)
    }

    func testPomodoro() throws {
        let v = try loadFixture("pomodoro")
        XCTAssertEqual(v.compact.kind, .pomodoro)
        XCTAssertEqual(v.compact.endsAtMs, 1_794_401_500_000)
        XCTAssertEqual(v.compact.totalSecs, 1500)
        XCTAssertEqual(v.pomodoro.phase, .focus)
        XCTAssertEqual(v.pomodoro.runState, .running)
        XCTAssertEqual(v.settings.pomodoro.focusSecs, 1500)
        XCTAssertEqual(v.clipboard.items.count, 5)
        XCTAssertEqual(v.clipboard.items[1].kind, .image)
        XCTAssertEqual(v.clipboard.items[3].kind, .files)
        XCTAssertTrue(v.clipboard.items[0].pinned)
    }

    func testMedia() throws {
        let v = try loadFixture("media")
        XCTAssertEqual(v.compact.kind, .media)
        XCTAssertEqual(v.compact.title, "Weightless")
        let m = try XCTUnwrap(v.media)
        XCTAssertEqual(m.artist, "Marconi Union")
        XCTAssertTrue(m.playing)
        XCTAssertEqual(m.durationMs, 480_000)
        XCTAssertEqual(m.positionMs, 95_000)
        XCTAssertEqual(m.positionAtMs, 1_794_400_000_000)
        XCTAssertTrue(m.controllable)
        XCTAssertNil(m.artworkPath)
        XCTAssertEqual(v.usage.week.count, 7)
        XCTAssertEqual(v.usage.week.first?.dayStartMs, 1_793_836_800_000)
        XCTAssertEqual(v.usage.week.last, UsageDay(dayStartMs: 1_794_355_200_000, tokens: 832_000, messages: 3))
        XCTAssertEqual(v.usage.models.first, UsageShare(name: "fable-5-2", tokens: 610_000))
        XCTAssertEqual(v.usage.projects.map(\.name), ["litenotch", "api-gateway", "docs"])
        XCTAssertTrue(v.usage.summary.hasPrefix("832k tokens today across 3 projects"))
    }

    func testArtworkPathDecodes() throws {
        let json = try String(contentsOf: fixtureURL("media"), encoding: .utf8)
            .replacingOccurrences(of: "\"controllable\": true", with: "\"controllable\": true, \"artwork_path\": \"/tmp/a.png\"")
        XCTAssertEqual(try ViewModel.decode(Data(json.utf8)).media?.artworkPath, "/tmp/a.png")
    }

    /// An older core sends none of the newer fields; a confused one sends
    /// the wrong types. Neither may cost the shell its view model.
    func testNewerFieldsDecodeLeniently() throws {
        var o = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("media"))) as! [String: Any]
        var usage = o["usage"] as! [String: Any]
        for k in ["week", "models", "projects", "summary"] { usage.removeValue(forKey: k) }
        o["usage"] = usage
        var settings = o["settings"] as! [String: Any]
        settings.removeValue(forKey: "media")
        var notify = settings["notify"] as! [String: Any]
        notify.removeValue(forKey: "system")
        settings["notify"] = notify
        o["settings"] = settings
        let old = try ViewModel.decode(JSONSerialization.data(withJSONObject: o))
        XCTAssertEqual(old.usage.week, [])
        XCTAssertEqual(old.usage.models, [])
        XCTAssertEqual(old.usage.projects, [])
        XCTAssertEqual(old.usage.summary, "")
        XCTAssertEqual(old.usage.fiveHour?.usedPct, 42.0)
        XCTAssertTrue(old.settings.media.enabled)
        XCTAssertFalse(old.settings.notify.system)

        usage["week"] = "soon"; usage["models"] = [["name": 3]]; usage["projects"] = 7; usage["summary"] = ["x"]
        o["usage"] = usage
        let odd = try ViewModel.decode(JSONSerialization.data(withJSONObject: o))
        XCTAssertEqual(odd.usage.week, [])
        XCTAssertEqual(odd.usage.models, [])
        XCTAssertEqual(odd.usage.projects, [])
        XCTAssertEqual(odd.usage.summary, "")
    }

    func testApproval() throws {
        let v = try loadFixture("approval")
        XCTAssertTrue(v.attention)
        XCTAssertEqual(v.compact.kind, .approval)
        XCTAssertEqual(v.compact.value, "Bash")
        XCTAssertEqual(v.compact.count, 1)
        let p = try XCTUnwrap(v.agents.pending.first)
        XCTAssertEqual(p.id, "req-1")
        XCTAssertEqual(p.toolName, "Bash")
        XCTAssertFalse(p.truncated)
        XCTAssertEqual(p.expiresMs, 1_794_400_120_010)
        XCTAssertEqual(v.agents.sessions[0].status, .waitingApproval)
        XCTAssertEqual(v.agents.hooksInstalled, true)
        XCTAssertEqual(v.usage.fiveHour?.usedPct, 42.0)
        XCTAssertEqual(v.usage.sevenDay?.resetsAtMs, 1_794_800_000_000)
        XCTAssertEqual(v.usage.model, "Fable 5.2")
        XCTAssertEqual(v.caffeine.mode, .display)
        XCTAssertEqual(v.caffeine.untilMs, 1_794_403_600_000)
        XCTAssertTrue(v.inbox.dnd)
        XCTAssertEqual(v.analytics.first, FeatureCount(feature: "notification_shown", count: 2))
    }

    func testBanner() throws {
        let v = try loadFixture("banner")
        XCTAssertEqual(v.compact.kind, .banner)
        let b = try XCTUnwrap(v.inbox.banner)
        XCTAssertEqual(b.title, "Build failed on main")
        XCTAssertEqual(b.priority, .high)
        XCTAssertFalse(b.read)
        XCTAssertEqual(v.inbox.unread, 1)
        XCTAssertEqual(NotchPresentation.mode(expanded: false, view: v), .toast)
    }

    func testCaffeine() throws {
        let v = try loadFixture("caffeine")
        XCTAssertEqual(v.compact.kind, .caffeine)
        XCTAssertEqual(v.compact.value, "lid")
        XCTAssertEqual(v.caffeine.lid, .on)
        XCTAssertNil(v.caffeine.untilMs)
        XCTAssertNil(v.caffeine.guardText)
    }

    func testUnknownEnumStringsDoNotCrash() throws {
        var json = try String(contentsOf: fixtureURL("approval"), encoding: .utf8)
        json = json.replacingOccurrences(of: "\"kind\": \"approval\"", with: "\"kind\": \"hologram\"")
            .replacingOccurrences(of: "\"phase\": \"focus\"", with: "\"phase\": \"nap\"")
            .replacingOccurrences(of: "\"status\": \"waiting_approval\"", with: "\"status\": \"levitating\"")
            .replacingOccurrences(of: "\"lid\": \"off\"", with: "\"lid\": \"ajar\"")
            .replacingOccurrences(of: "\"dnd_min_priority\": \"high\"", with: "\"dnd_min_priority\": \"urgent\"")
        let v = try ViewModel.decode(Data(json.utf8))
        XCTAssertEqual(v.compact.kind, .unknown)
        XCTAssertEqual(v.pomodoro.phase, .unknown)
        XCTAssertEqual(v.agents.sessions[0].status, .unknown)
        XCTAssertEqual(v.caffeine.lid, .unknown)
        XCTAssertEqual(v.settings.notify.dndMinPriority, .unknown)
        // Unknown values are omitted when settings are sent back.
        let sent = try obj(ShellCommand.setSettings(v.settings).encode())
        let notify = ((sent["settings"] as! NSDictionary)["notify"]) as! NSDictionary
        XCTAssertNil(notify["dnd_min_priority"])
        XCTAssertEqual(notify["banner_secs"] as? Int, 5)
    }

    func testPermissionRequestWithoutTruncatedFieldDefaultsToFalse() throws {
        let j = #"{"id":"a","session_id":"s","project":"p","tool_name":"Bash","summary":"x","detail":"x","created_ms":1,"expires_ms":2}"#
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertFalse(try d.decode(PermissionRequest.self, from: Data(j.utf8)).truncated)
    }

    func testAppModelReceiveDecodesAndIgnoresGarbage() throws {
        let model = AppModel(bridge: MockBridge())
        model.receive(viewJSON: Data("not json".utf8))
        XCTAssertNil(model.view)
        model.receive(viewJSON: try Data(contentsOf: fixtureURL("media")))
        XCTAssertEqual(model.view?.media?.title, "Weightless")
    }

    func testAppModelReceiveFromBackgroundThread() throws {
        let model = AppModel(bridge: MockBridge())
        let data = try Data(contentsOf: fixtureURL("idle"))
        let exp = expectation(description: "published")
        DispatchQueue.global().async {
            model.receive(viewJSON: data)
            DispatchQueue.main.async { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2)
        XCTAssertNotNil(model.view)
    }
}

final class CommandTests: XCTestCase {
    func testEveryCommandEncodesToWhatRustExpects() throws {
        var settings = try loadFixture("idle").settings
        settings.pomodoro.focusSecs = 1800
        let cases: [(ShellCommand, String)] = [
            (.pomodoroToggle, #"{"cmd":"pomodoro_toggle"}"#),
            (.pomodoroSkip, #"{"cmd":"pomodoro_skip"}"#),
            (.pomodoroReset, #"{"cmd":"pomodoro_reset"}"#),
            (.clipCopy(id: 3), #"{"cmd":"clip_copy","id":3}"#),
            (.clipPin(id: 3, pinned: true), #"{"cmd":"clip_pin","id":3,"pinned":true}"#),
            (.clipRemove(id: 4), #"{"cmd":"clip_remove","id":4}"#),
            (.clipClear, #"{"cmd":"clip_clear"}"#),
            (.clipQuery("a \"b\""), #"{"cmd":"clip_query","query":"a \"b\""}"#),
            (.notifyDismissBanner, #"{"cmd":"notify_dismiss_banner"}"#),
            (.notifyDismiss(id: 9), #"{"cmd":"notify_dismiss","id":9}"#),
            (.notifyMarkRead, #"{"cmd":"notify_mark_read"}"#),
            (.notifyClear, #"{"cmd":"notify_clear"}"#),
            (.media(.playPause), #"{"cmd":"media","action":"play_pause"}"#),
            (.media(.next), #"{"cmd":"media","action":"next"}"#),
            (.media(.previous), #"{"cmd":"media","action":"previous"}"#),
            (.notifySystem(app: "Mail", title: "Hi \"you\"", body: "line"),
             #"{"cmd":"notify_system","app":"Mail","title":"Hi \"you\"","body":"line"}"#),
            (.agentDecide(requestId: "req-1", decision: .allow), #"{"cmd":"agent_decide","request_id":"req-1","decision":"allow"}"#),
            (.agentDecide(requestId: "req-1", decision: .deny), #"{"cmd":"agent_decide","request_id":"req-1","decision":"deny"}"#),
            (.agentDecide(requestId: "req-1", decision: .pass), #"{"cmd":"agent_decide","request_id":"req-1","decision":"pass"}"#),
            (.caffeineToggle, #"{"cmd":"caffeine_toggle"}"#),
            (.caffeineActivate(mode: .system, durationSecs: nil), #"{"cmd":"caffeine_activate","mode":"system","duration_secs":null}"#),
            (.caffeineActivate(mode: .display, durationSecs: 3600), #"{"cmd":"caffeine_activate","mode":"display","duration_secs":3600}"#),
            (.caffeineLid(on: true), #"{"cmd":"caffeine_lid","on":true}"#),
            (.panelOpened, #"{"cmd":"panel_opened"}"#),
            (.tabOpened(.inbox), #"{"cmd":"tab_opened","tab":"inbox"}"#),
            (.tabOpened(.home), #"{"cmd":"tab_opened","tab":"home"}"#),
            (.tabOpened(.music), #"{"cmd":"tab_opened","tab":"music"}"#),
            (.tabOpened(.timer), #"{"cmd":"tab_opened","tab":"timer"}"#),
            (.analyticsClear, #"{"cmd":"analytics_clear"}"#),
            (.setUtcOffset(secs: -18000), #"{"cmd":"set_utc_offset","secs":-18000}"#),
            (.refresh, #"{"cmd":"refresh"}"#),
            (.hooksInstall, #"{"cmd":"hooks_install"}"#),
            (.hooksUninstall, #"{"cmd":"hooks_uninstall"}"#),
        ]
        for (cmd, expected) in cases {
            XCTAssertEqual(try obj(cmd.encode()), try obj(expected), expected)
        }
        // set_settings: full snake_case object, edited value included.
        let s = try obj(ShellCommand.setSettings(settings).encode())
        XCTAssertEqual(s["cmd"] as? String, "set_settings")
        let inner = try XCTUnwrap(s["settings"] as? NSDictionary)
        XCTAssertEqual(Set(inner.allKeys as! [String]),
                       ["general", "appearance", "pomodoro", "clipboard", "media", "notify", "caffeine", "agent", "analytics"])
        XCTAssertEqual((inner["general"] as! NSDictionary)["all_screens"] as? Bool, false)
        XCTAssertEqual(inner["appearance"] as? NSDictionary,
                       ["theme": "system", "accent": "#FF9E0A", "notch_style": "attached", "closed_notch": "dark"])
        XCTAssertEqual((inner["media"] as! NSDictionary)["enabled"] as? Bool, true)
        XCTAssertEqual((inner["notify"] as! NSDictionary)["system"] as? Bool, false)
        XCTAssertEqual(Tab.allCases.map(\.rawValue), ["home", "music", "timer", "clipboard", "agents", "inbox", "settings"])
        XCTAssertEqual((inner["pomodoro"] as! NSDictionary)["focus_secs"] as? Int, 1800)
        XCTAssertEqual((inner["general"] as! NSDictionary)["persist_clipboard"] as? Bool, false)
        XCTAssertEqual((inner["notify"] as! NSDictionary)["dnd_min_priority"] as? String, "high")
        XCTAssertEqual((inner["caffeine"] as! NSDictionary)["lid_requires_ac"] as? Bool, false)
        XCTAssertEqual((inner["agent"] as! NSDictionary)["auto_allow_tools"] as? [String], [])
    }

    func testMockBridgeRecordsAndAppModelSends() {
        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        model.send(.pomodoroToggle)
        model.primary.selectTab(.inbox)
        model.primary.selectTab(.inbox) // no change, no command
        XCTAssertEqual(bridge.sent, [#"{"cmd":"pomodoro_toggle"}"#, #"{"cmd":"tab_opened","tab":"inbox"}"#])
    }

    func testPanelOpenedSentOnceWhenApprovalForcesOpen() throws {
        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        model.receive(viewJSON: try Data(contentsOf: fixtureURL("idle")))
        XCTAssertTrue(bridge.sent.isEmpty)
        model.receive(viewJSON: try Data(contentsOf: fixtureURL("approval")))
        XCTAssertEqual(model.primary.mode, .expanded)
        model.receive(viewJSON: try Data(contentsOf: fixtureURL("approval")))
        XCTAssertEqual(bridge.sent, [#"{"cmd":"panel_opened"}"#])
    }
}

final class GeometryTests: XCTestCase {
    func testNotchedScreen() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 950, width: 664.5, height: 32)
        let right = CGRect(x: 847.5, y: 950, width: 664.5, height: 32)
        let n = NotchGeometry.notchRect(screenFrame: frame, safeAreaTop: 32, leftAux: left, rightAux: right)
        XCTAssertEqual(n, CGRect(x: 664.5, y: 950, width: 183, height: 32))
        XCTAssertEqual(n.midX, frame.midX)
        let panel = NotchGeometry.panelFrame(screenFrame: frame, notch: n)
        XCTAssertEqual(panel.midX, n.midX, accuracy: 0.001)
        XCTAssertEqual(panel.maxY, frame.maxY)
        XCTAssertGreaterThanOrEqual(panel.width, NotchGeometry.expandedSize.width)
        XCTAssertGreaterThanOrEqual(panel.height, NotchGeometry.expandedSize.height)
    }

    func testNotchlessScreenFallsBackToCentredPill() {
        let frame = CGRect(x: 100, y: 50, width: 1920, height: 1080)
        let n = NotchGeometry.notchRect(screenFrame: frame, safeAreaTop: 0, leftAux: nil, rightAux: nil)
        XCTAssertEqual(n.size, CGSize(width: 190, height: 32))
        XCTAssertEqual(n.midX, frame.midX)
        XCTAssertEqual(n.maxY, frame.maxY)
    }

    func testSizes() {
        let notch = CGSize(width: 183, height: 32)
        let idle = NotchGeometry.size(for: .closed, compact: nil, notch: notch)
        XCTAssertEqual(idle.height, 32)
        XCTAssertEqual(idle.width, 183 + 2 * NotchGeometry.closedEar)
        let pomo = CompactView(kind: .pomodoro, title: "Focus", value: "", endsAtMs: 1, totalSecs: 1500, count: 0)
        let active = NotchGeometry.size(for: .closed, compact: pomo, notch: notch)
        XCTAssertGreaterThan(active.width, idle.width)
        XCTAssertEqual(active.height, 32)
        XCTAssertEqual(NotchGeometry.size(for: .expanded, compact: pomo, notch: notch), NotchGeometry.expandedSize)
        XCTAssertEqual(NotchGeometry.expandedSize, CGSize(width: 600, height: 280))
        let toast = NotchGeometry.size(for: .toast, compact: nil, notch: notch)
        XCTAssertGreaterThan(toast.height, 32)
        XCTAssertLessThan(toast.height, 260)
        // Media: artwork left, equaliser right, never text.
        let song = CompactView(kind: .media, title: String(repeating: "x", count: 40), value: "", endsAtMs: nil, totalSecs: nil, count: 0)
        XCTAssertEqual(NotchGeometry.wingWidth(for: song), 40)
        let longName = CompactView(kind: .agent, title: String(repeating: "x", count: 80), value: "", endsAtMs: nil, totalSecs: nil, count: 1)
        XCTAssertLessThanOrEqual(NotchGeometry.wingWidth(for: longName), 130)
        XCTAssertEqual(NotchGeometry.wingWidth(for: CompactView(kind: .idle, title: "", value: "", endsAtMs: nil, totalSecs: nil, count: 0)), 0)
    }

    func testAttachedLayoutIsTheOriginalGeometry() {
        let notch = CGSize(width: 183, height: 32)
        let layout = NotchLayout(style: .attached, notch: notch)
        let pomo = CompactView(kind: .pomodoro, title: "Focus", value: "", endsAtMs: 1, totalSecs: 1500, count: 0)
        for mode in [NotchMode.closed, .toast, .expanded] {
            XCTAssertEqual(layout.size(for: mode, compact: pomo), NotchGeometry.size(for: mode, compact: pomo, notch: notch))
            XCTAssertEqual(layout.top(for: mode), 0)
            XCTAssertTrue(layout.contains(CGPoint(x: 1, y: 0), mode: mode, in: layout.size(for: mode, compact: pomo)))
        }
        XCTAssertEqual(layout.wingWidth(for: pomo), NotchGeometry.wingWidth(for: pomo))
    }

    func testFloatingLayoutSitsInsideTheMenuBar() {
        let pomo = CompactView(kind: .pomodoro, title: "Focus", value: "", endsAtMs: 1, totalSecs: 1500, count: 0)
        // No notch, 24 pt menu bar: a capsule 3 pt in from top and bottom.
        let bare = NotchLayout(style: .floating, notch: NotchGeometry.fallbackSize, hasNotch: false, menuBarHeight: 24)
        XCTAssertEqual(bare.bar, 24)
        XCTAssertEqual(bare.capsuleHeight, 18)
        XCTAssertEqual(bare.top(for: .closed), 3)
        XCTAssertEqual(bare.size(for: .closed, compact: nil), CGSize(width: NotchGeometry.floatingCenterWidth, height: 21))
        XCTAssertEqual(bare.size(for: .closed, compact: pomo).width,
                       NotchGeometry.floatingCenterWidth + 2 * NotchGeometry.floatingWingWidth(for: pomo))
        // The toast overlaps the menu bar; the panel starts below it.
        XCTAssertEqual(bare.top(for: .toast), 24 - NotchGeometry.floatingToastLift)
        XCTAssertEqual(bare.top(for: .expanded), 24)
        XCTAssertEqual(bare.size(for: .expanded, compact: pomo).height, 24 + NotchGeometry.expandedSize.height)
        // A hidden menu bar falls back to the stand-in's height.
        XCTAssertEqual(NotchLayout(style: .floating, notch: NotchGeometry.fallbackSize, hasNotch: false).bar, 32)
        // With a notch the capsule keeps the notch's width and height band.
        let notched = NotchLayout(style: .floating, notch: CGSize(width: 185, height: 38), hasNotch: true, menuBarHeight: 38)
        XCTAssertEqual(notched.centerWidth, 185)
        XCTAssertEqual(notched.capsuleHeight, 32)
        XCTAssertEqual(notched.top(for: .expanded), 38)
        // Above the open panel only the column under the notch takes the pointer.
        let open = bare.size(for: .expanded, compact: nil)
        XCTAssertFalse(bare.contains(CGPoint(x: 10, y: 5), mode: .expanded, in: open))
        XCTAssertTrue(bare.contains(CGPoint(x: open.width / 2, y: 5), mode: .expanded, in: open))
        XCTAssertTrue(bare.contains(CGPoint(x: 10, y: 30), mode: .expanded, in: open))
        // The window has room for the floating panel.
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = NotchGeometry.notchRect(screenFrame: frame, safeAreaTop: 0, leftAux: nil, rightAux: nil)
        XCTAssertGreaterThanOrEqual(NotchGeometry.panelFrame(screenFrame: frame, notch: notch).height,
                                    bare.size(for: .expanded, compact: nil).height)
    }

    func testNotchStyleDecodesLenientlyAndDefaultsToAttached() throws {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let old = try d.decode(AppearanceConfig.self, from: Data(##"{"theme":"dark","accent":"#000000"}"##.utf8))
        XCTAssertEqual(old.notchStyle, .attached)
        let floating = try d.decode(AppearanceConfig.self, from: Data(##"{"theme":"dark","accent":"#000000","notch_style":"floating"}"##.utf8))
        XCTAssertEqual(floating.notchStyle, .floating)
        let future = try d.decode(AppearanceConfig.self, from: Data(##"{"theme":"dark","accent":"#000000","notch_style":"orbit"}"##.utf8))
        XCTAssertEqual(future.notchStyle, .unknown)
        // An unknown style is not sent back, so the core keeps its own.
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try e.encode(future), as: UTF8.self)
        XCTAssertFalse(json.contains("notch_style"))
        XCTAssertTrue(String(decoding: try e.encode(floating), as: UTF8.self).contains(#""notch_style":"floating""#))
    }

    func testHitRectIsCentredAndTopAligned() {
        let r = NotchGeometry.shapeRect(in: CGSize(width: 608, height: 284), shape: CGSize(width: 195, height: 32), flipped: false)
        XCTAssertEqual(r, CGRect(x: 206.5, y: 252, width: 195, height: 32))
        let f = NotchGeometry.shapeRect(in: CGSize(width: 608, height: 284), shape: CGSize(width: 195, height: 32), flipped: true)
        XCTAssertEqual(f.minY, 0)
        XCTAssertFalse(r.contains(CGPoint(x: 10, y: 10)), "transparent area must pass clicks through")
    }

    func testPresentationMode() throws {
        let idle = try loadFixture("idle"), approval = try loadFixture("approval"), banner = try loadFixture("banner")
        XCTAssertEqual(NotchPresentation.mode(expanded: false, view: idle), .closed)
        XCTAssertEqual(NotchPresentation.mode(expanded: true, view: idle), .expanded)
        XCTAssertEqual(NotchPresentation.mode(expanded: false, view: approval), .expanded)
        XCTAssertEqual(NotchPresentation.mode(expanded: false, view: banner), .toast)
        XCTAssertEqual(NotchPresentation.mode(expanded: true, view: banner), .expanded)
    }
}

final class FormatTests: XCTestCase {
    func testCountdown() {
        XCTAssertEqual(Format.countdown(seconds: 0), "0:00")
        XCTAssertEqual(Format.countdown(seconds: 65), "1:05")
        XCTAssertEqual(Format.countdown(seconds: 1500), "25:00")
        XCTAssertEqual(Format.countdown(seconds: 3600), "60:00")
        XCTAssertEqual(Format.countdown(seconds: -4), "0:00")
        XCTAssertEqual(Format.secondsLeft(until: 10_500, nowMs: 10_000), 1)
        XCTAssertEqual(Format.secondsLeft(until: 10_000, nowMs: 10_000), 0)
        XCTAssertEqual(Format.secondsLeft(until: 5_000, nowMs: 10_000), 0)
        XCTAssertEqual(Format.secondsLeft(until: 1_794_401_500_000, nowMs: 1_794_400_000_000), 1500)
    }

    func testRelativeTime() {
        let now = 1_000_000_000
        XCTAssertEqual(Format.relative(from: now - 5_000, nowMs: now), "just now")
        XCTAssertEqual(Format.relative(from: now + 5_000, nowMs: now), "just now")
        XCTAssertEqual(Format.relative(from: now - 60_000, nowMs: now), "1m ago")
        XCTAssertEqual(Format.relative(from: now - 59 * 60_000, nowMs: now), "59m ago")
        XCTAssertEqual(Format.relative(from: now - 3 * 3_600_000, nowMs: now), "3h ago")
        XCTAssertEqual(Format.relative(from: now - 2 * 86_400_000, nowMs: now), "2d ago")
    }

    func testResetsIn() {
        let now = 0
        XCTAssertEqual(Format.resetsIn(resetsAtMs: (2 * 3600 + 14 * 60) * 1000, nowMs: now), "resets in 2h 14m")
        XCTAssertEqual(Format.resetsIn(resetsAtMs: 5 * 60_000, nowMs: now), "resets in 5m")
        XCTAssertEqual(Format.resetsIn(resetsAtMs: 3_600_000, nowMs: now), "resets in 1h")
        XCTAssertEqual(Format.resetsIn(resetsAtMs: (3 * 24 + 4) * 3_600_000, nowMs: now), "resets in 3d 4h")
        XCTAssertEqual(Format.resetsIn(resetsAtMs: 1_000, nowMs: now), "resets in 1m")
        XCTAssertEqual(Format.resetsIn(resetsAtMs: -1, nowMs: now), "resetting now")
    }

    func testMisc() {
        XCTAssertEqual(Format.tokens(950), "950")
        XCTAssertEqual(Format.tokens(12_300), "12.3k")
        XCTAssertEqual(Format.tokens(2_000), "2k")
        XCTAssertEqual(Format.tokens(4_200_000), "4.2M")
        XCTAssertEqual(Format.percent(42.4), "42%")
        XCTAssertEqual(Format.featureName("agent_request"), "Approval requests")
        XCTAssertEqual(Format.featureName("something_new"), "Something new")
        XCTAssertEqual(Format.phaseLabel(.longBreak), "Long break")
        XCTAssertEqual(Format.duration(secs: 0), "0m")
        XCTAssertEqual(Format.duration(secs: 45 * 60), "45m")
        XCTAssertEqual(Format.duration(secs: 80 * 60), "1h 20m")
        XCTAssertEqual(Format.duration(secs: 7200), "2h")
    }

    func testScheduleLine() throws {
        let p = try loadFixture("idle").settings.pomodoro
        XCTAssertEqual(Format.schedule(p), "25 min focus \u{00B7} 5 min break \u{00B7} long break 15 min every 4")
    }

    func testWeekdayInitials() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // The media fixture's week ends on Wednesday 11 November 2026.
        let week = try loadFixture("media").usage.week
        XCTAssertEqual(week.map { Format.weekdayInitial(dayStartMs: $0.dayStartMs, calendar: utc) },
                       ["T", "F", "S", "S", "M", "T", "W"])
    }

    func testAgentsHeadlineAndDetail() throws {
        func s(_ project: String, _ status: AgentStatus) -> AgentSession {
            AgentSession(id: project, project: project, cwd: "/", status: status, lastEventMs: 0, lastMessage: nil)
        }
        XCTAssertEqual(Format.agentsHeadline([]), "No active sessions")
        XCTAssertEqual(Format.agentsHeadline([s("a", .ended)]), "No active sessions")
        XCTAssertEqual(Format.agentsHeadline([s("a", .working)]), "1 active session")
        XCTAssertEqual(Format.agentsHeadline([s("a", .working), s("b", .idle), s("c", .ended)]), "2 active sessions")
        XCTAssertEqual(Format.agentsHeadline([s("a", .working), s("b", .waitingInput)]), "b needs you")
        XCTAssertEqual(Format.agentsHeadline([s("a", .waitingInput), s("b", .waitingApproval)]), "b needs approval")

        let media = try loadFixture("media").usage
        XCTAssertEqual(Format.agentsDetail(media).tokens, "832k tokens today")
        XCTAssertEqual(Format.agentsDetail(media).limit, "42% of 5-hour limit")
        XCTAssertTrue(Format.hasTokenData(media))
        var none = try loadFixture("idle").usage
        none.week = []; none.models = []; none.projects = []
        none.today = TokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, messages: 0)
        XCTAssertEqual(Format.agentsDetail(none).tokens, "0 tokens today")
        XCTAssertFalse(Format.hasTokenData(none))
        XCTAssertFalse(Format.hasTokenData(try loadFixture("idle").usage))
    }

    func testMediaPositionExtrapolatesOnlyWhilePlaying() throws {
        var m = try XCTUnwrap(loadFixture("media").media)
        XCTAssertEqual(Format.mediaPosition(m, nowMs: m.positionAtMs + 10_000), 105_000)
        XCTAssertEqual(Format.mediaPosition(m, nowMs: m.positionAtMs + 10_000_000), 480_000, "clamped to duration")
        m.playing = false
        XCTAssertEqual(Format.mediaPosition(m, nowMs: m.positionAtMs + 10_000), 95_000)
        m.positionMs = nil
        XCTAssertNil(Format.mediaPosition(m, nowMs: 0))
    }
}

final class ApprovalSecurityTests: XCTestCase {
    private func request(truncated: Bool, detail: String = "ls") -> PermissionRequest {
        PermissionRequest(id: "r", sessionId: "s", project: "p", toolName: "Bash", summary: "ls",
                          detail: detail, truncated: truncated, createdMs: 0, expiresMs: 1)
    }

    func testAllowIsNeverOfferedWhenTruncated() {
        let p = ApprovalPresentation(request(truncated: true))
        XCTAssertFalse(p.showAllow)
        XCTAssertTrue(p.showTruncatedNotice)
        XCTAssertFalse(p.offeredDecisions.contains(.allow))
        XCTAssertEqual(p.offeredDecisions, [.deny, .pass])
        XCTAssertEqual(ApprovalPresentation.truncatedNotice,
                       "Command too long to review here \u{2014} answer in Terminal")
    }

    func testAllowOfferedWhenComplete() {
        let p = ApprovalPresentation(request(truncated: false))
        XCTAssertTrue(p.showAllow)
        XCTAssertFalse(p.showTruncatedNotice)
        XCTAssertEqual(p.offeredDecisions, [.deny, .pass, .allow])
    }

    func testBidiOverridesAreNeutralised() {
        let sneaky = "echo safe \u{202E}dlrow tsuj\u{202C} \u{200B}"
        let p = ApprovalPresentation(request(truncated: false, detail: sneaky))
        XCTAssertFalse(p.detail.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || $0.value == 0x200B })
        XCTAssertTrue(p.detail.hasPrefix("echo safe "))
    }

    /// Source-level guards for the rules a unit test cannot observe in a view.
    func testViewSourcesNeverUseMarkdownTextOrKeyboardShortcuts() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LiteNotchUI")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 8)
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            let name = f.lastPathComponent
            XCTAssertFalse(src.contains("LocalizedStringKey"), name)
            XCTAssertFalse(src.contains(".keyboardShortcut("), "\(name): no shortcuts on decision buttons")
            XCTAssertFalse(src.contains(".drawingGroup("), name)
            XCTAssertFalse(src.contains("Timer.scheduledTimer"), name)
            // `Text("...")` with an interpolation would parse markdown/localise.
            for (i, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if l.contains("Text(\"") && l.contains("\\(") {
                    XCTFail("\(name):\(i + 1) interpolates into Text(\"...\"); use Text(verbatim:)")
                }
            }
        }
    }
}

/// Hover and click both open the notch; neither turns the other off.
final class HoverAndClickTests: XCTestCase {
    private var bridge = MockBridge()
    /// Panels hold their app weakly; the test keeps it alive.
    private var app: AppModel?

    private func makeModel(hover: Bool = true) throws -> PanelState {
        bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        app = model
        var vm = try loadFixture("idle")
        vm.settings.general.hoverToExpand = hover
        model.apply(vm)
        return model.primary
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testHoverOpensAfterTheDelayAndClosesAfterLeaving() throws {
        let model = try makeModel()
        model.hoverChanged(true)
        XCTAssertFalse(model.expanded, "not before the delay")
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertTrue(model.expanded)
        model.hoverChanged(false)
        XCTAssertTrue(model.expanded, "stays while the pointer may come back")
        spin(NotchPresentation.collapseDelay + 0.15)
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(bridge.sent, [#"{"cmd":"panel_opened"}"#])
    }

    func testBriefHoverDoesNotOpen() throws {
        let model = try makeModel()
        model.hoverChanged(true)
        model.hoverChanged(false)
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertFalse(model.expanded)
    }

    func testClickOpensImmediatelyWhileAHoverIsPending() throws {
        let model = try makeModel()
        model.hoverChanged(true)
        model.open()
        XCTAssertTrue(model.expanded)
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(bridge.sent, [#"{"cmd":"panel_opened"}"#], "opened once, not twice")
    }

    func testClickOpensWithHoverTurnedOffAndLeavingStillCloses() throws {
        let model = try makeModel(hover: false)
        model.hoverChanged(true)
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertFalse(model.expanded, "hover is off")
        model.open()
        XCTAssertTrue(model.expanded)
        model.hoverChanged(false)
        spin(NotchPresentation.collapseDelay + 0.15)
        XCTAssertFalse(model.expanded)
    }

    func testStripClickClosesAndHoverDoesNotReopenUntilThePointerLeaves() throws {
        let model = try makeModel()
        model.hoverChanged(true)
        model.open()
        model.stripClicked()
        XCTAssertFalse(model.expanded)
        // The shape shrank under a pointer that has not moved.
        model.hoverChanged(true)
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertFalse(model.expanded, "a click-close must stick")
        // Leave and come back: hover works again.
        model.hoverChanged(false)
        model.hoverChanged(true)
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertTrue(model.expanded)
    }

    func testClickRightAfterHoverOpenedDoesNotCloseAgain() throws {
        let model = try makeModel()
        var clock: TimeInterval = 100
        model.uptime = { clock }
        model.hoverChanged(true)
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertTrue(model.expanded)
        // The user was already clicking the closed notch when hover opened it.
        clock += 0.2
        model.stripClicked()
        XCTAssertTrue(model.expanded)
        // A deliberate click later closes.
        clock += 1
        model.stripClicked()
        XCTAssertFalse(model.expanded)
    }

    func testStripClickAfterClickOpenClosesAtOnce() throws {
        let model = try makeModel(hover: false)
        model.open()
        model.stripClicked()
        XCTAssertFalse(model.expanded)
        model.open()
        XCTAssertTrue(model.expanded, "and it opens again by click")
    }

    func testStripClickNeverClosesAPendingApproval() throws {
        let app = AppModel(bridge: bridge)
        app.apply(try loadFixture("approval"))
        let model = app.primary
        model.open()
        model.stripClicked()
        XCTAssertEqual(model.mode, .expanded)
        XCTAssertTrue(model.expanded)
    }

    func testOpenSettingsDeepLinks() throws {
        let model = try makeModel()
        model.openSettings(.timer)
        XCTAssertEqual(model.tab, .settings)
        XCTAssertEqual(model.settingsSection, .timer)
        XCTAssertEqual(bridge.sent.last, #"{"cmd":"tab_opened","tab":"settings"}"#)
        XCTAssertEqual(SettingsSection.allCases.count, 8)
    }
}

// MARK: - Other apps' notifications

private func text(_ value: String, id: String = "") -> AXNode {
    AXNode(role: "AXStaticText", identifier: id, value: value)
}

private func banner(_ description: String, subrole: String = "AXNotificationCenterBanner",
                    _ children: [AXNode]) -> AXNode {
    AXNode(role: "AXGroup", subrole: subrole, description: description, children: children)
}

final class BannerParserTests: XCTestCase {
    func testTaggedTexts() {
        let b = banner("Messages, Anna, Lunch?, stacked", [
            AXNode(role: "AXImage"),
            AXNode(role: "AXGroup", children: [
                text("Lunch at 12?", id: "body"),
                text("Anna", id: "title"),
                text("Work chat", id: "subtitle"),
            ]),
            AXNode(role: "AXButton", value: "Close"),
        ])
        XCTAssertEqual(BannerParser.parse(banner: b),
                       CapturedNotification(app: "Messages", title: "Anna", body: "Work chat \u{2014} Lunch at 12?"))
    }

    func testUntaggedTextsUseOrder() {
        let b = banner("Calendar", [text("Stand-up"), text("in 5 minutes"), text("Room 2")])
        XCTAssertEqual(BannerParser.parse(banner: b),
                       CapturedNotification(app: "Calendar", title: "Stand-up", body: "in 5 minutes Room 2"))
    }

    func testFallbacks() {
        XCTAssertEqual(BannerParser.parse(banner: banner("", [text("  Hello \n")])),
                       CapturedNotification(app: "Notification", title: "Hello", body: ""))
        XCTAssertEqual(BannerParser.parse(banner: banner(" , x", [text("only body", id: "body")])),
                       CapturedNotification(app: "Notification", title: "only body", body: ""))
        XCTAssertNil(BannerParser.parse(banner: banner("Mail, x", [AXNode(role: "AXImage"), text("   ")])))
        // A non-text element's value is never notification text.
        XCTAssertNil(BannerParser.parse(banner: banner("Mail", [AXNode(role: "AXButton", value: "Reply")])))
    }

    func testLongTextIsCapped() {
        let long = String(repeating: "a", count: 5000)
        let n = BannerParser.parse(banner: banner(long, [text(long), text(long)]))
        XCTAssertEqual(n?.app.count, 60)
        XCTAssertEqual(n?.title.count, BannerParser.maxTitle)
        XCTAssertEqual(n?.body.count, BannerParser.maxBody)
    }

    func testFindsBannersAndAlertsAnywhereButNothingElse() {
        let roots = [
            AXNode(role: "AXWindow", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXScrollArea", children: [
                        banner("Mail, one", [text("One")]),
                        banner("Reminders, two", subrole: "AXNotificationCenterAlert", [text("Two")]),
                        AXNode(role: "AXGroup", subrole: "AXWidget", description: "Weather, x", children: [text("Sunny")]),
                    ]),
                ]),
            ]),
            AXNode(role: "AXWindow", children: [text("stray")]),
        ]
        XCTAssertEqual(BannerParser.notifications(in: roots).map(\.app), ["Mail", "Reminders"])
        XCTAssertEqual(BannerParser.notifications(in: []), [])
    }

    func testDeduperRemembersForThirtySecondsWhileVisible() {
        var d = NotificationDeduper()
        let n = CapturedNotification(app: "Mail", title: "t", body: "b")
        XCTAssertTrue(d.isNew(n, nowMs: 0))
        XCTAssertFalse(d.isNew(n, nowMs: 100))
        XCTAssertTrue(d.isNew(CapturedNotification(app: "Mail", title: "t", body: "other"), nowMs: 200))
        // Seen again at 20 s (still on screen), so it is remembered until 50 s.
        XCTAssertFalse(d.isNew(n, nowMs: 20_000))
        XCTAssertFalse(d.isNew(n, nowMs: 49_000))
        // Gone for more than 30 s: the same text is a new notification.
        XCTAssertTrue(d.isNew(n, nowMs: 80_000))
        XCTAssertEqual(d.count, 1, "old keys are pruned")
    }
}

private final class FakeBannerSource: BannerSource {
    var onChange: (([AXNode]) -> Void)?
    var starts = 0, stops = 0
    func start(onChange: @escaping ([AXNode]) -> Void) { starts += 1; self.onChange = onChange }
    func stop() { stops += 1; onChange = nil }
}

final class SystemNotificationObserverTests: XCTestCase {
    private var bridge = MockBridge()
    private var source = FakeBannerSource()
    private var trusted = false
    private var prompts = 0
    private var now = 1_000

    private func make(system: Bool) throws -> (AppModel, SystemNotificationObserver) {
        bridge = MockBridge(); source = FakeBannerSource(); trusted = false; prompts = 0
        let model = AppModel(bridge: bridge)
        var vm = try loadFixture("idle")
        vm.settings.notify.system = system
        model.apply(vm)
        let o = SystemNotificationObserver(model: model, source: source,
                                           isTrusted: { [unowned self] in self.trusted },
                                           promptForTrust: { [unowned self] in self.prompts += 1 },
                                           nowMs: { [unowned self] in self.now })
        return (model, o)
    }

    private func setSystem(_ on: Bool, _ model: AppModel) throws {
        var vm = try XCTUnwrap(model.view)
        vm.settings.notify.system = on
        model.apply(vm)
    }

    func testOffByDefaultDoesNothing() throws {
        let (model, o) = try make(system: false)
        o.start()
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(prompts, 0)
        XCTAssertFalse(model.accessibilityNeeded)
        XCTAssertFalse(o.isWaitingForPermission)
    }

    func testAsksOnceThenStartsWhenPermissionArrives() throws {
        let (model, o) = try make(system: false)
        o.start()
        try setSystem(true, model)
        XCTAssertTrue(model.accessibilityNeeded)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(source.starts, 0)
        XCTAssertTrue(o.isWaitingForPermission)
        o.recheck(); o.recheck()
        XCTAssertEqual(prompts, 1, "the system prompt is shown once")
        XCTAssertTrue(o.isWaitingForPermission)

        trusted = true
        o.recheck()
        XCTAssertFalse(model.accessibilityNeeded)
        XCTAssertEqual(source.starts, 1)
        XCTAssertTrue(o.isCapturing)
        XCTAssertFalse(o.isWaitingForPermission, "no timer once permission is there")
        o.stop()
    }

    func testWaitForPermissionIsBounded() throws {
        let (model, o) = try make(system: true)
        o.start()
        XCTAssertTrue(o.isWaitingForPermission)
        XCTAssertEqual(o.rechecksLeft, 60)
        for _ in 0..<60 { o.recheck() }
        XCTAssertFalse(o.isWaitingForPermission, "gives up after two minutes")
        XCTAssertTrue(model.accessibilityNeeded)
        // Opening the panel looks again, without restarting the timer.
        trusted = true
        model.primary.open()
        XCTAssertFalse(model.accessibilityNeeded)
        XCTAssertEqual(source.starts, 1)
        XCTAssertFalse(o.isWaitingForPermission)
        o.stop()
    }

    func testTurningTheSettingOffStopsEverything() throws {
        let (model, o) = try make(system: true)
        trusted = true
        o.start()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(prompts, 0)
        XCTAssertFalse(o.isWaitingForPermission)
        try setSystem(false, model)
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(o.isCapturing)
        // Permission revoked while on: capture stops and the notice returns.
        try setSystem(true, model)
        trusted = false
        model.primary.close(); model.primary.open()
        XCTAssertEqual(source.stops, 2)
        XCTAssertTrue(model.accessibilityNeeded)
        try setSystem(false, model)
        XCTAssertFalse(model.accessibilityNeeded)
        o.stop()
    }

    func testBannersBecomeCommandsOnce() throws {
        let (model, o) = try make(system: true)
        trusted = true
        o.start()
        let tree = [AXNode(role: "AXWindow", children: [
            banner("Mail, new message", [text("Build passed", id: "title"), text("main is green", id: "body")]),
        ])]
        source.onChange?(tree)
        now += 400
        source.onChange?(tree) // layout changed, same banner still showing
        let sent = bridge.sentObjects.filter { $0["cmd"] as? String == "notify_system" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["app"] as? String, "Mail")
        XCTAssertEqual(sent.first?["title"] as? String, "Build passed")
        XCTAssertEqual(sent.first?["body"] as? String, "main is green")
        // After the setting goes off nothing is forwarded.
        let late = source.onChange
        try setSystem(false, model)
        now += 60_000
        late?(tree)
        XCTAssertEqual(bridge.sentObjects.filter { $0["cmd"] as? String == "notify_system" }.count, 1)
        o.stop()
    }
}

// MARK: - New features

final class NewFieldsDecodingTests: XCTestCase {
    func testMeetingColorsAppearanceAndClipPreviewsDecode() throws {
        let v = try loadFixture("pomodoro")
        XCTAssertEqual(v.meeting.runState, .stopped)
        XCTAssertFalse(v.meeting.items.isEmpty)
        XCTAssertEqual(v.meeting.presets.map(\.id), ["standup", "sprint_review", "sprint_planning", "retro"])
        XCTAssertEqual(v.meeting.totalPlannedSecs, v.meeting.items.reduce(0) { $0 + $1.plannedSecs })
        XCTAssertNil(v.meeting.current)
        XCTAssertEqual(v.colors, [])
        XCTAssertEqual(v.settings.appearance, AppearanceConfig(theme: .system, accent: "#FF9E0A"))
        XCTAssertFalse(v.settings.general.allScreens)
        let image = try XCTUnwrap(v.clipboard.items.first { $0.kind == .image })
        XCTAssertNotNil(image.imagePath)
        let files = try XCTUnwrap(v.clipboard.items.first { $0.kind == .files })
        XCTAssertFalse(files.files.isEmpty)
        XCTAssertLessThanOrEqual(files.files.count, 4)
        XCTAssertTrue(v.clipboard.items.filter { $0.kind == .text }.allSatisfy { $0.imagePath == nil && $0.files.isEmpty })
    }

    /// An older core sends none of these; a confused one sends wrong types.
    func testNewFieldsAreLenient() throws {
        var o = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("media"))) as! [String: Any]
        o.removeValue(forKey: "meeting"); o.removeValue(forKey: "colors")
        var settings = o["settings"] as! [String: Any]
        settings.removeValue(forKey: "appearance")
        var general = settings["general"] as! [String: Any]
        general.removeValue(forKey: "all_screens")
        settings["general"] = general
        o["settings"] = settings
        var clipboard = o["clipboard"] as! [String: Any]
        clipboard["items"] = (clipboard["items"] as! [[String: Any]]).map { var i = $0; i.removeValue(forKey: "image_path"); i.removeValue(forKey: "files"); return i }
        o["clipboard"] = clipboard
        let old = try ViewModel.decode(JSONSerialization.data(withJSONObject: o))
        XCTAssertEqual(old.meeting, .empty)
        XCTAssertEqual(old.colors, [])
        XCTAssertEqual(old.settings.appearance, .default)
        XCTAssertFalse(old.settings.general.allScreens)
        XCTAssertTrue(old.clipboard.items.allSatisfy { $0.imagePath == nil && $0.files.isEmpty })

        o["meeting"] = ["title": 3, "items": "x", "run_state": "levitating", "presets": [["id": 1]]]
        o["colors"] = "red"
        settings["appearance"] = ["theme": "sepia", "accent": 7]
        o["settings"] = settings
        let odd = try ViewModel.decode(JSONSerialization.data(withJSONObject: o))
        XCTAssertEqual(odd.meeting.title, "")
        XCTAssertEqual(odd.meeting.items, [])
        XCTAssertEqual(odd.meeting.runState, .unknown)
        XCTAssertEqual(odd.colors, [])
        XCTAssertEqual(odd.settings.appearance.theme, .unknown)
        XCTAssertEqual(odd.settings.appearance.accent, AppearanceConfig.defaultAccent)
        // An unknown theme is left out when settings go back.
        let sent = try obj(ShellCommand.setSettings(odd.settings).encode())
        let appearance = (sent["settings"] as! NSDictionary)["appearance"] as! NSDictionary
        XCTAssertNil(appearance["theme"])
        XCTAssertEqual(appearance["accent"] as? String, "#FF9E0A")
    }

    func testMeetingKindDecodes() throws {
        let json = try String(contentsOf: fixtureURL("pomodoro"), encoding: .utf8)
            .replacingOccurrences(of: "\"kind\": \"pomodoro\"", with: "\"kind\": \"meeting\"")
        XCTAssertEqual(try ViewModel.decode(Data(json.utf8)).compact.kind, .meeting)
        let c = CompactView(kind: .meeting, title: "Demo", value: "", endsAtMs: 1, totalSecs: 60, count: 0)
        XCTAssertGreaterThanOrEqual(NotchGeometry.wingWidth(for: c), 62)
    }
}

final class NewCommandTests: XCTestCase {
    func testMeetingAndColorCommands() throws {
        let cases: [(ShellCommand, String)] = [
            (.meetingLoad(preset: "retro"), #"{"cmd":"meeting_load","preset":"retro"}"#),
            (.meetingSet(title: "Sync \"x\"", items: [AgendaLine(name: "Intro", minutes: 5), AgendaLine(name: "Demo", minutes: 20)]),
             #"{"cmd":"meeting_set","title":"Sync \"x\"","items":[{"name":"Intro","minutes":5},{"name":"Demo","minutes":20}]}"#),
            (.meetingSet(title: "", items: []), #"{"cmd":"meeting_set","title":"","items":[]}"#),
            (.meetingToggle, #"{"cmd":"meeting_toggle"}"#),
            (.meetingNext, #"{"cmd":"meeting_next"}"#),
            (.meetingReset, #"{"cmd":"meeting_reset"}"#),
            (.colorPicked(hex: "#0A84FF"), ##"{"cmd":"color_picked","hex":"#0A84FF"}"##),
        ]
        for (cmd, expected) in cases {
            XCTAssertEqual(try obj(cmd.encode()), try obj(expected), expected)
        }
    }

    func testSettingsCarryTheNewFields() throws {
        var s = try loadFixture("idle").settings
        s.general.allScreens = true
        s.appearance = AppearanceConfig(theme: .light, accent: "#30D158", notchStyle: .floating)
        let inner = try obj(ShellCommand.setSettings(s).encode())["settings"] as! NSDictionary
        XCTAssertEqual((inner["general"] as! NSDictionary)["all_screens"] as? Bool, true)
        XCTAssertEqual(inner["appearance"] as? NSDictionary,
                       ["theme": "light", "accent": "#30D158", "notch_style": "floating", "closed_notch": "dark"])
    }

    func testClosedNotchFollowsTheThemeOnlyWhenAsked() throws {
        // The same key strategies as the bridge: the core's snake_case JSON.
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let matched = try decoder.decode(AppearanceConfig.self, from: Data(##"{"theme":"light","accent":"#FF9E0A","closed_notch":"theme"}"##.utf8))
        XCTAssertEqual(matched.closedNotch, .theme)
        XCTAssertEqual(matched.closedScheme(system: .dark), .light)
        // A hardware notch keeps it black whatever the setting says.
        XCTAssertFalse(matched.closedFollowsTheme(hardwareNotch: true))
        XCTAssertEqual(matched.closedScheme(system: .light, hardwareNotch: true), .dark)
        XCTAssertTrue(matched.closedFollowsTheme(hardwareNotch: false))
        // Older settings and older cores: no field means the black notch.
        let old = try decoder.decode(AppearanceConfig.self, from: Data(##"{"theme":"light","accent":"#FF9E0A"}"##.utf8))
        XCTAssertEqual(old.closedNotch, .dark)
        XCTAssertEqual(old.closedScheme(system: .light), .dark)
        let odd = try decoder.decode(AppearanceConfig.self, from: Data(##"{"theme":"light","accent":"#FF9E0A","closed_notch":"glass"}"##.utf8))
        XCTAssertEqual(odd.closedNotch, .unknown)
        XCTAssertEqual(odd.closedScheme(system: .light), .dark)
        // An unknown value is left out so the core keeps its own.
        let sent = try JSONSerialization.jsonObject(with: encoder.encode(odd)) as! NSDictionary
        XCTAssertNil(sent["closed_notch"])

        var a = AppearanceConfig(theme: .light, accent: "#FF9E0A", closedNotch: .theme)
        XCTAssertEqual(a.closedScheme(system: .dark), .light)
        a.theme = .dark
        XCTAssertEqual(a.closedScheme(system: .light), .dark)
        a.theme = .system
        XCTAssertEqual(a.closedScheme(system: .light), .light)
        XCTAssertEqual(a.closedScheme(system: .dark), .dark)
        let inner = try JSONSerialization.jsonObject(with: encoder.encode(a)) as! NSDictionary
        XCTAssertEqual(inner["closed_notch"] as? String, "theme")
    }
}

final class ColorTests: XCTestCase {
    func testParseAndFormat() {
        XCTAssertEqual(ColorMath.normalize("#ff9e0a"), "#FF9E0A")
        XCTAssertEqual(ColorMath.normalize(" 0a84ff "), "#0A84FF")
        XCTAssertNil(ColorMath.normalize("#FFF"))
        XCTAssertNil(ColorMath.normalize("#GG0000"))
        XCTAssertNil(ColorMath.normalize("+12345"))
        XCTAssertNil(ColorMath.normalize(""))
        XCTAssertEqual(ColorMath.hex(ColorMath.RGB(r: 1.2, g: 0, b: -1)), "#FF0000")
        XCTAssertEqual(ColorMath.parse("#FF8000"), ColorMath.RGB(r: 1, g: 128.0 / 255, b: 0))
    }

    func testSampledColoursBecomeUpperCaseSRGB() throws {
        XCTAssertEqual(ColorMath.hex(of: NSColor(srgbRed: 1, green: 158.0 / 255, blue: 10.0 / 255, alpha: 1)), "#FF9E0A")
        XCTAssertEqual(ColorMath.hex(of: NSColor(white: 0, alpha: 1)), "#000000")
        // A Display P3 colour is converted, not reinterpreted.
        let p3 = try XCTUnwrap(ColorMath.hex(of: NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)))
        XCTAssertNotNil(ColorMath.parse(p3))
        XCTAssertEqual(p3, p3.uppercased())
    }

    func testTextOnTheAccentPicksTheReadableOne() throws {
        func dark(_ hex: String) throws -> Bool { ColorMath.prefersDarkText(on: try XCTUnwrap(ColorMath.parse(hex))) }
        XCTAssertTrue(try dark("#FF9E0A"), "black on the default orange")
        XCTAssertTrue(try dark("#FFD60A"))
        XCTAssertTrue(try dark("#FFFFFF"))
        XCTAssertFalse(try dark("#000000"))
        XCTAssertFalse(try dark("#1C3F94"), "white on a dark blue")
        XCTAssertFalse(try dark("#8E1B1B"))
        XCTAssertEqual(ColorMath.luminance(ColorMath.RGB(r: 1, g: 1, b: 1)), 1, accuracy: 1e-9)
        XCTAssertEqual(ColorMath.luminance(ColorMath.RGB(r: 0, g: 0, b: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(AccentPresets.all.first, AppearanceConfig.defaultAccent)
        XCTAssertTrue(AccentPresets.all.allSatisfy { ColorMath.normalize($0) == $0 })
    }

    func testAccentFallsBackToTheDefault() {
        NT.setAccent("#1C3F94")
        XCTAssertEqual(NT.accentHex, "#1C3F94")
        XCTAssertEqual(NT.onAccent, .white)
        XCTAssertFalse(NT.setAccent("#1c3f94"), "same colour, no change")
        NT.setAccent("nonsense")
        XCTAssertEqual(NT.accentHex, AppearanceConfig.defaultAccent)
        XCTAssertEqual(NT.onAccent, .black)
    }

    func testThemeToScheme() {
        XCTAssertEqual(ThemeChoice.dark.scheme(system: .light), .dark)
        XCTAssertEqual(ThemeChoice.light.scheme(system: .dark), .light)
        XCTAssertEqual(ThemeChoice.system.scheme(system: .light), .light)
        XCTAssertEqual(ThemeChoice.system.scheme(system: .dark), .dark)
        XCTAssertEqual(ThemeChoice.unknown.scheme(system: .dark), .dark)
    }
}

final class MeetingMathTests: XCTestCase {
    private func meeting(_ state: MeetingRunState, current: Int? = 1) -> MeetingView {
        MeetingView(title: "Review",
                    items: [MeetingItem(name: "Intro", plannedSecs: 300, elapsedSecs: 340, state: .done),
                            MeetingItem(name: "Demo", plannedSecs: 600, elapsedSecs: 100, state: .running),
                            MeetingItem(name: "Wrap", plannedSecs: 120)],
                    current: current, runState: state, endsAtMs: nil, runningSinceMs: nil,
                    remainingSecs: 500, totalPlannedSecs: 1020, totalElapsedSecs: 440, presets: [])
    }

    func testSignedCountdown() {
        XCTAssertEqual(Format.signedCountdown(65), "1:05")
        XCTAssertEqual(Format.signedCountdown(0), "0:00")
        XCTAssertEqual(Format.signedCountdown(-65), "+1:05")
        XCTAssertEqual(Format.signedSecondsLeft(until: 10_500, nowMs: 10_000), 1)
        XCTAssertEqual(Format.signedSecondsLeft(until: 10_000, nowMs: 10_000), 0)
        XCTAssertEqual(Format.signedSecondsLeft(until: 10_000, nowMs: 10_999), 0)
        XCTAssertEqual(Format.signedSecondsLeft(until: 10_000, nowMs: 75_000), -65)
    }

    func testRunningMeetingAddsTheLiveStretch() {
        var m = meeting(.running)
        m.runningSinceMs = 1_000_000
        m.endsAtMs = 1_000_000 + 500_000
        let now = 1_000_000 + 120_400
        XCTAssertEqual(MeetingMath.liveStretch(m, nowMs: now), 120)
        XCTAssertEqual(MeetingMath.elapsed(m, item: 1, nowMs: now), 220)
        XCTAssertEqual(MeetingMath.elapsed(m, item: 0, nowMs: now), 340, "done items do not move")
        XCTAssertEqual(MeetingMath.elapsed(m, item: 9, nowMs: now), 0)
        XCTAssertEqual(MeetingMath.totalElapsed(m, nowMs: now), 560)
        XCTAssertEqual(MeetingMath.currentLeft(m, nowMs: now), 380)
        XCTAssertEqual(MeetingMath.currentLeft(m, nowMs: 1_000_000 + 565_000), -65, "over time")
        XCTAssertTrue(MeetingMath.isActive(m))
        XCTAssertEqual(MeetingMath.position(m), "Item 2 of 3")
        XCTAssertEqual(MeetingMath.nextTitle(m), "Next")
        XCTAssertEqual(MeetingMath.currentItem(m)?.name, "Demo")
    }

    func testPausedAndStoppedUseTheStoredValues() {
        let paused = meeting(.paused)
        XCTAssertEqual(MeetingMath.liveStretch(paused, nowMs: .max / 2), 0)
        XCTAssertEqual(MeetingMath.currentLeft(paused, nowMs: 0), 500)
        XCTAssertTrue(MeetingMath.isActive(paused))
        let stopped = meeting(.stopped, current: nil)
        XCTAssertFalse(MeetingMath.isActive(stopped))
        XCTAssertEqual(MeetingMath.position(stopped), "3 items")
        XCTAssertNil(MeetingMath.currentItem(stopped))
        XCTAssertFalse(MeetingMath.isActive(meeting(.finished, current: nil)))
        XCTAssertEqual(MeetingMath.nextTitle(meeting(.running, current: 2)), "Finish")
    }

    func testAgendaIsCleanedLikeTheCore() {
        let lines = [("  Intro ", 0), ("", 5), ("Demo", 500)] + (0..<20).map { ("Item \($0)", 5) }
        let a = MeetingMath.agenda(lines)
        XCTAssertEqual(a.count, MeetingMath.maxItems)
        XCTAssertEqual(a[0], AgendaLine(name: "Intro", minutes: 1))
        XCTAssertEqual(a[1], AgendaLine(name: "Demo", minutes: 120))
        XCTAssertEqual(MeetingMath.agenda(of: meeting(.stopped)).map(\.minutes), [5, 10, 2])
    }

    func testFixtureAgendaRoundTrips() throws {
        let m = try loadFixture("idle").meeting
        let a = MeetingMath.agenda(of: m)
        XCTAssertEqual(a.count, m.items.count)
        XCTAssertEqual(a.reduce(0) { $0 + $1.minutes } * 60, m.totalPlannedSecs)
    }
}

private final class FakeSampler: ColorSampling {
    var result: String?
    var calls = 0
    func sample(_ done: @escaping (String?) -> Void) { calls += 1; done(result) }
}

/// Each display's panel has its own presentation state; the core is shared.
final class PanelStateTests: XCTestCase {
    private var bridge = MockBridge()
    private var sampler = FakeSampler()

    private func makeApp(_ fixture: String = "idle") throws -> AppModel {
        bridge = MockBridge(); sampler = FakeSampler()
        let app = AppModel(bridge: bridge, sampler: sampler)
        app.apply(try loadFixture(fixture))
        return app
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testHoverAndClicksOnlyAffectTheirOwnPanel() throws {
        let app = try makeApp()
        let a = app.primary, b = app.addPanel()
        XCTAssertEqual(app.panels.count, 2)
        b.hoverChanged(true)
        spin(NotchPresentation.hoverDelay + 0.15)
        XCTAssertTrue(b.expanded)
        XCTAssertFalse(a.expanded)
        a.open()
        a.selectTab(.clipboard)
        XCTAssertEqual(a.tab, .clipboard)
        XCTAssertEqual(b.tab, .home)
        // panel_opened once for the first panel to open, not per display.
        XCTAssertEqual(bridge.sent.filter { $0.contains("panel_opened") }.count, 1)
        b.clickedOutside()
        XCTAssertFalse(b.expanded)
        XCTAssertTrue(a.expanded)
    }

    func testApprovalsShowOnEveryPanelAndOpenOnce() throws {
        let app = try makeApp()
        let b = app.addPanel()
        b.notch = CGSize(width: 190, height: 32)
        app.apply(try loadFixture("approval"))
        XCTAssertEqual(app.primary.mode, .expanded)
        XCTAssertEqual(b.mode, .expanded)
        XCTAssertEqual(bridge.sent, [#"{"cmd":"panel_opened"}"#])
        XCTAssertNotEqual(app.primary.targetSize, .zero)
        b.clickedOutside()
        XCTAssertEqual(b.mode, .expanded, "an approval stays until answered")
    }

    func testNotchSizeIsPerPanel() throws {
        let app = try makeApp("pomodoro")
        let b = app.addPanel()
        app.primary.notch = CGSize(width: 183, height: 37)
        b.notch = NotchGeometry.fallbackSize
        XCTAssertEqual(app.primary.targetSize.height, 37)
        XCTAssertEqual(b.targetSize.height, 32)
        XCTAssertNotEqual(app.primary.targetSize.width, b.targetSize.width)
    }

    func testRemovingPanels() throws {
        let app = try makeApp()
        let b = app.addPanel()
        b.open()
        app.removePanel(b)
        app.removePanel(app.primary)
        XCTAssertEqual(app.panels.count, 1, "the primary panel stays")
        // The removed panel no longer counts as open.
        app.primary.open()
        XCTAssertEqual(bridge.sent.filter { $0.contains("panel_opened") }.count, 2)
    }

    func testPanelsRepublishSharedChanges() throws {
        let app = try makeApp()
        let b = app.addPanel()
        var fired = 0
        let c = b.objectWillChange.sink { fired += 1 }
        app.apply(try loadFixture("media"))
        XCTAssertGreaterThan(fired, 0)
        XCTAssertEqual(b.view?.media?.title, "Weightless")
        c.cancel()
    }

    func testKeyboardAndTimerPaneArePerPanel() throws {
        let app = try makeApp()
        let b = app.addPanel()
        b.open()
        b.requestKeyboard(true)
        XCTAssertTrue(b.keyboardRequested)
        XCTAssertFalse(app.primary.keyboardRequested)
        b.openTimer(.meeting)
        XCTAssertEqual(b.tab, .timer)
        XCTAssertEqual(b.timerPane, .meeting)
        XCTAssertEqual(app.primary.timerPane, .focus)
        b.close()
        XCTAssertFalse(b.keyboardRequested, "closing gives the keyboard back")
    }

    func testClipPreviewResetsWhenTheTabChanges() throws {
        let app = try makeApp("media")
        let p = app.primary
        p.selectTab(.clipboard)
        p.clipPreview = 5
        p.selectTab(.home)
        XCTAssertNil(p.clipPreview)
    }

    func testEyedropperClosesThePanelAndSendsThePickedColour() throws {
        let app = try makeApp()
        let p = app.primary
        p.open()
        sampler.result = "#0A84FF"
        p.pickColor()
        XCTAssertFalse(p.expanded)
        XCTAssertEqual(sampler.calls, 1)
        XCTAssertEqual(bridge.sent.last, ##"{"cmd":"color_picked","hex":"#0A84FF"}"##)
        // Cancelled: nothing is sent.
        let before = bridge.sent.count
        sampler.result = nil
        p.pickColor()
        XCTAssertEqual(bridge.sent.count, before)
    }

    func testPickedAccentIsSentAsASetting() throws {
        let app = try makeApp()
        sampler.result = "#30D158"
        app.pickAccent()
        let sent = try XCTUnwrap(bridge.sentObjects.last)
        XCTAssertEqual(sent["cmd"] as? String, "set_settings")
        let appearance = (sent["settings"] as? [String: Any])?["appearance"] as? [String: Any]
        XCTAssertEqual(appearance?["accent"] as? String, "#30D158")
        XCTAssertEqual(appearance?["theme"] as? String, "system")
    }

    func testApplyUpdatesTheAccent() throws {
        let app = try makeApp()
        var vm = try loadFixture("idle")
        vm.settings.appearance.accent = "#bf5af2"
        app.apply(vm)
        XCTAssertEqual(NT.accentHex, "#BF5AF2")
        vm.settings.appearance.accent = "#XYZ"
        app.apply(vm)
        XCTAssertEqual(NT.accentHex, AppearanceConfig.defaultAccent)
    }
}

final class ContrastTests: XCTestCase {
    func testContrastRatio() {
        let black = ColorMath.RGB(r: 0, g: 0, b: 0), white = ColorMath.RGB(r: 1, g: 1, b: 1)
        XCTAssertEqual(ColorMath.contrast(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(ColorMath.contrast(white, white), 1, accuracy: 0.01)
        // The default orange alone is too pale for text on a light panel.
        let orange = ColorMath.RGB(r: 1, g: 0.62, b: 0.04)
        XCTAssertLessThan(ColorMath.contrast(orange, ColorMath.RGB(r: 0.965, g: 0.965, b: 0.965)), 4.5)
    }
}

final class CountdownAndPlainCopyTests: XCTestCase {
    func testCommandsEncodeToTheCoreNames() {
        func obj(_ c: ShellCommand) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(c.encode().utf8))) as? [String: Any] ?? [:]
        }
        XCTAssertEqual(obj(.clipCopyPlain(id: 7))["cmd"] as? String, "clip_copy_plain")
        XCTAssertEqual(obj(.clipCopyPlain(id: 7))["id"] as? Int, 7)
        XCTAssertEqual(obj(.timerSet(secs: 90))["secs"] as? Int, 90)
        XCTAssertEqual(obj(.timerSet(secs: 90))["cmd"] as? String, "timer_set")
        XCTAssertEqual(obj(.timerToggle)["cmd"] as? String, "timer_toggle")
        XCTAssertEqual(obj(.timerReset)["cmd"] as? String, "timer_reset")
        XCTAssertEqual(obj(.timerAdd(secs: 60))["cmd"] as? String, "timer_add")
    }

    func testTimerAndRichFieldsDecodeAndDefault() throws {
        let vm = try loadFixture("media")
        XCTAssertEqual(vm.timer.runState, .stopped)
        XCTAssertEqual(vm.timer.presets.count, 6)
        XCTAssertFalse(vm.timer.isActive)
        XCTAssertTrue(vm.clipboard.items.contains { $0.rich })
        // An older core without these fields still decodes.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("media"))) as? [String: Any] ?? [:]
        json.removeValue(forKey: "timer")
        let old = try ViewModel.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.timer, .empty)
    }

    func testPresetLabels() {
        XCTAssertEqual(Format.timerPreset(45), "45 s")
        XCTAssertEqual(Format.timerPreset(60), "1 min")
        XCTAssertEqual(Format.timerPreset(1800), "30 min")
        XCTAssertEqual(Format.timerPreset(3600), "1 h")
        XCTAssertEqual(Format.timerPreset(5400), "1 h 30 min")
    }
}

final class FollowTargetTests: XCTestCase {
    private var app: AppModel?

    private func panel() throws -> (PanelState, [OpenTarget]) {
        let model = AppModel(bridge: MockBridge())
        app = model
        model.apply(try loadFixture("idle"))
        return (model.primary, [])
    }

    func testTabTargetsOpenTheRightTabAndPane() throws {
        let (p, _) = try panel()
        p.follow(.tab(.timer, pane: "countdown"))
        XCTAssertTrue(p.expanded)
        XCTAssertEqual(p.tab, .timer)
        XCTAssertEqual(p.timerPane, .countdown)
        p.follow(.tab(.agents, pane: "usage"))
        XCTAssertEqual(p.tab, .agents); XCTAssertEqual(p.agentsPane, .usage)
        p.follow(.tab(.settings, pane: "keep_awake"))
        XCTAssertEqual(p.tab, .settings); XCTAssertEqual(p.settingsSection, .keepAwake)
        p.follow(.tab(.timer, pane: "nonsense"))
        XCTAssertEqual(p.timerPane, .countdown, "an unknown pane keeps the current one")
        p.follow(nil)
        XCTAssertEqual(p.tab, .inbox)
    }

    func testAppTargetsBringTheAppForwardAndClose() throws {
        let (p, _) = try panel()
        var activated: [OpenTarget] = []
        app?.activateApp = { activated.append($0) }
        p.open()
        p.follow(.app(bundleId: "com.apple.Terminal"))
        p.follow(.appNamed("Mail"))
        XCTAssertEqual(activated, [.app(bundleId: "com.apple.Terminal"), .appNamed("Mail")])
        XCTAssertFalse(p.expanded)
    }

    func testTargetsDecodeAndUnknownOnesAreIgnored() throws {
        func item(_ open: String) throws -> NotificationItem {
            let json = """
            {"id":1,"source":"s","title":"t","body":"","priority":"normal","group":null,
             "ttl_secs":null,"created_ms":0,"read":false,"open":\(open)}
            """
            let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
            return try d.decode(NotificationItem.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try item(#"{"kind":"app","bundle_id":"com.apple.Terminal"}"#).open,
                       .app(bundleId: "com.apple.Terminal"))
        XCTAssertEqual(try item(#"{"kind":"app_named","name":"Mail"}"#).open, .appNamed("Mail"))
        XCTAssertEqual(try item(#"{"kind":"tab","tab":"timer","pane":"meeting"}"#).open,
                       .tab(.timer, pane: "meeting"))
        XCTAssertNil(try item(#"{"kind":"teleport"}"#).open)
        XCTAssertNil(try item(#"{"kind":"tab","tab":"nowhere"}"#).open)
        XCTAssertNil(try item("null").open)
    }
}

final class PermissionResetTests: XCTestCase {
    func testResetClearsTheEntryAndAsksAgain() throws {
        let model = AppModel(bridge: MockBridge())
        var vm = try loadFixture("idle")
        vm.settings.notify.system = true
        model.apply(vm)
        var prompts = 0, resets: [String] = []
        let o = SystemNotificationObserver(model: model, source: FakeBannerSource(),
                                           isTrusted: { false }, promptForTrust: { prompts += 1 },
                                           nowMs: { 0 })
        o.resetEntry = { resets.append($0) }
        o.start()
        XCTAssertEqual(prompts, 1)
        o.refresh()
        XCTAssertEqual(prompts, 1, "asks once on its own")
        o.resetPermission(bundleId: "dev.litenotch.app")
        XCTAssertEqual(resets, ["dev.litenotch.app"])
        XCTAssertEqual(prompts, 2, "and again after a reset")
        XCTAssertTrue(o.isWaitingForPermission)
        o.stop()
    }
}

/// One test per issue reported against the prototype, so none comes back.
final class ReportedIssueTests: XCTestCase {
    private var app: AppModel?

    private func panel(_ fixture: String = "idle") throws -> PanelState {
        let model = AppModel(bridge: MockBridge())
        app = model
        model.apply(try loadFixture(fixture))
        return model.primary
    }

    /// "The meeting timer UI overflows left and right": the header (mode
    /// switch + presets) must fit inside the open panel in every mode.
    func testTimerHeaderFitsThePanelInEveryMode() throws {
        let p = try panel("pomodoro")
        let vm = try XCTUnwrap(p.view)
        let available = NotchGeometry.expandedSize.width - 2 * (NotchGeometry.expandedEar + 14)
        for pane in TimerPane.allCases {
            p.timerPane = pane
            let host = NSHostingView(rootView: TimerHeader(vm: vm, model: p).fixedSize())
            XCTAssertLessThanOrEqual(host.fittingSize.width, available, "\(pane) header overflows")
        }
    }

    /// "I can't see the Aa button": every text clip offers copy as plain
    /// text, whether or not it was copied with formatting.
    func testEveryTextClipOffersPlainCopy() {
        func clip(_ kind: ClipKind, rich: Bool = false) -> ClipView {
            ClipView(id: 1, kind: kind, preview: "x", sourceApp: nil, createdMs: 0, pinned: false, rich: rich)
        }
        XCTAssertEqual(ClipActions.of(clip(.text), hasPreview: false), [.copyPlain])
        XCTAssertEqual(ClipActions.of(clip(.text, rich: true), hasPreview: false), [.copyPlain])
        XCTAssertEqual(ClipActions.of(clip(.image), hasPreview: true), [.preview])
        XCTAssertEqual(ClipActions.of(clip(.files), hasPreview: true), [.preview])
        XCTAssertEqual(ClipActions.of(clip(.files), hasPreview: false), [])
    }

    /// "Notifications are not clickable": a click goes to the target, and a
    /// clicked banner is dismissed (it stays in the inbox).
    func testClickingANotificationGoesSomewhere() throws {
        var activated: [OpenTarget] = []
        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        app = model
        model.apply(try loadFixture("idle"))
        model.activateApp = { activated.append($0) }
        let q = model.primary
        let mail = NotificationItem(id: 1, source: "Mail", title: "t", body: "", priority: .normal, group: nil,
                                    ttlSecs: nil, createdMs: 0, read: false, open: .appNamed("Mail"))
        q.openNotification(mail, isBanner: true)
        XCTAssertEqual(activated, [.appNamed("Mail")])
        // "When a notification is clicked, assume it has been read."
        XCTAssertTrue(bridge.sent.contains { $0.contains(#""cmd":"notify_opened""#) && $0.contains(#""id":1"#) })
        XCTAssertTrue(bridge.sent.contains { $0.contains("notify_dismiss_banner") })

        let timer = NotificationItem(id: 2, source: "timer", title: "t", body: "", priority: .high, group: nil,
                                     ttlSecs: nil, createdMs: 0, read: false,
                                     open: .tab(.timer, pane: "countdown"))
        q.openNotification(timer, isBanner: false)
        XCTAssertEqual(q.tab, .timer)
        XCTAssertEqual(q.timerPane, .countdown)
        XCTAssertTrue(q.expanded)
    }

    /// "Agentic is not clickable": a session with a known terminal brings it
    /// forward; one without does nothing.
    func testClickingASessionBringsItsTerminalForward() throws {
        let p = try panel()
        var activated: [OpenTarget] = []
        app?.activateApp = { activated.append($0) }
        var s = AgentSession(id: "s", project: "api", cwd: "/w/api", status: .working, lastEventMs: 0,
                             lastMessage: nil, app: nil)
        p.openSession(s)
        XCTAssertTrue(activated.isEmpty)
        s.app = "com.apple.Terminal"
        p.openSession(s)
        XCTAssertEqual(activated, [.app(bundleId: "com.apple.Terminal")])
    }
}

final class TypedTimerLengthTests: XCTestCase {
    func testTypedLengthsParse() {
        let cases: [(String, Int?)] = [
            ("25", 1500), ("1:30", 90), ("0:45", 45), ("1:05:00", 3900),
            ("90s", 90), ("45m", 2700), ("1h", 3600), ("1h 30m", 5400), ("1h30", 5400),
            ("2m30s", 150), (" 10 ", 600), ("1H", 3600),
            ("", nil), ("abc", nil), ("1:75", nil), ("0", nil), ("25:00:00", nil),
            ("1m1m", nil), ("30x", nil), ("1:2:3:4", nil), ("m5", nil), ("5m30", nil), (":", nil),
        ]
        for (text, want) in cases {
            XCTAssertEqual(Format.parseDuration(text), want, "\"\(text)\"")
        }
    }
}

/// Text tokens stay readable (WCAG AA, 4.5:1) on every surface they sit on:
/// the panel, a card, a hovered row, and a hovered row inside a card.
final class TextContrastTests: XCTestCase {
    private func surfaces(dark: Bool) -> [(String, ColorMath.RGB)] {
        let panel = NT.Tone.panel.resolved(dark: dark, over: ColorMath.RGB(r: 0, g: 0, b: 0))
        let card = NT.Tone.fill.resolved(dark: dark, over: panel)
        return [("panel", panel), ("card", card),
                ("hover", NT.Tone.fillHi.resolved(dark: dark, over: panel)),
                ("hover in card", NT.Tone.fill.resolved(dark: dark, over: card))]
    }

    func testTextTokensPassAAOnEverySurfaceInBothSchemes() {
        for dark in [true, false] {
            for (name, bg) in surfaces(dark: dark) {
                for tone in [NT.Tone.text1, .text2, .text3] {
                    let ratio = ColorMath.contrast(tone.resolved(dark: dark, over: bg), bg)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(tone) on \(name), \(dark ? "dark" : "light"): \(ratio)")
                }
            }
        }
    }

    func testTextLevelsStayDistinct() {
        for dark in [true, false] {
            let bg = NT.Tone.panel.resolved(dark: dark, over: ColorMath.RGB(r: 0, g: 0, b: 0))
            let r = [NT.Tone.text1, .text2, .text3].map { ColorMath.contrast($0.resolved(dark: dark, over: bg), bg) }
            XCTAssertGreaterThan(r[0], r[1])
            XCTAssertGreaterThan(r[1], r[2])
        }
    }

    func testCompositing() {
        let w = ColorMath.RGB(r: 1, g: 1, b: 1), b = ColorMath.RGB(r: 0, g: 0, b: 0)
        XCTAssertEqual(ColorMath.over(w, alpha: 0.5, b), ColorMath.RGB(r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(ColorMath.over(w, alpha: 2, b), w)
        XCTAssertEqual(ColorMath.over(w, alpha: 0, b), b)
    }

    func testTheClosedNotchAndToastAreBlackUnlessAskedToMatchTheTheme() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LiteNotchUI/NotchRootView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("shape.fill(mode == .expanded || appearance.closedFollowsTheme(hardwareNotch: model.hasNotch) ? NT.panel : Color.black)"))
    }
}

final class ConfirmGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testFirstClickArmsSecondClickActs() {
        var g = ConfirmGate()
        XCTAssertFalse(g.isArmed(at: t0))
        XCTAssertFalse(g.tap(at: t0), "the first click only asks")
        XCTAssertTrue(g.isArmed(at: t0.addingTimeInterval(1)))
        XCTAssertTrue(g.tap(at: t0.addingTimeInterval(2.9)), "a second click inside the window acts")
        XCTAssertFalse(g.isArmed(at: t0.addingTimeInterval(2.9)), "and disarms")
    }

    func testTimeoutReverts() {
        var g = ConfirmGate()
        _ = g.tap(at: t0)
        XCTAssertFalse(g.isArmed(at: t0.addingTimeInterval(ConfirmGate.window)))
        XCTAssertFalse(g.tap(at: t0.addingTimeInterval(3.5)), "a late click asks again")
        XCTAssertTrue(g.isArmed(at: t0.addingTimeInterval(4)))
    }

    func testLeavingDisarms() {
        var g = ConfirmGate()
        _ = g.tap(at: t0)
        g.disarm()
        XCTAssertFalse(g.tap(at: t0.addingTimeInterval(0.5)), "after leaving, a click asks again")
    }

    func testClockGoingBackwardsDoesNotConfirm() {
        var g = ConfirmGate()
        _ = g.tap(at: t0)
        XCTAssertFalse(g.isArmed(at: t0.addingTimeInterval(-1)))
    }

    func testQuestion() {
        XCTAssertEqual(ConfirmGate.question(count: 12), "Clear 12 items?")
        XCTAssertEqual(ConfirmGate.question(count: 1), "Clear 1 item?")
        XCTAssertEqual(ConfirmGate.question(count: nil), "Clear all?")
        XCTAssertEqual(ConfirmGate.question(count: 0), "Clear all?")
    }
}

final class CopyTests: XCTestCase {
    func testStatusLabelsArePlain() {
        XCTAssertEqual(Format.statusLabel(.working), "Working")
        XCTAssertEqual(Format.statusLabel(.waitingInput), "Needs you")
        XCTAssertEqual(Format.statusLabel(.waitingApproval), "Waiting for approval")
        XCTAssertEqual(Format.statusLabel(.idle), "Idle")
        XCTAssertEqual(Format.statusLabel(.ended), "Done")
    }

    func testKeepAwakeTooltipSaysWhatHappensAndForHowLong() {
        XCTAssertEqual(KeepAwakeText.help(on: false, untilMs: nil, nowMs: 0), "Keep the Mac awake")
        XCTAssertEqual(KeepAwakeText.help(on: true, untilMs: nil, nowMs: 0),
                       "Keeping the Mac awake until you turn it off. Click to stop.")
        XCTAssertEqual(KeepAwakeText.help(on: true, untilMs: 42 * 60_000 - 500, nowMs: 0),
                       "Keeping the Mac awake, 42 min left. Click to stop.")
        XCTAssertEqual(KeepAwakeText.help(on: true, untilMs: 90 * 60_000, nowMs: 0),
                       "Keeping the Mac awake, 1h 30m left. Click to stop.")
        XCTAssertEqual(KeepAwakeText.help(on: true, untilMs: 1_000, nowMs: 5_000),
                       "Keeping the Mac awake, 1 min left. Click to stop.")
    }

    func testNoTrackedCapsLabelsInViews() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LiteNotchUI")
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            where f.pathExtension == "swift" {
            let src = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(src.contains(".tracking("), f.lastPathComponent)
            XCTAssertFalse(src.contains(".uppercased())"), f.lastPathComponent)
        }
    }
}

final class RoundTwoTests: XCTestCase {
    private func request(_ tool: String, _ summary: String) -> PermissionRequest {
        PermissionRequest(id: "r", sessionId: "s", project: "LiteNotch", toolName: tool, summary: summary,
                          detail: summary, createdMs: 0, expiresMs: 0)
    }

    func testApprovalHeadlineSaysWhatIsAsked() {
        XCTAssertEqual(ApprovalPresentation.headline(request("Bash", "ls")),
                       "Claude Code wants to run a command in LiteNotch")
        XCTAssertEqual(ApprovalPresentation.headline(request("Edit", "/Users/me/src/main.rs")),
                       "Claude Code wants to edit main.rs in LiteNotch")
        XCTAssertEqual(ApprovalPresentation.headline(request("Write", "")),
                       "Claude Code wants to edit a file in LiteNotch")
        XCTAssertEqual(ApprovalPresentation.headline(request("WebSearch", "q")),
                       "Claude Code wants to use WebSearch in LiteNotch")
        // Invisible formatting cannot sneak into the headline either.
        XCTAssertEqual(ApprovalPresentation.headline(request("Bash\u{202E}", "x")),
                       "Claude Code wants to use Bash\u{FFFD} in LiteNotch")
    }

    func testOverrunAndScheduleAndSourceTags() throws {
        XCTAssertEqual(Format.overrun(65), "1:05")
        XCTAssertEqual(Format.overrun(-65), "1:05 over")
        let p = try loadFixture("idle").settings.pomodoro
        XCTAssertEqual(Format.scheduleLines(p),
                       ["\(p.focusSecs / 60) min focus \u{00B7} \(p.shortBreakSecs / 60) min break",
                        "\(p.longBreakSecs / 60) min long break every \(p.roundsBeforeLong) rounds"])
        XCTAssertEqual(Format.sourceTag("ci"), "CI")
        XCTAssertEqual(Format.sourceTag("agent"), "Agent")
        XCTAssertEqual(Format.sourceTag("Slack"), "Slack")
        XCTAssertNil(Format.sourceTag(""))
        XCTAssertNil(Format.sourceTag("litenotch"))
        XCTAssertEqual(Format.phaseLabel(.idle), "Focus")
    }

    func testStatuslineCommandsAndField() throws {
        XCTAssertEqual(ShellCommand.statuslineInstall.encode(), #"{"cmd":"statusline_install"}"#)
        XCTAssertEqual(ShellCommand.statuslineUninstall.encode(), #"{"cmd":"statusline_uninstall"}"#)
        XCTAssertNil(try loadFixture("idle").agents.statuslineInstalled)
        let json = #"{"sessions":[],"pending":[],"hooks_installed":true,"statusline_installed":true}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try d.decode(AgentsView.self, from: Data(json.utf8)).statuslineInstalled, true)
        let old = #"{"sessions":[],"pending":[]}"#
        XCTAssertNil(try d.decode(AgentsView.self, from: Data(old.utf8)).statuslineInstalled)
    }

    func testOnlyAppsInApplicationFoldersMayBeLaunched() {
        let home = URL(fileURLWithPath: "/Users/me")
        func ok(_ p: String) -> Bool { AppModel.mayLaunch(URL(fileURLWithPath: p), home: home) }
        XCTAssertTrue(ok("/Applications/Ghostty.app"))
        XCTAssertTrue(ok("/System/Applications/Utilities/Terminal.app"))
        XCTAssertTrue(ok("/Users/me/Applications/Tool.app"))
        XCTAssertFalse(ok("/Users/me/Downloads/Evil.app"))
        XCTAssertFalse(ok("/tmp/x.app"))
        XCTAssertFalse(ok("/Applications/../tmp/x.app"))
        XCTAssertFalse(ok("/ApplicationsX/x.app"))
        XCTAssertFalse(ok("/Applications/script.sh"))
        XCTAssertFalse(AppModel.mayLaunch(URL(string: "https://example.com/Applications/a.app")!, home: home))
    }

    func testHugeImagesAreRefusedAndSmallOnesDownsampled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func png(_ w: Int, _ h: Int) throws -> String {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
            let url = dir.appendingPathComponent("\(w)x\(h).png")
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            return url.path
        }
        let big = try png(4097, 2)
        XCTAssertNil(Thumbnails.downsample(big, px: 300, maxSourceSide: Thumbnails.maxSourceSide))
        let ok = try png(1200, 600)
        let cg = try XCTUnwrap(Thumbnails.downsample(ok, px: ArtworkCache.pixels, maxSourceSide: Thumbnails.maxSourceSide))
        XCTAssertEqual(max(cg.width, cg.height), ArtworkCache.pixels)
        XCTAssertNil(Thumbnails.downsample(dir.appendingPathComponent("missing.png").path, px: 300, maxSourceSide: 4096))
    }

    func testWarningAndDenyTextPassAA() {
        for dark in [true, false] {
            let panel = NT.Tone.panel.resolved(dark: dark, over: ColorMath.RGB(r: 0, g: 0, b: 0))
            let card = NT.Tone.fill.resolved(dark: dark, over: panel)
            for bg in [panel, card] {
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(dark ? NT.warningRGB.dark : NT.warningRGB.light, bg), 4.5)
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(dark ? NT.denyRGB.dark : NT.denyRGB.light, bg), 4.5)
            }
        }
    }
}
