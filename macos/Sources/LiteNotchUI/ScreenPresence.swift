import AppKit

/// Whether anyone can see the screen: not while it is locked, the displays
/// sleep, the Mac sleeps or another user's session is in front. Eye breaks
/// are skipped then (`Command::ScreenAway`).
public struct ScreenPresence: Equatable {
    public enum Reason: CaseIterable { case locked, displaysAsleep, systemAsleep, sessionInactive }

    private var reasons: Set<Reason> = []

    public init() {}

    public var away: Bool { !reasons.isEmpty }

    /// Records one reason starting or ending; returns the new `away` when it
    /// changed.
    public mutating func set(_ reason: Reason, _ on: Bool) -> Bool? {
        let before = away
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        return away == before ? nil : away
    }
}

/// Feeds `ScreenPresence` from the system's own notifications. Nothing is
/// polled: each observer runs only when the state changes.
public final class ScreenPresenceObserver {
    private weak var model: AppModel?
    private var presence = ScreenPresence()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(model: AppModel) {
        self.model = model
    }

    public func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let watch: [(NotificationCenter, Notification.Name, ScreenPresence.Reason, Bool)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
            (workspace, NSWorkspace.screensDidSleepNotification, .displaysAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .displaysAsleep, false),
            (workspace, NSWorkspace.willSleepNotification, .systemAsleep, true),
            (workspace, NSWorkspace.didWakeNotification, .systemAsleep, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        for (center, name, reason, on) in watch {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update(reason, on)
            }
            tokens.append((center, token))
        }
    }

    public func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func update(_ reason: ScreenPresence.Reason, _ on: Bool) {
        if let away = presence.set(reason, on) {
            model?.send(.screenAway(away))
        }
    }
}
