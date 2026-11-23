import AppKit
import Combine
import Foundation

// The waiting dot says a Claude Code session wants the user. It should go
// once they have gone to that session, however they got there: a click in
// the notch (see `PanelState.openSession` and `openNotification`), or by
// bringing the session's terminal forward themselves, which is noticed here.
// Event-driven: it looks only when an app comes to the front, or when a
// session starts waiting while its terminal already is in front.

public enum AgentAttention {
    /// The session an agent notification is about; nil for other sources.
    public static func session(of n: NotificationItem) -> String? {
        guard n.source == "agent", let group = n.group, group.hasPrefix("agent-") else { return nil }
        let id = String(group.dropFirst("agent-".count))
        return id.isEmpty ? nil : id
    }

    /// Sessions that keep the dot on: waiting for a reply, or with a notice
    /// not read yet.
    public static func waiting(in vm: ViewModel) -> [AgentSession] {
        let unread = Set(vm.inbox.history.filter { !$0.read }.compactMap(session(of:)))
        return vm.agents.sessions.filter { $0.status == .waitingInput || unread.contains($0.id) }
    }

    /// Which of `sessions` (all in the app now in front) the user is looking
    /// at. With the front tab's device known, only the session on it, plus
    /// any whose device is unknown. Without it (another terminal, or no
    /// permission to ask), all of them: the app is in front, and that is
    /// the most that can be told.
    public static func attended(_ sessions: [AgentSession], frontTTY: String?) -> [AgentSession] {
        guard let frontTTY else { return sessions }
        return sessions.filter { $0.tty == nil || $0.tty == frontTTY }
    }
}

/// Clears the dot for sessions whose terminal window the user brings forward.
public final class AgentAttentionObserver {
    private weak var model: AppModel?
    private let frontmost: () -> String?
    private let frontTTY: (String, @escaping (String?) -> Void) -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?

    public convenience init(model: AppModel) {
        self.init(
            model: model,
            frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            frontTTY: TerminalWindow.frontTTY(bundleId:done:))
    }

    init(
        model: AppModel, frontmost: @escaping () -> String?,
        frontTTY: @escaping (String, @escaping (String?) -> Void) -> Void
    ) {
        self.model = model
        self.frontmost = frontmost
        self.frontTTY = frontTTY
    }

    deinit { stop() }

    /// Main thread.
    public func start() {
        guard observer == nil, let model else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.cameForward(app?.bundleIdentifier)
        }
        // A session that starts waiting while the user is already in its
        // terminal: no app comes forward, so look now.
        model.$view
            .map { vm in vm.map { $0.waiting ? AgentAttention.waiting(in: $0).map(\.id) : [] } ?? [] }
            .removeDuplicates()
            .filter { !$0.isEmpty }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.cameForward(self?.frontmost()) }
            .store(in: &cancellables)
    }

    public func stop() {
        cancellables.removeAll()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// An app is in front: mark the waiting sessions the user can now see.
    func cameForward(_ bundleId: String?) {
        guard let bundleId, let model, let vm = model.view, vm.waiting else { return }
        let here = AgentAttention.waiting(in: vm).filter { $0.app == bundleId }
        guard !here.isEmpty else { return }
        let seen: ([AgentSession]) -> Void = { [weak model] sessions in
            sessions.forEach { model?.send(.agentSeen(sessionId: $0.id)) }
        }
        // Ask which tab is in front only where that can narrow it down.
        guard TerminalWindow.frontScript(bundleId: bundleId) != nil, here.contains(where: { $0.tty != nil }) else {
            return seen(here)
        }
        frontTTY(bundleId) { tty in seen(AgentAttention.attended(here, frontTTY: tty)) }
    }
}
