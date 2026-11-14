import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    /// Only true while the clipboard search field wants keystrokes.
    var allowsKey = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        titleVisibility = .hidden
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that lets clicks fall through everywhere except the notch
/// shape, so the large transparent window never blocks apps underneath.
final class NotchHostingView: NSHostingView<NotchRootView> {
    var shapeSize: () -> CGSize = { .zero }
    /// Takes a point from the top-left of the shape's area.
    var shapeContains: (CGPoint) -> Bool = { _ in true }

    required init(rootView: NotchRootView) {
        super.init(rootView: rootView)
        // The window is fixed-size; SwiftUI content must not resize it.
        sizingOptions = []
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let rect = NotchGeometry.shapeRect(in: bounds.size, shape: shapeSize(), flipped: isFlipped)
        guard rect.contains(local) else { return nil }
        let p = CGPoint(x: local.x - rect.minX, y: isFlipped ? local.y - rect.minY : rect.maxY - local.y)
        guard shapeContains(p) else { return nil }
        // Inside the shape something always takes the event. SwiftUI answers
        // nil over its empty areas, and a scroll there went to the app behind.
        return super.hitTest(point) ?? self
    }
}

/// One notch: its window and its presentation state.
private final class PanelEntry {
    let window: NotchPanel
    let state: PanelState
    var cancellables: Set<AnyCancellable> = []

    init(window: NotchPanel, state: PanelState) {
        self.window = window
        self.state = state
    }
}

/// Owns the panels: one on the built-in (or main) display, or one per
/// display when "Show on every display" is on. Keeps them on the right
/// screens and in line with the setting.
public final class NotchPanelController {
    private let model: AppModel
    private var entries: [CGDirectDisplayID: PanelEntry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClicks: Any?
    private var insideClicks: Any?
    private var shown = false

    public init(model: AppModel) {
        self.model = model
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let insideClicks { NSEvent.removeMonitor(insideClicks) }
    }

    /// Creates the panels, positions them and orders them front.
    public func show() {
        shown = true
        if observers.isEmpty { observe() }
        if outsideClicks == nil {
            // Fires only for clicks delivered to other apps, i.e. outside every notch.
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.entries.values.forEach { $0.state.clickedOutside() }
            }
        }
        if insideClicks == nil {
            // A click on one notch closes the others.
            insideClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.entries.values.forEach { if $0.window !== event.window { $0.state.clickedOutside() } }
                return event
            }
        }
        rebuild()
    }

    public func hide() {
        shown = false
        entries.values.forEach { $0.window.orderOut(nil) }
    }

    private func observe() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        model.$view
            .map { $0?.settings.general.allScreens ?? false }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    /// Built-in display with a notch if there is one, else the main screen.
    static func chooseScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The screens that get a notch, the primary one first.
    static func screens(allScreens: Bool) -> [NSScreen] {
        guard let first = chooseScreen() else { return [] }
        guard allScreens else { return [first] }
        return [first] + NSScreen.screens.filter { $0 != first }
    }

    private static func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Brings the panels in line with the screens and the setting.
    public func rebuild() {
        guard shown else { return }
        let all = model.view?.settings.general.allScreens ?? false
        let screens = Self.screens(allScreens: all).compactMap { s in Self.displayID(s).map { (s, $0) } }
        let primaryID = screens.first?.1
        var keep: Set<CGDirectDisplayID> = []
        for (screen, id) in screens {
            keep.insert(id)
            let entry: PanelEntry
            if let e = entries[id], (e.state === model.primary) == (id == primaryID) {
                entry = e
            } else {
                if let old = entries[id] { remove(old) }
                // The primary state moves with the primary screen.
                if id == primaryID, let holder = entries.first(where: { $0.value.state === model.primary }) {
                    remove(holder.value)
                    entries[holder.key] = nil
                }
                entry = make(state: id == primaryID ? model.primary : model.addPanel())
                entries[id] = entry
            }
            place(entry, on: screen)
            entry.window.orderFrontRegardless()
        }
        for (id, e) in entries where !keep.contains(id) {
            remove(e)
            entries[id] = nil
        }
    }

    private func make(state: PanelState) -> PanelEntry {
        let window = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300))
        let host = NotchHostingView(rootView: NotchRootView(model: state))
        host.shapeSize = { [weak state] in state?.targetSize ?? .zero }
        host.shapeContains = { [weak state] p in state?.shapeContains(p) ?? false }
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        let entry = PanelEntry(window: window, state: state)
        state.$keyboardRequested
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak entry] on in entry.map { Self.setKeyboard(on, $0.window) } }
            .store(in: &entry.cancellables)
        return entry
    }

    private func remove(_ e: PanelEntry) {
        e.cancellables.removeAll()
        e.state.close()
        e.window.orderOut(nil)
        e.window.contentView = nil
        model.removePanel(e.state)
    }

    private static func setKeyboard(_ on: Bool, _ panel: NotchPanel) {
        panel.allowsKey = on
        if on {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            // Re-ordering a window that can no longer be key hands the
            // keyboard back to the app the user was in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func place(_ e: PanelEntry, on screen: NSScreen) {
        let notch = NotchGeometry.notchRect(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAux: screen.auxiliaryTopLeftArea,
            rightAux: screen.auxiliaryTopRightArea)
        if e.state.notch != notch.size { e.state.notch = notch.size }
        let hasNotch = screen.safeAreaInsets.top > 0
        if e.state.hasNotch != hasNotch { e.state.hasNotch = hasNotch }
        // Zero on a screen whose menu bar hides itself.
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        if e.state.menuBarHeight != menuBar { e.state.menuBarHeight = menuBar }
        e.window.setFrame(NotchGeometry.panelFrame(screenFrame: screen.frame, notch: notch), display: true)
    }
}
