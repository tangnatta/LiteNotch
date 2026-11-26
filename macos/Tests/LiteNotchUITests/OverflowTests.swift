import AppKit
import SwiftUI
import XCTest

@testable import LiteNotchUI

private func fixture(_ name: String) throws -> ViewModel {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try ViewModel.decode(Data(contentsOf: url))
}

/// Reported: the bottom rows of a Settings pane could not be scrolled into
/// view. The list of sections had grown taller than the panel, which pushed
/// the whole tab, scroll view included, past the bottom edge.
///
/// Every tab must fit the space the open panel gives it; whatever is longer
/// has to scroll inside that space.
@MainActor
final class OverflowTests: XCTestCase {
    /// The space a tab gets inside the open panel (see `ExpandedView`).
    private var room: CGSize {
        let header = max(NotchGeometry.fallbackSize.height, NotchGeometry.islandHeaderHeight)
        return CGSize(
            width: NotchGeometry.expandedSize.width - 2 * (NotchGeometry.expandedEar + 14),
            height: NotchGeometry.expandedSize.height - header - 8 - 20)
    }

    /// The height the view insists on when offered `room`.
    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingController(rootView: view.frame(width: room.width))
        return host.sizeThatFits(in: room).height
    }

    private func panel(_ name: String, _ change: (inout ViewModel) -> Void = { _ in }) throws -> (ViewModel, PanelState) {
        let model = AppModel(bridge: MockBridge())
        var vm = try fixture(name)
        change(&vm)
        model.apply(vm)
        keep.append(model)
        return (vm, model.primary)
    }
    private var keep: [AppModel] = []

    func testEverySettingsSectionFitsThePanel() throws {
        SettingsTab.showMoreOptions = true
        defer { SettingsTab.showMoreOptions = false }
        for name in ["idle", "media", "pair"] {
            for section in SettingsSection.allCases {
                let (vm, p) = try panel(name) {
                    $0.settings.calendar.enabled = true
                    $0.settings.notify.system = true
                }
                p.settingsSection = section
                p.app?.accessibilityNeeded = true
                p.app?.calendarAccess = .denied
                XCTAssertLessThanOrEqual(
                    height(SettingsTab(vm: vm, model: p)), room.height,
                    "Settings › \(section.title) with the \(name) fixture")
            }
        }
    }

    func testEveryOtherTabFitsThePanel() throws {
        for name in ["idle", "media", "pomodoro", "pair", "banner", "caffeine", "calendar", "day"] {
            let (vm, p) = try panel(name)
            XCTAssertLessThanOrEqual(height(HomeTab(vm: vm, model: p)), room.height, "Home, \(name)")
            XCTAssertLessThanOrEqual(height(MusicTab(vm: vm, model: p)), room.height, "Music, \(name)")
            XCTAssertLessThanOrEqual(height(ClipboardTab(vm: vm, model: p)), room.height, "Clipboard, \(name)")
            XCTAssertLessThanOrEqual(height(InboxTab(vm: vm, model: p)), room.height, "Inbox, \(name)")
            for pane in TimerPane.allCases {
                p.timerPane = pane
                XCTAssertLessThanOrEqual(height(TimerTab(vm: vm, model: p)), room.height, "Timer › \(pane), \(name)")
            }
            for pane in AgentsPane.allCases {
                p.agentsPane = pane
                XCTAssertLessThanOrEqual(height(AgentsTab(vm: vm, model: p)), room.height, "Agents › \(pane), \(name)")
            }
        }
    }

    func testEveryCalendarPageFitsThePanel() throws {
        for name in ["calendar", "calendar-detail", "idle"] {
            let (vm, p) = try panel(name) { $0.settings.calendar.enabled = true }
            let key = vm.calendar.events.first?.key ?? "0-none"
            for page in [CalendarPage.list, .event(key), .edit(key), .new] {
                p.calendarPage = page
                XCTAssertLessThanOrEqual(height(CalendarTab(vm: vm, model: p)), room.height, "Calendar › \(page), \(name)")
            }
            p.app?.calendarAccess = .denied
            XCTAssertLessThanOrEqual(height(CalendarTab(vm: vm, model: p)), room.height, "Calendar, no permission")
        }
        // A detail with as much as the core lets through.
        let (vm, p) = try panel("calendar-detail") {
            $0.calendar.detail?.notes = Array(repeating: String(repeating: "word ", count: 40), count: 40)
                .joined(separator: "\n")
            let someone = $0.calendar.detail!.attendees[0]
            $0.calendar.detail?.attendees = Array(repeating: someone, count: 30)
            $0.calendar.detail?.attendeesMore = 12
            $0.calendar.detail?.title = String(repeating: "Long title ", count: 12)
            $0.calendar.detail?.url = "https://" + String(repeating: "a", count: 290)
        }
        p.calendarPage = .event(vm.calendar.detail!.key)
        XCTAssertLessThanOrEqual(height(CalendarTab(vm: vm, model: p)), room.height, "Calendar, the longest detail")
    }

    func testTheWelcomeFitsThePanel() {
        // Its own height, not the room it is offered: nothing here scrolls.
        XCTAssertLessThanOrEqual(height(WelcomeCard {}.fixedSize(horizontal: false, vertical: true)), room.height)
    }

    func testTheCheckNoticesAViewThatIsTooTall() {
        // Guards the test itself: a fixed column taller than the room must
        // be reported, and the same column in a scroll view must not.
        let tall = VStack(spacing: 0) { ForEach(0..<20, id: \.self) { _ in Color.clear.frame(height: 26) } }
        XCTAssertGreaterThan(height(tall), room.height)
        XCTAssertLessThanOrEqual(height(NotchScroll { tall }), room.height)
    }
}
