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
        let header = max(NotchGeometry.fallbackSize.height, NotchGeometry.floatingHeaderHeight)
        return CGSize(width: NotchGeometry.expandedSize.width - 2 * (NotchGeometry.expandedEar + 14),
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
        for name in ["idle", "media", "pair"] {
            for section in SettingsSection.allCases {
                let (vm, p) = try panel(name) {
                    $0.settings.calendar.enabled = true
                    $0.settings.notify.system = true
                }
                p.settingsSection = section
                p.app?.accessibilityNeeded = true
                p.app?.calendarAccess = .denied
                XCTAssertLessThanOrEqual(height(SettingsTab(vm: vm, model: p)), room.height,
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

    func testTheCheckNoticesAViewThatIsTooTall() {
        // Guards the test itself: a fixed column taller than the room must
        // be reported, and the same column in a scroll view must not.
        let tall = VStack(spacing: 0) { ForEach(0..<20, id: \.self) { _ in Color.clear.frame(height: 26) } }
        XCTAssertGreaterThan(height(tall), room.height)
        XCTAssertLessThanOrEqual(height(NotchScroll { tall }), room.height)
    }
}
