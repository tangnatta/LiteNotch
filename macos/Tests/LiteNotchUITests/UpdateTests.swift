import XCTest

@testable import LiteNotchUI

private func fixture(_ name: String) throws -> ViewModel {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try ViewModel.decode(Data(contentsOf: url))
}

final class UpdateTests: XCTestCase {
    func testTheShellShowsWhatTheCoreSaysAboutTheCheck() throws {
        let idle = try fixture("idle").update
        XCTAssertFalse(idle.current.isEmpty, "this build's version comes from the core")
        XCTAssertEqual(idle.status, .idle)
        XCTAssertEqual(UpdateText.caption(idle), "Not checked yet.")

        XCTAssertEqual(try fixture("update-checking").update.status, .checking)
        XCTAssertEqual(UpdateText.caption(try fixture("update-checking").update), "Asking GitHub\u{2026}")

        let found = try fixture("update-available").update
        XCTAssertEqual(found.status, .available)
        XCTAssertEqual(found.latest?.hasPrefix("0.3.0"), true)
        XCTAssertEqual(found.command, UpdateText.command(found), "the core's text is the one the shell copies")
        XCTAssertNotNil(UpdateText.releasePage(found.url), "the core's page opens")

        let current = try fixture("update-current").update
        XCTAssertEqual(current.status, .upToDate)
        XCTAssertNil(current.latest)
        XCTAssertEqual(
            UpdateText.caption(current),
            current.channel == .beta ? "You have the latest beta." : "You have the latest version.")
    }

    // MARK: Channels

    private func view(_ channel: UpdateChannel?, _ status: UpdateStatus = .idle) -> UpdateView {
        UpdateView(
            current: "0.2.6", status: status, latest: nil, url: nil, checkedMs: nil, command: "",
            channel: channel)
    }

    func testEachChannelCopiesItsOwnCaskCommand() {
        XCTAssertEqual(UpdateText.command(view(.stable)), "brew update && brew upgrade --cask litenotch")
        XCTAssertEqual(UpdateText.command(view(.beta)), "brew update && brew upgrade --cask litenotch@beta")
        XCTAssertEqual(UpdateText.command(view(nil)), UpdateText.brewCommand, "a core without channels is stable")
        XCTAssertEqual(UpdateText.command(view(.unknown)), UpdateText.brewCommand, "never guesses the beta cask")
    }

    func testCaptionsNameTheBetaChannel() {
        XCTAssertEqual(UpdateText.caption(view(.beta, .upToDate)), "You have the latest beta.")
        XCTAssertEqual(UpdateText.caption(view(.beta, .available)), "A newer beta is available.")
        XCTAssertEqual(UpdateText.caption(view(.stable, .upToDate)), "You have the latest version.")
        XCTAssertEqual(UpdateText.caption(view(.stable, .available)), "A newer version is available.")
        XCTAssertEqual(UpdateText.caption(view(nil, .available)), "A newer version is available.")
    }

    func testTheChannelDecodesFromTheCoreAndAnOlderCoreHasNone() throws {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let json = #"{"current":"0.2.6-beta","status":"idle","command":"x","channel":"beta"}"#
        XCTAssertEqual(try d.decode(UpdateView.self, from: Data(json.utf8)).channel, .beta)
        let older = #"{"current":"0.2.5","status":"idle","command":"x"}"#
        XCTAssertNil(try d.decode(UpdateView.self, from: Data(older.utf8)).channel)
        let future = #"{"current":"1.0.0","status":"idle","command":"x","channel":"nightly"}"#
        XCTAssertEqual(try d.decode(UpdateView.self, from: Data(future.utf8)).channel, .unknown)
        XCTAssertNotNil(try fixture("idle").update.channel, "the core says which channel it is")
    }

    func testTheButtonSendsTheCheckCommand() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(ShellCommand.updateCheck.encode().utf8)) as? NSDictionary
        XCTAssertEqual(obj, ["cmd": "update_check"])
    }

    func testOnlyAReleasePageOfOursIsOpened() {
        let base = UpdateText.releasesPage
        XCTAssertNotNil(UpdateText.releasePage("\(base)/tag/v0.3.0-beta"))
        XCTAssertNotNil(UpdateText.releasePage(base))
        for bad in [
            nil, "", "http://github.com/tangnatta/LiteNotch/releases/tag/v1",
            "https://github.com.evil.example/tangnatta/LiteNotch/releases",
            "https://github.com/tangnatta/LiteNotchEvil",
            "\(base)/tag/v1?x=1", "\(base)/tag/v1 && open", "\(base)/../../x@evil", "file:///etc/passwd",
            "x-apple.systempreferences:", String(repeating: "a", count: 400),
        ] as [String?] {
            XCTAssertNil(UpdateText.releasePage(bad), "\(bad ?? "nil")")
        }
    }

    func testTheAutomaticCheckIsOffUnlessTurnedOn() throws {
        XCTAssertFalse(try fixture("idle").settings.general.checkUpdates)
        let old = try JSONDecoder().decode(
            GeneralSettings.self,
            from: Data(
                #"{"persistClipboard":false,"hoverToExpand":true,"usageAlerts":true}"#.utf8))
        XCTAssertFalse(old.checkUpdates, "settings saved before it existed")
    }
}
