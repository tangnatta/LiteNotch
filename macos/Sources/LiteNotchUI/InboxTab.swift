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
                    Image(systemName: "moon.fill").glyph(NGlyph.small).foregroundStyle(NT.accentText)
                    Text(verbatim: "Focus: less urgent notifications wait until it ends")
                        .nfont(.body).foregroundStyle(NT.text2).lineLimit(1)
                } else {
                    Text(verbatim: vm.inbox.unread > 0 ? "\(vm.inbox.unread) unread" : "All caught up")
                        .nfont(.body).foregroundStyle(NT.text3)
                }
                Spacer(minLength: 4)
                if vm.inbox.unread > 0 {
                    TextPill(title: "Mark all read", height: 24) { send(.notifyMarkRead) }
                }
                ConfirmPill(title: "Clear inbox", question: ConfirmGate.question(count: rows.count),
                            help: "Remove every notification", enabled: !rows.isEmpty) {
                    send(.notifyClear)
                }
            }
            .frame(height: 24)
            systemRow
            if rows.isEmpty {
                EmptyState(symbol: "bell", title: "No notifications",
                           hint: vm.settings.notify.system
                               ? "Notifications from LiteNotch, Claude Code and other apps appear here."
                               : "Notifications from LiteNotch and Claude Code appear here.")
            } else {
                NotchScroll {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, n in
                        row(n, isBanner: n.id == vm.inbox.banner?.id, now: now)
                        if i < rows.count - 1 { Hairline().padding(.horizontal, 6) }
                    }
                    .padding(.horizontal, 6)
                }
                .padding(.horizontal, -6)
            }
        }
    }

    /// Offers other apps' notifications, or says what is still missing.
    @ViewBuilder private var systemRow: some View {
        if !vm.settings.notify.system {
            notice(symbol: "app.badge", text: "Also show notifications from other apps", action: "Turn on",
                   help: "LiteNotch reads other apps\u{2019} banners through Accessibility") {
                var s = vm.settings
                s.notify.system = true
                send(.setSettings(s))
            }
        } else if model.accessibilityNeeded {
            notice(symbol: "exclamationmark.triangle.fill",
                   text: "Allow LiteNotch to read other apps\u{2019} notifications in System Settings",
                   action: "Open Settings", warning: true,
                   help: "Opens Privacy & Security \u{203A} Accessibility") { model.app?.onOpenAccessibilitySettings() }
            notice(symbol: "arrow.clockwise",
                   text: "Already allowed it?",
                   action: "Reset and ask again", primary: false,
                   help: "macOS forgets the permission when LiteNotch is updated") { model.app?.onResetAccessibility() }
        }
    }

    /// One line with one button. Only the `primary` one is filled with the
    /// accent, so a screen has one call to action.
    private func notice(symbol: String, text: String, action: String, primary: Bool = true,
                        warning: Bool = false, help: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).glyph(11)
                .foregroundStyle(warning ? NT.warning : (primary ? NT.accentText : NT.text3))
                .frame(width: 16)
            Text(verbatim: text).nfont(.body).foregroundStyle(warning ? NT.warning : NT.text2)
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if primary {
                TextPill(title: action, tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold,
                         action: run)
                    .help(help)
            } else {
                TextPill(title: action, tint: NT.text1, height: 22, action: run)
                    .help(help)
            }
        }
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: 32)
        .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
    }

    private func row(_ n: NotificationItem, isBanner: Bool, now: Int) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(n.read ? Color.clear : NT.accent).frame(width: 7, height: 7).padding(.top, 5)
                .accessibilityLabel(Text(verbatim: n.read ? "Read" : "Unread"))
            Button { model.openNotification(n, isBanner: isBanner) } label: { content(n, now: now) }
                .buttonStyle(.plain)
                .help(Format.openHelp(n.open))
            IconButton(symbol: "xmark", label: "Dismiss", size: NGlyph.small, tint: NT.text3) {
                send(isBanner ? .notifyDismissBanner : .notifyDismiss(id: n.id))
            }
            .padding(.top, -6)
        }
        .padding(.vertical, 7)
        .rowHover()
    }

    /// Title and time on the first line, the message below, the source
    /// as a quiet tag after the title.
    private func content(_ n: NotificationItem, now: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VText(n.title).nfont(.emphasis).foregroundStyle(NT.text1).lineLimit(1)
                    .layoutPriority(1)
                if let tag = Format.sourceTag(n.source) {
                    VText(tag).nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(verbatim: Format.relative(from: n.createdMs, nowMs: now))
                    .nfont(.caption).foregroundStyle(NT.text3).lineLimit(1).fixedSize()
                if n.open != nil {
                    Image(systemName: "arrow.up.forward").glyph(9)
                        .foregroundStyle(NT.text3)
                        .accessibilityHidden(true)
                }
            }
            if !n.body.isEmpty {
                VText(n.body).nfont(.body).foregroundStyle(NT.text2).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
