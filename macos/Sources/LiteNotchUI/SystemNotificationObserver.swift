import AppKit
import ApplicationServices
import Combine
import Foundation

// Other apps' notifications. macOS has no API for them, so the banners that
// Notification Center draws are read through the Accessibility API, which
// needs the user's permission (Privacy & Security › Accessibility).
// Event-driven: nothing here polls, except the bounded wait for permission.

/// The few accessibility attributes the parser needs, as plain data so the
/// parsing can be tested without a live accessibility tree.
public struct AXNode: Equatable {
    public var role: String
    public var subrole: String
    public var identifier: String
    public var value: String
    public var description: String
    public var children: [AXNode]

    public init(role: String = "", subrole: String = "", identifier: String = "", value: String = "",
                description: String = "", children: [AXNode] = []) {
        self.role = role; self.subrole = subrole; self.identifier = identifier
        self.value = value; self.description = description; self.children = children
    }
}

public struct CapturedNotification: Equatable {
    public var app: String
    public var title: String
    public var body: String
}

public enum BannerParser {
    static let bannerSubroles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]
    static let maxTitle = 200
    static let maxBody = 600

    /// Every banner or alert under `roots`, in tree order.
    public static func notifications(in roots: [AXNode]) -> [CapturedNotification] {
        var out: [CapturedNotification] = []
        func walk(_ n: AXNode) {
            if bannerSubroles.contains(n.subrole) {
                // A banner's own subtree is its content, never another banner.
                if let c = parse(banner: n) { out.append(c) }
                return
            }
            n.children.forEach(walk)
        }
        roots.forEach(walk)
        return out
    }

    /// Texts tagged `title` / `subtitle` / `body` when the system tags them;
    /// otherwise the first text is the title and the rest the body.
    public static func parse(banner: AXNode) -> CapturedNotification? {
        var texts: [(id: String, value: String)] = []
        func collect(_ n: AXNode) {
            if n.role == "AXStaticText" {
                let v = n.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { texts.append((n.identifier, v)) }
            }
            n.children.forEach(collect)
        }
        banner.children.forEach(collect)

        func tagged(_ id: String) -> String? { texts.first { $0.id == id }?.value }
        var title: String
        var body: String
        if texts.contains(where: { ["title", "subtitle", "body"].contains($0.id) }) {
            var rest = [tagged("subtitle"), tagged("body")].compactMap { $0 }
            title = tagged("title") ?? (rest.isEmpty ? "" : rest.removeFirst())
            body = rest.joined(separator: " \u{2014} ")
        } else {
            title = texts.first?.value ?? ""
            body = texts.dropFirst().map(\.value).joined(separator: " ")
        }
        guard !title.isEmpty || !body.isEmpty else { return nil }
        if title.isEmpty { title = body; body = "" }

        let name = banner.description.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return CapturedNotification(app: name.isEmpty ? "Notification" : String(name.prefix(60)),
                                    title: String(title.prefix(maxTitle)),
                                    body: String(body.prefix(maxBody)))
    }
}

/// Remembers what was sent so a banner that stays on screen (and keeps
/// producing layout events) is reported once.
public struct NotificationDeduper {
    public static let windowMs = 30_000
    private var seen: [String: Int] = [:]

    public init() {}

    public mutating func isNew(_ n: CapturedNotification, nowMs: Int) -> Bool {
        seen = seen.filter { nowMs - $0.value < Self.windowMs }
        let key = "\(n.app)|\(n.title)|\(n.body)"
        let known = seen[key] != nil
        // Still on screen: keep remembering it.
        seen[key] = nowMs
        return !known
    }

    public var count: Int { seen.count }
}

/// Where banner trees come from. The real one talks to Notification Center;
/// tests substitute their own.
protocol BannerSource: AnyObject {
    /// Calls `onChange` (on the main thread) with the current window trees
    /// whenever Notification Center's content changes.
    func start(onChange: @escaping ([AXNode]) -> Void)
    func stop()
}

/// Runs the capture while the setting is on and permission is granted, and
/// tells the model when permission is missing.
public final class SystemNotificationObserver {
    static let recheckInterval: TimeInterval = 2
    static let maxRechecks = 60 // two minutes

    private weak var model: AppModel?
    private let source: BannerSource
    private let isTrusted: () -> Bool
    private let promptForTrust: () -> Void
    private let nowMs: () -> Int

    private var cancellables: Set<AnyCancellable> = []
    private var wanted = false
    private var running = false
    private var prompted = false
    private var deduper = NotificationDeduper()
    private var timer: DispatchSourceTimer?
    private(set) var rechecksLeft = 0

    public convenience init(model: AppModel) {
        self.init(model: model, source: AXBannerSource(),
                  isTrusted: { AXIsProcessTrusted() },
                  promptForTrust: {
                      let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                      _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                  },
                  nowMs: { Int(Date().timeIntervalSince1970 * 1000) })
    }

    init(model: AppModel, source: BannerSource, isTrusted: @escaping () -> Bool,
         promptForTrust: @escaping () -> Void, nowMs: @escaping () -> Int) {
        self.model = model
        self.source = source
        self.isTrusted = isTrusted
        self.promptForTrust = promptForTrust
        self.nowMs = nowMs
    }

