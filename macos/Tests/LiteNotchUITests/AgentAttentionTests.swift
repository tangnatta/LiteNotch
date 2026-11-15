import AppKit
import XCTest
@testable import LiteNotchUI

private func fixture(_ name: String) throws -> ViewModel {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try ViewModel.decode(Data(contentsOf: url))
}

private let terminal = "com.apple.Terminal"
private let ghostty = "com.mitchellh.ghostty"

/// Reported: the waiting dot stayed after clicking the session it was for,
/// and after going to that session's terminal window by hand.
final class AgentAttentionTests: XCTestCase {
    private func session(_ id: String, _ status: AgentStatus = .waitingInput, app: String? = terminal,
                         tty: String? = nil) -> AgentSession {
        AgentSession(id: id, project: id, cwd: "/work/\(id)", status: status, lastEventMs: 0, app: app, tty: tty)
    }

    private func notice(_ id: Int, source: String = "agent", group: String?, read: Bool = false) -> NotificationItem {
        NotificationItem(id: id, source: source, title: "t", body: "b", priority: .normal, group: group,
                         ttlSecs: nil, createdMs: 0, read: read, open: .app(bundleId: terminal))
    }

    /// A model showing `sessions`, the dot on, and the commands it sends.
    private func make(_ sessions: [AgentSession], history: [NotificationItem] = [], waiting: Bool = true)
        throws -> (AppModel, MockBridge) {
        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        var vm = try fixture("idle")
        vm.agents.sessions = sessions
        vm.inbox.history = history
        vm.waiting = waiting
        model.apply(vm)
        return (model, bridge)
    }

    private func seen(_ bridge: MockBridge) -> [String] {
        bridge.sentObjects.filter { $0["cmd"] as? String == "agent_seen" }.compactMap { $0["session_id"] as? String }
    }

    // MARK: Clicking in the notch

