import AppKit
import SwiftUI
import XCTest

@testable import LiteNotchUI

/// Reported: in the Island style the icon and time were drawn outside the
/// black shape. The shape was sized by one rule and the content laid out by
/// another.
///
/// A Mac has a camera housing or it does not, and the user picks Attached or
/// Island on either, so there are four layouts. In each, whatever the
/// closed notch shows must fit inside the shape the layout gives it.
@MainActor
final class ClosedSpaceTests: XCTestCase {
    private struct Machine {
        let name: String
        let layout: NotchLayout
    }

    private var machines: [Machine] {
        let notch = CGSize(width: 185, height: 32)
        return [
            Machine(name: "notch, attached", layout: NotchLayout(style: .attached, notch: notch, hasNotch: true, menuBarHeight: 32)),
            Machine(name: "notch, island", layout: NotchLayout(style: .island, notch: notch, hasNotch: true, menuBarHeight: 32)),
            Machine(
                name: "no notch, attached",
                layout: NotchLayout(
                    style: .attached, notch: NotchGeometry.fallbackSize,
                    hasNotch: false, menuBarHeight: 24)),
            Machine(
                name: "no notch, island",
                layout: NotchLayout(
                    style: .island, notch: NotchGeometry.fallbackSize,
                    hasNotch: false, menuBarHeight: 24)),
        ]
    }

