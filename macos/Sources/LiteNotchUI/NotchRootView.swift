import AppKit
import SwiftUI

extension NotchPresentation {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)

    /// Open and close: the spring, or no animation at all when Reduce
    /// Motion is on (the shape would still move under a short fade).
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : spring
    }
}

/// The SwiftUI root hosted by one panel. The window never resizes; the
/// shape grows inside it. Closed and as a toast, the shape is black with dark
/// content by default so it blends with the hardware notch, or follows the
/// theme when "Closed notch: Match theme" is set; open it follows the chosen
/// theme, and the fill fades with the spring.
public struct NotchRootView: View {
    @ObservedObject var model: PanelState
    /// The window's scheme, which follows the system setting live.
    @Environment(\.colorScheme) private var systemScheme
    /// With Reduce Motion on, the shape changes size without the spring.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: PanelState) {
        self.model = model
    }

    public var body: some View {
        let mode = model.mode
        let size = model.targetSize
        let appearance = model.view?.settings.appearance ?? .default
        let scheme = appearance.theme.scheme(system: systemScheme)
        let closedScheme = appearance.closedScheme(system: systemScheme, hardwareNotch: model.hasHardwareNotch)
        let ear = mode == .expanded ? NotchGeometry.expandedEar : NotchGeometry.closedEar
        let bottom: CGFloat = {
            switch mode {
            case .closed: return NotchGeometry.closedBottomRadius
            case .toast: return NotchGeometry.toastBottomRadius
            case .expanded: return NotchGeometry.expandedBottomRadius
            }
        }()
        let shape = NotchShape(topRadius: ear, bottomRadius: bottom)

        ZStack(alignment: .top) {
            // Closed and as a toast the shape is black by default, so it reads
            // as part of the hardware notch; the open panel follows the theme.
            // `NT.panel` is black in the dark scheme, so "Match theme" with a
            // dark theme draws exactly what the default does.
            shape.fill(mode == .expanded || appearance.closedFollowsTheme(hardwareNotch: model.hasHardwareNotch) ? NT.panel : Color.black)
            switch mode {
            case .closed:
                if let c = model.view?.compact, c.kind != .idle, c.kind != .unknown {
                    ClosedActivityView(compact: c, notchWidth: model.notch.width, ear: ear,
                                       artworkPath: model.view?.media?.artworkPath)
                        .environment(\.colorScheme, closedScheme)
                        .transition(.opacity)
                }
            case .toast:
                if let b = model.view?.inbox.banner {
                    ToastView(banner: b, notch: model.notch, ear: ear,
                              open: { model.openNotification(b, isBanner: true) },
                              dismiss: { model.send(.notifyDismissBanner) })
                        .environment(\.colorScheme, closedScheme)
                        .transition(.opacity)
                }
            case .expanded:
                ExpandedView(model: model, ear: ear)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .environment(\.colorScheme, scheme)
        // A new accent restyles everything: views whose inputs did not
        // change would otherwise keep the colour they last drew with.
        .id(NT.accentHex)
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { model.hoverChanged($0) }
        // Clicking the closed notch (or a toast) opens it at once, with or
        // without "hover to expand". Buttons inside take their own clicks,
        // and the open panel's top strip has its own gesture that closes it.
        .onTapGesture { if !model.expanded { model.open() } }
        .animation(NotchPresentation.animation(reduceMotion: reduceMotion), value: size)
        .animation(NotchPresentation.animation(reduceMotion: reduceMotion), value: mode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Closed with an activity

struct ClosedActivityView: View {
    let compact: CompactView
    let notchWidth: CGFloat
    let ear: CGFloat
    var artworkPath: String?

    var body: some View {
        let wing = NotchGeometry.wingWidth(for: compact)
        HStack(spacing: 0) {
            leftIcon
                .padding(.leading, 12)
                .frame(width: wing, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            rightValue
                .padding(.trailing, 12)
                .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, ear)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(compact.title) \(compact.value)"))
    }

    @ViewBuilder private var leftIcon: some View {
        switch compact.kind {
        case .pomodoro:
            Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(NT.accentText)
        case .media:
            ArtworkView(path: artworkPath, size: 20, radius: 5)
        case .caffeine:
            Image(systemName: "cup.and.heat.waves.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.text1)
        case .agent:
            Image(systemName: "terminal.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
        case .timer:
            Image(systemName: "hourglass").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
        case .meeting:
            Image(systemName: "person.2.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(NT.accentText)
        case .approval:
            Circle().fill(NT.accentText).frame(width: 9, height: 9)
        case .banner:
            Image(systemName: "bell.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
        case .idle, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder private var rightValue: some View {
        switch compact.kind {
        case .pomodoro:
            if let end = compact.endsAtMs {
                EverySecond { now in
                    VText(Format.countdown(seconds: Format.secondsLeft(until: end, nowMs: now)))
                        .wingText(mono: true)
                }
            } else {
                VText(compact.value).wingText(mono: true)
            }
        case .media:
            MediaBars(active: true)
        case .caffeine:
            if let end = compact.endsAtMs {
                EverySecond { now in
                    VText(Format.countdown(seconds: Format.secondsLeft(until: end, nowMs: now)))
                        .wingText(mono: true)
                }
            } else {
                VText(compact.value).wingText(mono: false)
            }
        case .agent:
            VText(compact.title).wingText(mono: false)
        case .timer:
            if let end = compact.endsAtMs {
                EverySecond { now in
                    VText(Format.countdown(seconds: Format.secondsLeft(until: end, nowMs: now)))
                        .wingText(mono: true)
                }
            } else {
                VText(compact.value).wingText(mono: true)
            }
        case .meeting:
            if let end = compact.endsAtMs {
                EverySecond { now in
                    let left = Format.signedSecondsLeft(until: end, nowMs: now)
                    VText(Format.signedCountdown(left)).wingText(mono: true, tint: left < 0 ? NT.deny : NT.text1)
                }
            } else {
                VText(compact.value).wingText(mono: false)
            }
        case .approval:
            HStack(spacing: 5) {
                VText(compact.value).wingText(mono: false)
                if compact.count > 1 {
                    Text(verbatim: "\(compact.count)")
                        .font(NType.badge.font)
                        .foregroundStyle(NT.onAccent)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(NT.accent, in: Capsule())
                }
            }
        case .banner:
            VText(compact.title).wingText(mono: false)
        case .idle, .unknown:
            EmptyView()
        }
    }
}

private extension Text {
    func wingText(mono: Bool, tint: Color = NT.text1) -> some View {
        self.font(NType.emphasis.font)
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Four equaliser bars. The motion is a repeating Core Animation, which the
/// window server runs: a SwiftUI animation here re-rendered the notch on
/// every frame and cost about 9 % CPU for as long as music played.
struct MediaBars: View {
    var active: Bool
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme
    static let base: [CGFloat] = [6, 11, 8, 12]

    var body: some View {
        // `accentText`: the accent, darkened on a light surface until it
        // reads (a pale accent on white would all but vanish).
        if active && !snapshot {
            AnimatedBars(color: NSColor(NT.accentText).resolved(dark: scheme == .dark))
                .frame(width: 16, height: 14)
        } else {
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(NT.accentText).frame(width: 2.5, height: Self.base[i])
                }
            }
            .frame(height: 14)
        }
    }
}

private struct AnimatedBars: NSViewRepresentable {
    /// Already resolved for the scheme: a layer's `CGColor` does not follow
    /// SwiftUI's environment.
    let color: CGColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 14))
        view.wantsLayer = true
        // With Reduce Motion on, the bars stay still at their resting heights.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let durations: [CFTimeInterval] = [0.42, 0.34, 0.50, 0.38]
        for i in 0..<4 {
            let bar = CALayer()
            bar.backgroundColor = color
            bar.cornerRadius = 1.25
            bar.bounds = CGRect(x: 0, y: 0, width: 2.5, height: MediaBars.base[i])
            bar.position = CGPoint(x: 1.25 + CGFloat(i) * 4.5, y: 7)
            view.layer?.addSublayer(bar)
            if still { continue }
            let pulse = CABasicAnimation(keyPath: "bounds.size.height")
            pulse.fromValue = 4
            pulse.toValue = 13
            pulse.duration = durations[i]
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            bar.add(pulse, forKey: "pulse")
        }
        return view
    }

    /// Only the colour changes (a theme switch); the running animations
    /// are left alone.
    func updateNSView(_ nsView: NSView, context: Context) {
        for bar in nsView.layer?.sublayers ?? [] where bar.backgroundColor != color {
            bar.backgroundColor = color
        }
    }
}

extension NSColor {
    /// This (dynamic) colour as it draws in the dark or the light appearance.
    func resolved(dark: Bool) -> CGColor {
        var out = cgColor
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance { out = self.cgColor }
        return out
    }
}

// MARK: - Toast

struct ToastView: View {
    let banner: NotificationItem
    let notch: CGSize
    let ear: CGFloat
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .glyph(NGlyph.regular)
                    .foregroundStyle(NT.accentText)
                    .frame(width: 18)
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 1) {
                        VText(banner.title).nfont(.emphasis).foregroundStyle(NT.text1).lineLimit(1)
                        VText(banner.body).nfont(.body).foregroundStyle(NT.text2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open")
                if let tag = Format.sourceTag(banner.source) {
                    VText(tag).nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
                }
                IconButton(symbol: "xmark", label: "Dismiss", size: NGlyph.small, action: dismiss)
            }
            .padding(.horizontal, ear + 14)
            .frame(height: NotchGeometry.toastExtraHeight - 6)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: PanelState
    let ear: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownApproval: String?

    var body: some View {
        let vm = model.view
        let pending = vm?.agents.pending ?? []
        VStack(spacing: 0) {
            if !pending.isEmpty {
                // The one being looked at; the first when it was answered or
                // none was picked.
                let i = pending.firstIndex { $0.id == shownApproval } ?? 0
                let request = pending[i]
                ApprovalHeader(index: i + 1, total: pending.count, notch: model.notch, ear: ear) { d in
                    let j = min(max(i + d, 0), pending.count - 1)
                    shownApproval = pending[j].id
                }
                .frame(height: model.notch.height)
                // A new id re-arms Allow (see ApprovalView.armDelay).
                ApprovalView(request: request, send: model.send)
                    .id(request.id)
                    .padding(.horizontal, ear + 14)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
            } else {
                TabBar(model: model, ear: ear)
                    .frame(height: model.notch.height)
                if let vm {
                    Group {
                        switch model.tab {
                        case .home: HomeTab(vm: vm, model: model)
                        case .music: MusicTab(vm: vm, model: model)
                        case .timer: TimerTab(vm: vm, model: model)
                        case .clipboard: ClipboardTab(vm: vm, model: model)
                        case .agents: AgentsTab(vm: vm, model: model)
                        case .inbox: InboxTab(vm: vm, model: model)
                        case .settings: SettingsTab(vm: vm, model: model)
                        }
                    }
                    .id(model.tab)
                    .transition(.opacity)
                    .padding(.horizontal, ear + 14)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                } else {
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.tab)
    }
}

extension Tab {
    var symbol: String {
        switch self {
        case .home: return "house"
        case .music: return "music.note"
        case .timer: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .agents: return "terminal"
        case .inbox: return "bell"
        case .settings: return "gearshape"
        }
    }

    /// Tooltip: the name and what the tab holds.
    var help: String {
        switch self {
        case .home: return "Home"
        case .music: return "Music: what\u{2019}s playing"
        case .timer: return "Timer: focus sessions, meetings and a countdown"
        case .clipboard: return "Clipboard history"
        case .agents: return "Agents: Claude Code sessions and usage"
        case .inbox: return "Inbox: notifications"
        case .settings: return "Settings"
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .music: return "Music"
        case .timer: return "Timer"
        case .clipboard: return "Clipboard"
        case .agents: return "Agents"
        case .inbox: return "Inbox"
        case .settings: return "Settings"
        }
    }
}

/// Icon-only tabs on both sides of the physical notch. Left: the pages.
/// Right: the keep-awake switch, inbox and settings.
struct TabBar: View {
    @ObservedObject var model: PanelState
    let ear: CGFloat

    static let left: [Tab] = [.home, .music, .timer, .clipboard, .agents]
    static let right: [Tab] = [.inbox, .settings]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.left, id: \.self) { tabButton($0) }
            Spacer(minLength: model.notch.width + 24)
            pickerButton
            keepAwakeButton
            ForEach(Self.right, id: \.self) { tabButton($0) }
        }
        .padding(.horizontal, ear + 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The strip itself (not its buttons) closes the panel on a click,
        // the counterpart of clicking the closed notch to open it.
        .contentShape(Rectangle())
        .onTapGesture { model.stripClicked() }
    }

    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .inbox: return model.view?.inbox.unread ?? 0
        case .agents: return model.view?.agents.pending.count ?? 0
        default: return 0
        }
    }

    /// Closes the panel and samples a colour from the screen.
    private var pickerButton: some View {
        Button { model.pickColor() } label: {
            Image(systemName: "eyedropper")
                .glyph(13)
                .foregroundStyle(NT.text3)
                .frame(width: 30, height: 24)
                .contentShape(Capsule())
                .controlHover(Capsule())
        }
        .buttonStyle(.plain)
        .help("Pick a colour from the screen and copy it")
        .accessibilityLabel(Text(verbatim: "Pick a colour from the screen"))
    }

    /// Filled and in the accent while on; the tooltip says for how long.
    @ViewBuilder private var keepAwakeButton: some View {
        let c = model.view?.caffeine
        let on = c.map { $0.mode != .off && $0.mode != .unknown } ?? false
        if on, let until = c?.untilMs {
            // Minutes are enough for a tooltip, so this redraws twice a minute.
            EverySecond(interval: 30) { now in
                keepAwakeButton(on: true, help: KeepAwakeText.help(on: true, untilMs: until, nowMs: now))
            }
        } else {
            keepAwakeButton(on: on, help: KeepAwakeText.help(on: on, untilMs: nil, nowMs: 0))
        }
    }

    private func keepAwakeButton(on: Bool, help: String) -> some View {
        Button { model.send(.caffeineToggle) } label: {
            Image(systemName: on ? "cup.and.heat.waves.fill" : "cup.and.heat.waves")
                .glyph(13)
                .foregroundStyle(on ? NT.accentText : NT.text3)
                .frame(width: 30, height: 24)
                .background(on ? NT.fillHi : Color.clear, in: Capsule())
                .contentShape(Capsule())
                .controlHover(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: "Keep the Mac awake"))
        .accessibilityValue(Text(verbatim: on ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }

    private func tabButton(_ t: Tab) -> some View {
        let selected = model.tab == t
        let count = badge(for: t)
        return Button { model.selectTab(t) } label: {
            Image(systemName: t.symbol).glyph(13)
                .foregroundStyle(selected ? NT.text1 : NT.text3)
                .frame(width: 30, height: 24)
                .background(selected ? NT.fillHi : Color.clear, in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(verbatim: count > 9 ? "9+" : "\(count)")
                            .font(NType.badge.font)
                            .foregroundStyle(NT.onAccent)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(NT.accent, in: Capsule())
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Capsule())
                .controlHover(Capsule())
        }
        .buttonStyle(.plain)
        .help(t.help)
        .accessibilityLabel(Text(verbatim: count > 0 ? "\(t.title), \(count)" : t.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
