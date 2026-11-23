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
        XCTAssertEqual(found.latest, "0.3.0-beta")
        XCTAssertEqual(found.command, UpdateText.brewCommand, "the core's text is the one the shell copies")
        XCTAssertNotNil(UpdateText.releasePage(found.url), "the core's page opens")

        let current = try fixture("update-current").update
        XCTAssertEqual(current.status, .upToDate)
        XCTAssertNil(current.latest)
        XCTAssertEqual(UpdateText.caption(current), "You have the latest version.")
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
