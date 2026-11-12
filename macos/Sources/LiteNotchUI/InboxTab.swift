import SwiftUI

struct InboxTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState
    @Environment(\.clockOffsetMs) private var offset

    private var send: (ShellCommand) -> Void { model.send }

    private var rows: [NotificationItem] {
        var r = vm.inbox.history
        if let b = vm.inbox.banner { r.removeAll { $0.id == b.id }; r.insert(b, at: 0) }
        return r
    }

    var body: some View {
        let now = nowMs(Date(), offset: offset)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if vm.inbox.dnd {
                    Image(systemName: "moon.fill").font(.system(size: 10.5)).foregroundStyle(NT.accentText)
                    Text(verbatim: "Focus mode: holding low-priority notifications")
                        .nfont(11.5).foregroundStyle(NT.text2).lineLimit(1)
                } else {
                    Text(verbatim: vm.inbox.unread > 0 ? "\(vm.inbox.unread) unread" : "All caught up")
                        .nfont(11.5).foregroundStyle(NT.text3)
                }
                Spacer(minLength: 4)
                TextPill(title: "Mark all read", tint: vm.inbox.unread > 0 ? NT.text1 : NT.text3, height: 24) {
                    send(.notifyMarkRead)
                }
                TextPill(title: "Clear", height: 24) { send(.notifyClear) }
            }
            .frame(height: 24)
            systemRow
            if rows.isEmpty {
                EmptyState(symbol: "bell", title: "No notifications")
            } else {
                NotchScroll {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, n in
                        row(n, isBanner: n.id == vm.inbox.banner?.id, now: now)
                        if i < rows.count - 1 { Divider().overlay(NT.hairline) }
                    }
                }
            }
        }
    }

    /// Offers other apps' notifications, or says what is still missing.
    @ViewBuilder private var systemRow: some View {
        if !vm.settings.notify.system {
            notice(symbol: "app.badge", text: "Show notifications from other apps", action: "Enable") {
                var s = vm.settings
                s.notify.system = true
                send(.setSettings(s))
            }
        } else if model.accessibilityNeeded {
            notice(symbol: "lock",
                   text: "Allow LiteNotch in System Settings \u{203A} Privacy & Security \u{203A} Accessibility",
                   action: "Open Settings") { model.app?.onOpenAccessibilitySettings() }
        }
    }

    private func notice(symbol: String, text: String, action: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(NT.accentText)
                .frame(width: 16)
            Text(verbatim: text).nfont(11.5).foregroundStyle(NT.text2)
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            TextPill(title: action, tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold, action: run)
        }
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: 32)
        .background(NT.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ n: NotificationItem, isBanner: Bool, now: Int) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(n.read ? Color.clear : NT.accent).frame(width: 7, height: 7).padding(.top, 5)
                .accessibilityLabel(Text(verbatim: n.read ? "Read" : "Unread"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    VText(n.source.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(NT.text3).lineLimit(1)
                    Text(verbatim: Format.relative(from: n.createdMs, nowMs: now))
                        .nfont(10.5).foregroundStyle(NT.text3)
                }
                VText(n.title).nfont(12.5, .semibold).foregroundStyle(NT.text1).lineLimit(1)
                if !n.body.isEmpty {
                    VText(n.body).nfont(11.5).foregroundStyle(NT.text2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "xmark", label: "Dismiss", size: 10, tint: NT.text3, frame: 24) {
                send(isBanner ? .notifyDismissBanner : .notifyDismiss(id: n.id))
            }
        }
        .padding(.vertical, 7)
    }
}
