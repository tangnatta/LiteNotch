import XCTest

@testable import LiteNotchUI

/// The shell shows and edits what the core holds. These tests hold the two to
/// each other, using what the core itself wrote (`Fixtures/*.json`, made by
/// `cargo run -p litenotch-core --example fixtures`): the same enum values,
/// the same sounds, controls that offer only what the core keeps, and every
/// setting and view-model field known on both sides.
final class ParityTests: XCTestCase {
    private static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.dir.appendingPathComponent("\(name).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Self.dir.path)
            .filter { $0.hasSuffix(".json") && $0 != "schema.json" }
            .map { String($0.dropLast(5)) }.sorted()
    }

    // MARK: Enums

    private func check<E: CaseIterable & RawRepresentable>(
        _ name: String, _ type: E.Type,
        file: StaticString = #filePath, line: UInt = #line
    ) throws
    where E.RawValue == String {
        let core = try XCTUnwrap(try json("schema")["enums"] as? [String: [String]])[name]
        let shell = E.allCases.map(\.rawValue).filter { $0 != "unknown" }
        XCTAssertEqual(
            Set(shell), Set(try XCTUnwrap(core, name)), "\(name): shell and core list different values",
            file: file, line: line)
        XCTAssertEqual(shell.count, core?.count, "\(name): a value is listed twice", file: file, line: line)
    }

    func testEveryEnumHasTheCoresValuesAndNoOthers() throws {
        try check("theme", ThemeChoice.self)
        try check("notch_style", NotchStyle.self)
        try check("closed_notch", ClosedNotchChoice.self)
        try check("shrink", ShrinkChoice.self)
        try check("material", MaterialChoice.self)
        try check("home_card", HomeCard.self)
        try check("day_icons", DayIcons.self)
        try check("priority", Priority.self)
        try check("awake_mode", AwakeMode.self)
        try check("lid_state", LidState.self)
        try check("agent_status", AgentStatus.self)
        try check("clip_kind", ClipKind.self)
        try check("phase", Phase.self)
        try check("run_state", RunState.self)
        try check("tab", Tab.self)
        try check("attendee_status", AttendeeStatus.self)
        try check("update_status", UpdateStatus.self)
        try check("update_channel", UpdateChannel.self)
        try check("peek_kind", PeekKind.self)
        try check("activity_kind", ActivityKind.self)
    }

    func testTheUpdateCommandIsTheCores() throws {
        XCTAssertEqual(UpdateText.brewCommand, try json("schema")["brew_command"] as? String)
        XCTAssertEqual(UpdateText.brewCommandBeta, try json("schema")["brew_command_beta"] as? String)
        XCTAssertEqual(UpdateText.releasesPage, "https://github.com/tangnatta/LiteNotch/releases")
    }

    func testTheSoundsAreTheCoresSounds() throws {
        XCTAssertEqual(SoundConfig.sounds, try XCTUnwrap(try json("schema")["sounds"] as? [String]))
    }

    // MARK: Ranges

    private func limit(_ path: String) throws -> ClosedRange<Int> {
        let limits = try XCTUnwrap(try json("schema")["limits"] as? [String: [Int]])
        let pair = try XCTUnwrap(limits[path], path)
        return pair[0]...pair[1]
    }

    private func within(
        _ ui: ClosedRange<Int>, _ path: String, scale: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let core = try limit(path)
        XCTAssertTrue(
            core.contains(ui.lowerBound * scale) && core.contains(ui.upperBound * scale),
            "\(path): the control offers \(ui.lowerBound * scale)...\(ui.upperBound * scale), the core keeps \(core)",
            file: file, line: line)
    }

    private func choices(_ values: [Int], _ path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let core = try limit(path)
        for v in values where v != 0 {
            XCTAssertTrue(
                core.contains(v), "\(path): the control offers \(v), the core keeps \(core)",
                file: file, line: line)
        }
        XCTAssertTrue(values.contains(0), "\(path): 0 (off) is offered", file: file, line: line)
    }

    func testEveryControlOffersOnlyWhatTheCoreKeeps() throws {
        for path in ["pomodoro.focus_secs", "pomodoro.short_break_secs", "pomodoro.long_break_secs"] {
            try within(SettingsLimits.pomodoroMinutes, path, scale: 60)
        }
        try within(SettingsLimits.rounds, "pomodoro.rounds_before_long")
        try within(SettingsLimits.bannerSecs, "notify.banner_secs")
        try within(SettingsLimits.clipboardItems, "clipboard.max_items")
        try within(SettingsLimits.approvalSecs, "agent.approval_timeout_secs")
        try within(SettingsLimits.alertMinutes, "calendar.alert_minutes")
        try within(SettingsLimits.batteryFloor, "caffeine.battery_floor_pct")
        try within(SettingsLimits.dayStart, "day.start_min")
        try choices(SettingsLimits.timeWarningSecs, "peek.time_warning_secs")
        try choices(SettingsLimits.eyeBreakMins, "peek.eye_break_mins")
        try choices(SettingsLimits.moveMins, "peek.move_mins")
    }