    /// Running activities with the widest values they show: an hour-long
    /// countdown, a meeting item far over time, several agents.
    private var activities: [CompactView] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func c(_ kind: ActivityKind, _ title: String, _ value: String = "", ends: Int? = nil, count: Int = 1) -> CompactView {
            CompactView(kind: kind, title: title, value: value, endsAtMs: ends, totalSecs: nil, count: count)
        }
        return [
            c(.meeting, "Stand-up", ends: now - 754_000),
            c(.meeting, "Stand-up", "Paused"),
            c(.calendar, "Design review", ends: now + 3_590_000),
            c(.timer, "Timer", ends: now + 3_590_000),
            c(.timer, "Timer", "59:59"),
            c(.pomodoro, "Focus", ends: now + 3_590_000),
            c(.pomodoro, "Break", "4:59"),
            c(.media, "Weightless", "Marconi Union"),
            c(.caffeine, "Awake", ends: now + 3_590_000),
            c(.caffeine, "Awake", "lid"),
            c(.agent, "api", "working", count: 3),
            // Midnight before a 10:00 start, and two hours over.
            CompactView(
                kind: .day, title: "Day", value: "", endsAtMs: now + 18 * 3_600_000,
                totalSecs: 8 * 3600, count: 1),
            CompactView(
                kind: .day, title: "Day", value: "", endsAtMs: now - 2 * 3_600_000,
                totalSecs: 8 * 3600, count: 1),
            // A full gauge counting down, and one standing still.
            CompactView(kind: .body, title: "Water", value: "", endsAtMs: now + 5_400_000, totalSecs: 5400, count: 1),
            c(.body, "Stretch", "100%"),
        ]
    }

    /// The wider of the two day icon styles (sun or plant).
    private func width<V: View>(_ view: V) -> CGFloat {
        DayIcons.allCases.map { icons in
            NSHostingController(rootView: view.fixedSize().environment(\.colorScheme, .dark).environment(\.dayIcons, icons))
                .sizeThatFits(in: CGSize(width: 2000, height: 100)).width
        }.max() ?? 0
    }

    private func view(_ content: ClosedContent, _ layout: NotchLayout) -> ClosedActivityView {
        if layout.island {
            return ClosedActivityView(
                content: content, notchWidth: layout.centerWidth, ear: 0,
                wing: layout.wingWidth(for: content),
                edgePadding: NotchGeometry.islandWingPadding,
                artworkSize: min(20, layout.capsuleHeight - 4),
                artworkInset: (layout.capsuleHeight - min(20, layout.capsuleHeight - 4)) / 2,
                oneRow: layout.oneRow)
        }
        return ClosedActivityView(
            content: content, notchWidth: layout.notch.width, ear: 0,
            wing: layout.wingWidth(for: content), oneRow: layout.oneRow)
    }

    /// Fails when what is drawn is wider than the room the layout gives it.
    private func check(_ content: ClosedContent, on m: Machine, _ what: String) {
        let v = view(content, m.layout)
        let shape = m.layout.size(for: .closed, content: content).width - (m.layout.island ? 0 : 2 * NotchGeometry.closedEar)
        if m.layout.oneRow, content.primary != nil {
            XCTAssertLessThanOrEqual(width(v.row), shape + 0.5, "\(m.name): \(what) in one row")
        } else {
            let wing = m.layout.wingWidth(for: content)
            XCTAssertLessThanOrEqual(width(v.left), wing + 0.5, "\(m.name): left side of \(what)")
            XCTAssertLessThanOrEqual(width(v.right), wing + 0.5, "\(m.name): right side of \(what)")
            XCTAssertEqual(
                shape, m.layout.centerWidth + 2 * wing, accuracy: 0.5,
                "\(m.name): the shape is the middle plus both sides for \(what)")
        }
    }

    func testOneActivityFitsItsShapeOnEveryMachineAndStyle() {
        for m in machines {
            for a in activities {
                check(ClosedContent(primary: a), on: m, "\(a.kind) \(a.value)")
                check(ClosedContent(primary: a, waiting: true), on: m, "\(a.kind) \(a.value) with the dot")
            }
            check(ClosedContent(primary: nil, waiting: true), on: m, "the dot alone")
        }
    }

    func testTwoActivitiesFitTheirShapeOnEveryMachineAndStyle() {
        for m in machines {
            for a in activities {
                for b in activities where a.kind != b.kind {
                    check(
                        ClosedContent(primary: a, secondary: b, waiting: true), on: m,
                        "\(a.kind) \(a.value) + \(b.kind) \(b.value) with the dot")
                }
            }
        }
    }

    func testTheSettingsPreviewDrawsInsideItsShapeInEveryLayout() {
        for hasNotch in [true, false] {
            for island in [false, true] {
                let layout = NotchPreview.layout(island: island, hasNotch: hasNotch)
                XCTAssertEqual(layout.oneRow, !hasNotch)
                for s in NotchPriority.situations {
                    let content = NotchPriority.content(for: s, config: .default)
                    let shape = NotchPreview.shapeWidth(layout, content: content)
                    let v = view(content, layout)
                    let name = "\(hasNotch ? "notch" : "no notch"), \(island ? "island" : "attached"), \(s.title)"
                    if layout.oneRow, content.primary != nil {
                        XCTAssertLessThanOrEqual(width(v.row), shape + 0.5, name)
                    } else {
                        let wing = layout.wingWidth(for: content)
                        XCTAssertLessThanOrEqual(width(v.left), wing + 0.5, name)
                        XCTAssertLessThanOrEqual(width(v.right), wing + 0.5, name)
                        XCTAssertEqual(shape, layout.centerWidth + 2 * wing, accuracy: 0.5, name)
                    }
                    // Room for it inside the Settings pane.
                    XCTAssertLessThanOrEqual(shape, 400, name)
                }
            }
        }
    }

    // MARK: Shrink

    func testShrinkWithACameraHousingOnlyHasAlways() {
        let busy = ClosedContent(primary: activities[5])
        let empty = ClosedContent(primary: nil)
        // Without a notch: unchanged.
        XCTAssertTrue(NotchLayout.shrinks(.whenEmpty, content: empty, peek: false, hasNotch: false))
        XCTAssertFalse(NotchLayout.shrinks(.whenEmpty, content: busy, peek: false, hasNotch: false))
        XCTAssertTrue(NotchLayout.shrinks(.always, content: busy, peek: false, hasNotch: false))
        // With one: "when empty" means nothing (an empty notch already is
        // just the notch); "always" keeps the sides clear, except for a peek.
        XCTAssertFalse(NotchLayout.shrinks(.whenEmpty, content: empty, peek: false, hasNotch: true))
        XCTAssertFalse(NotchLayout.shrinks(.whenEmpty, content: busy, peek: false, hasNotch: true))
        XCTAssertTrue(NotchLayout.shrinks(.always, content: busy, peek: false, hasNotch: true))
        XCTAssertFalse(NotchLayout.shrinks(.always, content: busy, peek: true, hasNotch: true))
        XCTAssertFalse(NotchLayout.shrinks(.off, content: busy, peek: false, hasNotch: true))

        // Shrunk beside a housing, the shape is the bare notch: full height,
        // so the pointer finds it, and nothing beside it.
        let notch = CGSize(width: 185, height: 32)
        for style in [NotchStyle.attached, .island] {
            let shrunk = NotchLayout(style: style, notch: notch, hasNotch: true, menuBarHeight: 32, minimized: true)
            let plain = NotchLayout(style: style, notch: notch, hasNotch: true, menuBarHeight: 32)
            XCTAssertEqual(shrunk.size(for: .closed, content: busy), plain.size(for: .closed, content: empty), "\(style)")
            XCTAssertGreaterThan(shrunk.size(for: .closed, content: busy).height, NotchGeometry.minimizedSize.height)
            // Open and as a toast it is the full shape.
            XCTAssertEqual(shrunk.size(for: .expanded, content: busy), plain.size(for: .expanded, content: busy))
            XCTAssertEqual(shrunk.size(for: .toast, content: busy), plain.size(for: .toast, content: busy))
        }
        // Without a housing it is still the thin strip.
        let strip = NotchLayout(
            style: .attached, notch: NotchGeometry.fallbackSize, hasNotch: false, menuBarHeight: 24,
            minimized: true)
        XCTAssertEqual(strip.size(for: .closed, content: busy), NotchGeometry.minimizedSize)
    }

    // MARK: Smaller things from the same round

    /// Reported: the number in a `− 12 +` control could not be edited. The
    /// typing was ended by "not focused" before the field ever had focus.
    func testStepperTypingEndsOnlyWhenAFocusItHadIsLost() {
        XCTAssertFalse(MiniStepper.endsTyping(focused: false, hadFocus: false), "just opened")
        XCTAssertFalse(MiniStepper.endsTyping(focused: true, hadFocus: true))
        XCTAssertTrue(MiniStepper.endsTyping(focused: false, hadFocus: true), "the user clicked or tabbed away")
    }

    func testFocusAndBreakHaveDifferentIcons() {
        XCTAssertEqual(ClosedActivityView.pomodoroSymbol(title: "Focus"), "timer")
        XCTAssertEqual(ClosedActivityView.pomodoroSymbol(title: "Pomodoro"), "timer")
        XCTAssertEqual(ClosedActivityView.pomodoroSymbol(title: "Break"), "leaf.fill")
        XCTAssertEqual(ClosedActivityView.pomodoroSymbol(title: "Long break"), "leaf.fill")
    }

    func testTheSoundSettingAndItsPicker() throws {
        XCTAssertEqual(SoundConfig.default, SoundConfig(enabled: true, name: "Glass"))
        XCTAssertTrue(SoundConfig.sounds.contains(SoundConfig.defaultName))
        XCTAssertEqual(SoundPicker.next(after: "Glass", step: 1), "Hero")
        XCTAssertEqual(SoundPicker.next(after: "Glass", step: -1), "Funk")
        XCTAssertEqual(SoundPicker.next(after: "Tink", step: 1), "Basso", "wraps round")
        XCTAssertEqual(SoundPicker.next(after: "Basso", step: -1), "Tink")
        XCTAssertEqual(SoundPicker.next(after: "not a sound", step: 1), "Glass")
        XCTAssertEqual(ShellCommand.soundPreview(name: "Ping").encode(), #"{"cmd":"sound_preview","name":"Ping"}"#)

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/idle.json")
        var settings = try ViewModel.decode(Data(contentsOf: url)).settings
        XCTAssertEqual(settings.sound, .default, "what the core sends by default")
        settings.sound = SoundConfig(enabled: false, name: "Hero")
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(ShellCommand.setSettings(settings).encode().utf8)) as? [String: Any])
        let sound = try XCTUnwrap((sent["settings"] as? [String: Any])?["sound"] as? [String: Any])
        XCTAssertEqual(sound as NSDictionary, ["enabled": false, "name": "Hero"] as NSDictionary)
    }
}
