import XCTest
@testable import LiteNotchUI

private final class FakeLogin: LoginItemService {
    var status: LoginItemStatus
    var fails = false
    var calls: [Bool] = []
    init(_ status: LoginItemStatus) { self.status = status }
    func set(_ enabled: Bool) throws {
        calls.append(enabled)
        if fails { throw NSError(domain: "fake", code: 1) }
        status = enabled ? .on : .off
    }
    func openSystemSettings() {}
}

final class LoginItemTests: XCTestCase {
    private func model(_ fake: FakeLogin) -> AppModel {
        let m = AppModel(bridge: MockBridge())
        m.loginItem = fake
        return m
    }

    func testTurningItOnAndOffFollowsTheSystem() {
        let fake = FakeLogin(.off)
        let m = model(fake)
        m.refreshLaunchAtLogin()
        XCTAssertEqual(m.launchAtLogin, .off)
        m.setLaunchAtLogin(true)
        XCTAssertEqual(m.launchAtLogin, .on)
        m.setLaunchAtLogin(false)
        XCTAssertEqual(m.launchAtLogin, .off)
        XCTAssertEqual(fake.calls, [true, false])
    }

    func testAFailureShowsWhatTheSystemReallyHas() {
        let fake = FakeLogin(.off)
        fake.fails = true
        let m = model(fake)
        m.setLaunchAtLogin(true)
        XCTAssertEqual(m.launchAtLogin, .off, "the toggle must not claim a state macOS did not accept")
    }

    func testAChangeMadeInSystemSettingsIsPickedUp() {
        let fake = FakeLogin(.on)
        let m = model(fake)
        m.refreshLaunchAtLogin()
        XCTAssertEqual(m.launchAtLogin, .on)
        fake.status = .needsApproval
        m.refreshLaunchAtLogin()
        XCTAssertEqual(m.launchAtLogin, .needsApproval)
        XCTAssertFalse(LoginItemStatus.needsApproval.caption.isEmpty)
    }

    func testTheRowIsCalledLaunchNotOpen() {
        XCTAssertEqual(LoginItemStatus.title, "Launch at login")
        for status in [LoginItemStatus.off, .on, .needsApproval, .unavailable] {
            XCTAssertFalse(status.caption.contains("Opens the notch"), "Open reads as the panel opening")
        }
        XCTAssertEqual(LoginItemStatus.on.caption, LoginItemStatus.off.caption, "on and off share one line")
        XCTAssertTrue(LoginItemStatus.off.caption.contains("Starts LiteNotch"))
    }

    func testWaitingForApprovalIsNotOnAndPointsToSystemSettings() {
        XCTAssertFalse(LoginItemStatus.needsApproval.isOn)
        XCTAssertTrue(LoginItemStatus.needsApproval.caption.contains("Login Items"))
    }

    func testACopyMacOSCannotFindExplainsWhatToDo() {
        let fake = FakeLogin(.unavailable)
        fake.fails = true
        let m = model(fake)
        m.setLaunchAtLogin(true)
        XCTAssertEqual(m.launchAtLogin, .unavailable)
        XCTAssertFalse(m.launchAtLogin.isOn)
        XCTAssertTrue(m.launchAtLogin.caption.contains("Applications"))
    }
}