    func testTheOfficeHoursSpanIsTheCores() throws {
        let start = try XCTUnwrap(try json("idle")["settings"] as? [String: Any])["day"] as? [String: Any]
        let startMin = try XCTUnwrap(start?["start_min"] as? Int)
        // The core keeps the end at least this long after the start.
        XCTAssertEqual(try limit("day.end_min").lowerBound - startMin, SettingsLimits.dayMinSpan)
        XCTAssertEqual(try limit("day.end_min").upperBound, SettingsLimits.dayEnd.upperBound)
    }

    // MARK: Fields

    private func same(_ a: Any, _ b: Any, _ path: String, _ problems: inout [String]) {
        switch (a, b) {
        case (let x as [String: Any], let y as [String: Any]):
            for key in Set(x.keys).union(y.keys).sorted() {
                switch (x[key], y[key]) {
                case (let l?, let r?): same(l, r, "\(path).\(key)", &problems)
                case (nil, _): problems.append("\(path).\(key): the core has a setting the shell drops")
                case (_, nil): problems.append("\(path).\(key): the shell writes a setting the core does not have")
                }
            }
        case (let x as [Any], let y as [Any]):
            if x.count != y.count {
                problems.append("\(path): \(x.count) items against \(y.count)")
                return
            }
            for (i, pair) in zip(x, y).enumerated() { same(pair.0, pair.1, "\(path)[\(i)]", &problems) }
        default:
            if !(a as AnyObject).isEqual(b) { problems.append("\(path): shell \(a), core \(b)") }
        }
    }

    func testEverySettingTheCoreWritesSurvivesTheShellUnchanged() throws {
        for name in try fixtureNames() {
            let vm = try json(name)
            let core = try XCTUnwrap(vm["settings"] as? [String: Any], name)
            let settings = try JSONDecoder.snake.decode(
                Settings.self,
                from: JSONSerialization.data(withJSONObject: core))
            let back = try JSONSerialization.jsonObject(with: JSONEncoder.snake.encode(settings))
            var problems: [String] = []
            same(back, core, "settings", &problems)
            XCTAssertEqual(problems, [], "\(name).json")
        }
    }

    func testEveryTopLevelFieldOfTheViewModelIsKnownToTheShell() throws {
        let known = Set(
            Mirror(
                reflecting: try ViewModel.decode(
                    Data(contentsOf: Self.dir.appendingPathComponent("idle.json")))
            ).children
                .compactMap { $0.label }
                .map { label in label.reduce(into: "") { $0 += $1.isUppercase ? "_\($1.lowercased())" : String($1) } })
        for name in try fixtureNames() {
            let keys = Set(try json(name).keys)
            XCTAssertEqual(keys.subtracting(known), [], "\(name).json: sent by the core, unknown to the shell")
        }
    }

    /// Settings the core has that Settings shows no control for, and why. A
    /// new core setting must either get a control or be added here on purpose.
    private static let withoutControl: [String: String] = [
        "pomodoro.utc_offset_secs": "the system's time zone, sent by the shell itself",
        "clipboard.max_item_bytes": "a memory limit, not a preference",
        "clipboard.max_total_bytes": "a memory limit, not a preference",
        "clipboard.excluded_apps": "no editor yet",
        "notify.max_history": "a memory limit, not a preference",
        "notify.dnd_min_priority": "Settings offers only whether focus holds notifications",
        "agent.session_ttl_secs": "timing of the session list, no control",
        "agent.session_keep_secs": "timing of the session list, no control",
        "agent.auto_allow_tools": "no editor yet; allowing tools unseen stays a file-only choice",
        "analytics.share": "uploading is not implemented",
    ]

    func testEverySettingHasAControlOrAStatedReason() throws {
        let src = try ["SettingsTab", "NotchPriority"].map {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Sources/LiteNotchUI/\($0).swift"))
        }.joined()
        func camel(_ s: String) -> String {
            let p = s.split(separator: "_").map(String.init)
            return p[0] + p.dropFirst().map(\.capitalized).joined()
        }
        let settings = try XCTUnwrap(try json("idle")["settings"] as? [String: Any])
        var found = Set<String>()
        for (group, value) in settings {
            for key in (value as? [String: Any])?.keys.sorted() ?? [] {
                let path = "\(group).\(key)"
                found.insert(path)
                // The notch group is edited by its own pane, through `config`.
                let shown =
                    src.contains("\(camel(group)).\(camel(key))")
                    || (group == "notch" && src.contains("config.\(camel(key))"))
                XCTAssertTrue(
                    shown || Self.withoutControl[path] != nil,
                    "\(path) is a core setting with no control in Settings and no reason listed")
                XCTAssertFalse(
                    shown && Self.withoutControl[path] != nil,
                    "\(path) has a control now: take it off the list")
            }
        }
        for path in Self.withoutControl.keys {
            XCTAssertTrue(found.contains(path), "\(path) is listed but the core no longer has it")
        }
    }
}

extension JSONDecoder {
    fileprivate static var snake: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
extension JSONEncoder {
    fileprivate static var snake: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}