    func testClickingASessionSaysItWasSeenEvenWithoutAKnownTerminal() throws {
        let (model, bridge) = try make([session("s1", app: nil)])
        model.activateApp = { _ in }
        model.primary.openSession(session("s1", app: nil))
        XCTAssertEqual(seen(bridge), ["s1"])
        XCTAssertEqual(ShellCommand.agentSeen(sessionId: "s1").encode(), #"{"cmd":"agent_seen","session_id":"s1"}"#)
    }

    func testOpeningAnAgentNoticeSaysItsSessionWasSeenAndOtherNoticesDoNot() throws {
        let (model, bridge) = try make([session("s1")])
        model.activateApp = { _ in }
        model.primary.openNotification(notice(1, group: "agent-s1"), isBanner: false)
        XCTAssertEqual(seen(bridge), ["s1"])
        model.primary.openNotification(notice(2, source: "ci", group: "agent-s2"), isBanner: false)
        model.primary.openNotification(notice(3, group: nil), isBanner: false)
        model.primary.openNotification(notice(4, group: "agent-"), isBanner: false)
        XCTAssertEqual(seen(bridge), ["s1"], "only an agent's own notice names a session")
    }

    func testWhichSessionsKeepTheDotOn() throws {
        var vm = try fixture("idle")
        vm.agents.sessions = [session("wait"), session("busy", .working), session("done", .idle), session("read", .idle)]
        vm.inbox.history = [notice(1, group: "agent-done"), notice(2, group: "agent-read", read: true)]
        XCTAssertEqual(AgentAttention.waiting(in: vm).map(\.id), ["wait", "done"])
        // The fixture with a session waiting for input.
        XCTAssertEqual(AgentAttention.waiting(in: try fixture("pair")).map(\.id), ["s9"])
    }

    // MARK: Going to the terminal by hand

    func testWithTheFrontTabKnownOnlyTheSessionOnItCounts() {
        let a = session("a", tty: "ttys001"), b = session("b", tty: "ttys002"), c = session("c", tty: nil)
        XCTAssertEqual(AgentAttention.attended([a, b, c], frontTTY: "ttys002").map(\.id), ["b", "c"])
        XCTAssertEqual(AgentAttention.attended([a, b], frontTTY: "ttys009").map(\.id), [])
        XCTAssertEqual(AgentAttention.attended([a, b, c], frontTTY: nil).map(\.id), ["a", "b", "c"],
                       "not known: the app being in front is all that can be told")
    }

    private func observer(_ model: AppModel, front: String? = nil, tty: String?? = .none)
        -> (AgentAttentionObserver, () -> [String]) {
        var asked: [String] = []
        let o = AgentAttentionObserver(model: model, frontmost: { front }, frontTTY: { app, done in
            asked.append(app)
            if case .some(let answer) = tty { done(answer) }
        })
        return (o, { asked })
    }

    func testBringingTheSessionsTabForwardClearsItAndAnotherTabDoesNot() throws {
        let sessions = [session("a", tty: "ttys001"), session("b", tty: "ttys002")]
        let (model, bridge) = try make(sessions)
        let (onA, asked) = observer(model, tty: .some("ttys001"))
        onA.cameForward(terminal)
        XCTAssertEqual(asked(), [terminal])
        XCTAssertEqual(seen(bridge), ["a"], "b's tab is not the one in front")

        let (model2, bridge2) = try make(sessions)
        let (elsewhere, _) = observer(model2, tty: .some("ttys777"))
        elsewhere.cameForward(terminal)
        XCTAssertEqual(seen(bridge2), [], "Terminal is in front, on a tab with no waiting session")
    }

    func testWhenTheTabCannotBeToldTheAppInFrontIsEnough() throws {
        // Terminal, but LiteNotch may not ask it (or it did not answer).
        let (model, bridge) = try make([session("a", tty: "ttys001"), session("b", tty: "ttys002")])
        let (o, _) = observer(model, tty: .some(nil))
        o.cameForward(terminal)
        XCTAssertEqual(seen(bridge), ["a", "b"])

        // A terminal that cannot be asked at all is never asked.
        let (model2, bridge2) = try make([session("g", app: ghostty, tty: "ttys004"), session("t", tty: "ttys001")])
        let (o2, asked2) = observer(model2, tty: .some("ttys001"))
        o2.cameForward(ghostty)
        XCTAssertEqual(asked2(), [])
        XCTAssertEqual(seen(bridge2), ["g"], "only the sessions in the app that came forward")

        // Nothing to narrow down when no session's device is known.
        let (model3, bridge3) = try make([session("x", tty: nil)])
        let (o3, asked3) = observer(model3, tty: .some("ttys001"))
        o3.cameForward(terminal)
        XCTAssertEqual(asked3(), [])
        XCTAssertEqual(seen(bridge3), ["x"])
    }

    func testNothingHappensWithoutADotOrForAnUnrelatedApp() throws {
        let (quiet, bridge) = try make([session("a", tty: "ttys001")], waiting: false)
        let (o, asked) = observer(quiet, tty: .some("ttys001"))
        o.cameForward(terminal)
        XCTAssertEqual(asked(), [])
        XCTAssertEqual(seen(bridge), [])

        let (model, bridge2) = try make([session("a", tty: "ttys001"), session("w", .working, tty: "ttys002")])
        let (o2, asked2) = observer(model, tty: .some("ttys002"))
        o2.cameForward("com.apple.Safari")
        o2.cameForward(nil)
        XCTAssertEqual(asked2(), [])
        o2.cameForward(terminal)
        XCTAssertEqual(seen(bridge2), [], "the tab in front holds a session that is working, not waiting")
    }

    func testASessionThatStartsWaitingWhileItsTerminalIsInFrontIsSeenAtOnce() throws {
        let bridge = MockBridge()
        let model = AppModel(bridge: bridge)
        let (o, _) = observer(model, front: terminal, tty: .some("ttys001"))
        o.start()
        defer { o.stop() }
        var vm = try fixture("idle")
        vm.agents.sessions = [session("a", tty: "ttys001")]
        vm.waiting = true
        model.apply(vm)
        let done = expectation(description: "main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(seen(bridge), ["a"])
    }

    // MARK: Extra hooks

    /// Reported: Claude Code's settings held the hooks of five copies of
    /// LiteNotch. Settings says so and offers to remove them.
    func testOtherCopiesOfLiteNotchAreReportedInSettings() throws {
        XCTAssertNil(AgentsText.otherCopies(found: 0, missing: 0))
        XCTAssertEqual(AgentsText.otherCopies(found: 1, missing: 0),
                       "1 other copy of LiteNotch also runs on every Claude Code event.")
        XCTAssertEqual(AgentsText.otherCopies(found: 1, missing: 1),
                       "1 other copy of LiteNotch also runs on every Claude Code event. It no longer exists.")
        XCTAssertEqual(AgentsText.otherCopies(found: 4, missing: 2),
                       "4 other copies of LiteNotch also run on every Claude Code event. 2 of them no longer exist.")
        XCTAssertEqual(AgentsText.otherCopies(found: 3, missing: 3),
                       "3 other copies of LiteNotch also run on every Claude Code event. None of them exist any more.")
        XCTAssertEqual(AgentsText.otherCopies(found: 2, missing: 9), AgentsText.otherCopies(found: 2, missing: 2))

        XCTAssertEqual(ShellCommand.hooksClean.encode(), #"{"cmd":"hooks_clean"}"#)
        let agents = try fixture("idle").agents
        XCTAssertEqual(agents.otherCopies, 0, "what the core sends when there are none")
        XCTAssertEqual(agents.otherCopiesMissing, 0)
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let older = try d.decode(AgentsView.self, from: Data(#"{"sessions":[],"pending":[],"hooks_installed":true}"#.utf8))
        XCTAssertNil(older.otherCopies, "a core from before the check")
        let found = try d.decode(AgentsView.self, from: Data(
            #"{"sessions":[],"pending":[],"hooks_installed":true,"other_copies":4,"other_copies_missing":2}"#.utf8))
        XCTAssertEqual(found.otherCopies, 4)
        XCTAssertEqual(found.otherCopiesMissing, 2)
    }

    // MARK: The scripts

    func testTheFrontTabScriptsOnlyReadAndTheirAnswerIsChecked() throws {
        for app in [terminal, "com.googlecode.iterm2"] {
            let script = try XCTUnwrap(TerminalWindow.frontScript(bundleId: app))
            XCTAssertTrue(script.contains("application id \"\(app)\""))
            // Nothing that changes the terminal or runs anything in it.
            for word in ["set ", "activate", "to select", "do script", "do shell script", "write text", "close", "keystroke"] {
                XCTAssertFalse(script.contains(word), "\(app): \(word)")
            }
        }
        XCTAssertNil(TerminalWindow.frontScript(bundleId: ghostty))
        XCTAssertEqual(TerminalWindow.ttyName(fromOutput: "/dev/ttys003\n"), "ttys003")
        for bad in ["none", "", "ttys003", "/dev/console", "/dev/ttys3; rm -rf", "/dev/ttys12345", "missing value"] {
            XCTAssertNil(TerminalWindow.ttyName(fromOutput: bad), bad)
        }
        // An app that cannot be asked answers "not known" without running anything.
        let done = expectation(description: "answered")
        TerminalWindow.frontTTY(bundleId: ghostty) { tty in
            XCTAssertNil(tty)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