    deinit { stop() }

    /// Starts following the setting. Main thread.
    public func start() {
        guard cancellables.isEmpty, let model else { return }
        model.$view
            .map { $0?.settings.notify.system ?? false }
            .removeDuplicates()
            .sink { [weak self] on in self?.settingChanged(on) }
            .store(in: &cancellables)
        // Permission may have been granted since; opening the panel is a
        // natural moment to look again.
        model.panelOpened
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    public func stop() {
        cancellables.removeAll()
        stopTimer()
        stopSource()
    }

    private func settingChanged(_ on: Bool) {
        wanted = on
        refresh()
        // Waiting for the user to grant permission: look again for a while.
        if on && !running { startTimer() }
    }

    /// Brings capture in line with the setting and the permission.
    func refresh() {
        guard wanted else {
            stopTimer()
            stopSource()
            setNeeded(false)
            return
        }
        if isTrusted() {
            stopTimer()
            setNeeded(false)
            startSource()
        } else {
            stopSource()
            setNeeded(true)
            if !prompted {
                prompted = true
                promptForTrust()
            }
        }
    }

    /// One step of the bounded wait for permission.
    func recheck() {
        guard rechecksLeft > 0 else { stopTimer(); return }
        rechecksLeft -= 1
        refresh()
        if rechecksLeft == 0 { stopTimer() }
    }

    var isWaitingForPermission: Bool { timer != nil }
    var isCapturing: Bool { running }

    private func setNeeded(_ value: Bool) {
        if model?.accessibilityNeeded != value { model?.accessibilityNeeded = value }
    }

    private func startSource() {
        guard !running else { return }
        running = true
        source.start { [weak self] roots in self?.handle(roots) }
    }

    private func stopSource() {
        guard running else { return }
        running = false
        source.stop()
    }

    private func startTimer() {
        stopTimer()
        rechecksLeft = Self.maxRechecks
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.recheckInterval, repeating: Self.recheckInterval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.recheck() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        rechecksLeft = 0
    }

    func handle(_ roots: [AXNode]) {
        guard running else { return }
        let now = nowMs()
        for n in BannerParser.notifications(in: roots) where deduper.isNew(n, nowMs: now) {
            model?.send(.notifySystem(app: n.app, title: n.title, body: n.body))
        }
    }
}

// MARK: - The live accessibility source

/// Observes Notification Center's accessibility tree. All on the main thread.
final class AXBannerSource: BannerSource {
    static let bundleId = "com.apple.notificationcenterui"
    static let maxDepth = 10
    static let maxNodes = 400
    static let debounce: TimeInterval = 0.15

    private var onChange: (([AXNode]) -> Void)?
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var scanWork: DispatchWorkItem?
    private var launchToken: NSObjectProtocol?

    deinit { stop() }

    func start(onChange: @escaping ([AXNode]) -> Void) {
        stop()
        self.onChange = onChange
        // Notification Center restarts now and then (and after a crash).
        launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Self.bundleId { self?.attach() }
        }
        attach()
    }

    func stop() {
        if let launchToken { NSWorkspace.shared.notificationCenter.removeObserver(launchToken) }
        launchToken = nil
        detach()
        onChange = nil
    }

    private func attach() {
        detach()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first
        else { return }
        let pid = app.processIdentifier
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        // A hung Notification Center must not hang the notch.
        AXUIElementSetMessagingTimeout(element, 1.0)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            // Each is optional: not every system version posts all three.
            _ = AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        self.appElement = element
        self.pid = pid
    }

    private func detach() {
        scanWork?.cancel()
        scanWork = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
        pid = 0
    }

    fileprivate func eventArrived() {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func scan() {
        scanWork = nil
        guard let appElement, let onChange else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        var budget = Self.maxNodes
        var roots: [AXNode] = []
        for w in windows {
            guard let n = Self.node(w, depth: 0, budget: &budget) else { break }
            roots.append(n)
        }
        if !roots.isEmpty { onChange(roots) }
    }

    private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute,
                                     kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray

    /// Copies one element and (within the depth and node limits) its subtree.
    /// One round trip per element.
    private static func node(_ element: AXUIElement, depth: Int, budget: inout Int) -> AXNode? {
        guard budget > 0 else { return nil }
        budget -= 1
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(), &raw) == .success,
              let values = raw as? [Any], values.count == 6 else { return AXNode() }
        func text(_ i: Int) -> String { values[i] as? String ?? "" }
        var n = AXNode(role: text(0), subrole: text(1), identifier: text(2), value: text(3), description: text(4))
        if depth < maxDepth, let kids = values[5] as? [AXUIElement] {
            for k in kids {
                guard let c = node(k, depth: depth + 1, budget: &budget) else { break }
                n.children.append(c)
            }
        }
        return n
    }
}

private let axCallback: AXObserverCallback = { _, _, _, context in
    guard let context else { return }
    Unmanaged<AXBannerSource>.fromOpaque(context).takeUnretainedValue().eventArrived()
}
