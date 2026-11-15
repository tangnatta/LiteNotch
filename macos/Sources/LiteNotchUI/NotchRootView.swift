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
/// theme (solid or Liquid Glass, see `GlassSupport`), and the fill fades
/// with the spring.
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
        let layout = model.layout
        let top = layout.top(for: mode)
        let closedScheme = appearance.closedScheme(system: systemScheme, hardwareNotch: model.hasNotch)
        let ear = mode == .expanded ? NotchGeometry.expandedEar : NotchGeometry.closedEar
        let bottom: CGFloat = {
            switch mode {
            case .closed: return layout.floating ? layout.capsuleHeight / 2 : NotchGeometry.closedBottomRadius
            case .toast: return NotchGeometry.toastBottomRadius
            case .expanded: return NotchGeometry.expandedBottomRadius
            }
        }()
        // Attached: the notch silhouette with concave ears. Floating: all
        // four corners rounded, `top` below the top of the screen.
        // Shrunk: a thin strip flush with the top edge, in either style.
        let shape = layout.minimized && !layout.hasNotch
            ? NotchShape(topRadius: NotchGeometry.minimizedEar, bottomRadius: NotchGeometry.minimizedBottomRadius)
            : layout.floating
            ? NotchShape(topRadius: 0, bottomRadius: bottom, topCorner: bottom, topInset: top)
            : NotchShape(topRadius: ear, bottomRadius: bottom)

        ZStack(alignment: .top) {
            // Closed and as a toast the shape is black by default, so it reads
            // as part of the hardware notch; the open panel follows the theme.
            // `NT.panel` is black in the dark scheme, so "Match theme" with a
            // dark theme draws exactly what the default does.
            // With Liquid Glass chosen (and drawable) the open panel is glass and
            // the closed fill fades out under it. Not while an approval waits:
            // its text is contrast-tested against the solid colour only.
            if appearance.drawsGlass(approvalPending: !(model.view?.agents.pending.isEmpty ?? true)) {
                shape.fill(appearance.closedFollowsTheme(hardwareNotch: model.hasNotch) ? NT.panel : Color.black)
                    .opacity(mode == .expanded ? 0 : 1)
                if mode == .expanded {
                    PanelFill(shape: shape, glass: true).transition(.opacity)
                }
            } else {
                shape.fill(mode == .expanded || appearance.closedFollowsTheme(hardwareNotch: model.hasNotch) ? NT.panel : Color.black)
            }
            switch mode {
            case .closed:
                let content = ClosedContent(view: model.view)
                if !content.isEmpty && !layout.minimized {
                    Group {
                        if layout.floating {
                            ClosedActivityView(content: content, notchWidth: layout.centerWidth, ear: 0,
                                               wing: layout.wingWidth(for: content),
                                               edgePadding: NotchGeometry.floatingWingPadding,
                                               artworkSize: min(20, layout.capsuleHeight - 4),
                                               artworkInset: (layout.capsuleHeight - min(20, layout.capsuleHeight - 4)) / 2,
                                               artworkPath: model.view?.media?.artworkPath,
                                               oneRow: layout.oneRow)
                                .frame(height: layout.capsuleHeight)
                                .padding(.top, top)
                        } else {
                            ClosedActivityView(content: content, notchWidth: model.notch.width, ear: ear,
                                               wing: layout.wingWidth(for: content),
                                               artworkPath: model.view?.media?.artworkPath,
                                               oneRow: layout.oneRow)
                        }
                    }
                        .environment(\.colorScheme, closedScheme)
                        .transition(.opacity)
                }
            case .toast:
                if let b = model.view?.inbox.banner {
                    ToastView(banner: b, top: layout.floating ? top : model.notch.height,
                              rowHeight: NotchGeometry.toastExtraHeight - (layout.floating ? 0 : 6), ear: ear,
                              open: { model.openNotification(b, isBanner: true) },
                              dismiss: { model.send(.notifyDismissBanner) },
                              act: { model.banner(b, perform: $0) })
                        .environment(\.colorScheme, closedScheme)
                        .transition(.opacity)
                }
            case .expanded:
                ExpandedView(model: model, ear: ear)
                    .environment(\.requestKeyboard, { [weak model] on in model?.requestKeyboard(on) })
                    .padding(.top, top)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .environment(\.colorScheme, scheme)
        // A new accent restyles everything: views whose inputs did not
        // change would otherwise keep the colour they last drew with.
        .id(NT.accentHex)
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(PointerShape(shape: shape, top: top, column: layout.centerWidth))
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
    let content: ClosedContent
    let notchWidth: CGFloat
    let ear: CGFloat
    let wing: CGFloat
    /// Space between the content and the outer end of each wing.
    var edgePadding: CGFloat = 12
    var artworkSize: CGFloat = 20
    /// Floating only: the artwork is round and sits this far from the
    /// capsule's top, bottom and end, so it nests inside the round end.
    var artworkInset: CGFloat?
    var artworkPath: String?
    /// No notch: one row with no gap in the middle (`NotchLayout.oneRow`).
    var oneRow = false

    private var paired: Bool { content.secondary != nil }

    var body: some View {
        Group {
            if oneRow, content.primary != nil {
                row
            } else {
                HStack(spacing: 0) {
                    left.frame(width: wing, alignment: .leading)
                    Color.clear.frame(width: notchWidth)
                    right.frame(width: wing, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, ear)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spoken(content)))
    }

    /// The pomodoro's icon: a timer while focusing, a leaf during a break,
    /// so the two can be told apart at a glance. `title` is the core's
    /// phase label (`Focus`, `Break`, `Long break`).
    static func pomodoroSymbol(title: String) -> String {
        title.localizedCaseInsensitiveContains("break") ? "leaf.fill" : "timer"
    }

    /// What VoiceOver says for the closed notch.
    static func spoken(_ content: ClosedContent) -> String {
        var parts = [content.primary, content.secondary].compactMap { $0 }
            .map { "\($0.title) \($0.value)".trimmingCharacters(in: .whitespaces) }
        if content.waiting { parts.append("An agent is waiting for you") }
        return parts.joined(separator: ". ")
    }

    /// One row: one activity as its icon, then its value filling the rest;
    /// two side by side, the second dimmed. Then the dot.
    @ViewBuilder var row: some View {
        if let c = content.primary {
            HStack(spacing: 0) {
                if let s = content.secondary {
                    HStack(spacing: NotchGeometry.pairGap) {
                        icon(c)
                        value(c)
                    }
                    Spacer(minLength: NotchGeometry.rowPairSpace)
                    HStack(spacing: NotchGeometry.pairGap) {
                        icon(s)
                        value(s)
                    }
                    .opacity(0.7)
                } else {
                    HStack(spacing: NotchGeometry.rowGap) {
                        icon(c).frame(minWidth: NotchGeometry.rowIcon, alignment: .leading)
                        value(c).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if content.waiting {
                    Circle().fill(NT.accentText)
                        .frame(width: NotchGeometry.waitingDot, height: NotchGeometry.waitingDot)
                        .padding(.leading, NotchGeometry.waitingDotSpace - NotchGeometry.waitingDot)
                }
            }
            .padding(.leading, c.kind == .media ? artworkInset ?? edgePadding : edgePadding)
            .padding(.trailing, edgePadding)
        }
    }

    /// One activity: its icon. Two: the first one's icon and value.
    @ViewBuilder var left: some View {
        if let c = content.primary {
            HStack(spacing: NotchGeometry.pairGap) {
                icon(c)
                if paired { value(c) }
            }
            .padding(.leading, c.kind == .media ? artworkInset ?? edgePadding : edgePadding)
        }
    }

    /// One activity: its value. Two: the second one, dimmed. Then the dot.
    @ViewBuilder var right: some View {
        HStack(spacing: NotchGeometry.pairGap) {
            if let s = content.secondary {
                HStack(spacing: NotchGeometry.pairGap) {
                    icon(s)
                    value(s)
                }
                .opacity(0.7)
            } else if let c = content.primary {
                value(c)
            }
            if content.waiting {
                Circle().fill(NT.accentText)
                    .frame(width: NotchGeometry.waitingDot, height: NotchGeometry.waitingDot)
            }
        }
        .padding(.trailing, edgePadding)
    }

    @ViewBuilder private func icon(_ compact: CompactView) -> some View {
        switch compact.kind {
        case .pomodoro:
            Image(systemName: Self.pomodoroSymbol(title: compact.title))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(NT.accentText)
        case .media:
            ArtworkView(path: artworkPath, size: artworkSize, radius: artworkInset == nil ? artworkSize / 4 : artworkSize / 2)
        case .caffeine:
            Image(systemName: "cup.and.heat.waves.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.text1)
        case .agent:
            Image(systemName: "terminal.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
        case .timer:
            Image(systemName: "hourglass").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
        case .meeting:
            Image(systemName: "person.2.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(NT.accentText)
        case .calendar:
            Image(systemName: "calendar").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
        case .approval:
            Circle().fill(NT.accentText).frame(width: 9, height: 9)
        case .banner:
            Image(systemName: "bell.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
        case .nudge:
            if compact.peek == .eyeBreak {
                BlinkingFace()
            } else {
                Image(systemName: Self.nudgeSymbol(compact))
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NT.accentText)
            }
        case .idle, .unknown:
            EmptyView()
        }
    }

    /// A peek's own text, otherwise the activity's.
    @ViewBuilder private func value(_ compact: CompactView) -> some View {
        switch compact.peek {
        case .trackChanged where compact.kind == .media:
            MarqueeText(text: compact.value.isEmpty ? compact.title : "\(compact.title) — \(compact.value)")
        case .move, .quote:
            MarqueeText(text: compact.value)
        case .timeWarning where compact.endsAtMs != nil:
            EverySecond { now in
                let left = Format.countdown(seconds: Format.secondsLeft(until: compact.endsAtMs ?? 0, nowMs: now))
                VText(left + " left").wingText(mono: true, tint: NT.accentText)
            }
        default:
            activityValue(compact)
        }
    }

    /// The Move reminder's kind is its title; a quote gets sparkles.
    static func nudgeSymbol(_ compact: CompactView) -> String {
        guard compact.peek == .move else { return "sparkles" }
        switch compact.title {
        case "Stretch": return "figure.flexibility"
        case "Water": return "drop.fill"
        default: return "figure.walk"
        }
    }

    /// The text (or bars) for an activity. Sharing the notch, anything
    /// that is not a time is left to the icon.
    @ViewBuilder private func activityValue(_ compact: CompactView) -> some View {
        switch compact.kind {
        case .pomodoro, .timer, .calendar:
            countdown(compact, mono: true)
        case .media:
            MediaBars(active: true)
        case .caffeine:
            if compact.endsAtMs != nil {
                countdown(compact, mono: true)
            } else if !paired {
                VText(compact.value).wingText(mono: false)
            }
        case .agent:
            if !paired {
                VText(compact.title).wingText(mono: false)
            } else if compact.count > 1 {
                Text(verbatim: "\(compact.count)").wingText(mono: true)
            }
        case .meeting:
            if let end = compact.endsAtMs {
                EverySecond { now in
                    let left = Format.signedSecondsLeft(until: end, nowMs: now)
                    VText(Format.signedCountdown(left)).wingText(mono: true, tint: left < 0 ? NT.deny : NT.text1)
                }
            } else if paired {
                Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(NT.text1)
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
        case .nudge:
            VText(compact.value).wingText(mono: false)
        case .idle, .unknown:
            EmptyView()
        }
    }

    /// The time left, counted down here once a second; the stored value
    /// (a paused timer's) when there is no end time.
    @ViewBuilder private func countdown(_ compact: CompactView, mono: Bool) -> some View {
        if let end = compact.endsAtMs {
            EverySecond { now in
                VText(Format.countdown(seconds: Format.secondsLeft(until: end, nowMs: now)))
                    .wingText(mono: mono)
            }
        } else {
            VText(compact.value).wingText(mono: mono)
        }
    }
}

/// One line of text that scrolls when it does not fit. Like the equaliser
/// bars it is a Core Animation layer animation, run by the window server, so
/// SwiftUI does not redraw the notch on every frame. It is only on screen
/// for the few seconds of a peek.
struct MarqueeText: View {
    let text: String
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if snapshot || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            VText(text).wingText(mono: false)
        } else {
            MarqueeLayer(text: text, color: NSColor(NT.text1).resolved(dark: scheme == .dark))
                .frame(height: 16)
        }
    }
}

private struct MarqueeLayer: NSViewRepresentable {
    let text: String
    let color: CGColor

    func makeNSView(context: Context) -> MarqueeNSView {
        let view = MarqueeNSView(frame: .zero)
        view.configure(text: text, color: color)
        return view
    }

    func updateNSView(_ nsView: MarqueeNSView, context: Context) {
        nsView.configure(text: text, color: color)
    }
}

final class MarqueeNSView: NSView {
    private var text = ""
    private var color: CGColor = .white
    private var textWidth: CGFloat = 0
    /// What the layers were last built for. While the wing springs open the
    /// size changes on nearly every frame; only a change in whether the text
    /// scrolls (or in height) rebuilds, so the scroll does not restart.
    private var builtFor: (scrolls: Bool, height: CGFloat)?
    private let strip = CALayer()
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Points per second, and the pause before it starts moving.
    static let speed: CGFloat = 40
    static let delay: CFTimeInterval = 0.5
    static let gap: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks go through to the notch, which opens on a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, color: CGColor) {
        guard text != self.text || color != self.color else { return }
        self.text = text
        self.color = color
        textWidth = ceil(NSAttributedString(string: text, attributes: [.font: Self.font]).size().width)
        builtFor = nil
        needsLayout = true
    }

    /// Moved to a display with another scale: redraw the text sharp.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        builtFor = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let scrolls = textWidth > bounds.width
        if let built = builtFor, built.scrolls == scrolls, built.height == bounds.height {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.mask?.frame = bounds
            CATransaction.commit()
            return
        }
        builtFor = (scrolls, bounds.height)
        rebuild()
    }

    private func rebuild() {
        let str = NSAttributedString(string: text, attributes: [
            .font: Self.font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ])
        let size = str.size()
        let w = ceil(size.width), h = ceil(size.height)
        let y = ((bounds.height - h) / 2).rounded()
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.removeAllAnimations()
        strip.sublayers?.forEach { $0.removeFromSuperlayer() }
        let scrolls = textWidth > bounds.width
        let copies: [CGFloat] = scrolls ? [0, w + Self.gap] : [0]
        for x in copies {
            let t = CATextLayer()
            t.string = str
            t.contentsScale = scale
            t.frame = CGRect(x: x, y: y, width: w, height: h)
            strip.addSublayer(t)
        }
        strip.frame = CGRect(x: 0, y: 0, width: (copies.last ?? 0) + w, height: bounds.height)
        if scrolls {
            let travel = w + Self.gap
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = 0
            move.toValue = -travel
            move.duration = CFTimeInterval(travel / Self.speed)
            move.beginTime = CACurrentMediaTime() + Self.delay
            move.repeatCount = .infinity
            strip.add(move, forKey: "marquee")
            let fade = CAGradientLayer()
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [CGColor.clear, CGColor.black, CGColor.black, CGColor.clear]
            fade.locations = [0, 0.06, 0.92, 1]
            fade.frame = bounds
            layer?.mask = fade
        } else {
            layer?.mask = nil
        }
        CATransaction.commit()
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

/// `>_<` for an eye break, blinking now and then: the glyph swaps to
/// `-_-` for a moment. Like the equaliser bars the swap is a Core
/// Animation keyframe animation the window server runs, never a SwiftUI
/// animation, and it is on screen only for the seconds of the peek.
struct BlinkingFace: View {
    static let face = ">_<"
    static let shut = "-_-"
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if snapshot || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            VText(Self.face).wingText(mono: false, tint: NT.accentText)
        } else {
            BlinkingFaceLayer(color: NSColor(NT.accentText).resolved(dark: scheme == .dark))
                .frame(width: BlinkingFaceNSView.size.width, height: BlinkingFaceNSView.size.height)
        }
    }
}

private struct BlinkingFaceLayer: NSViewRepresentable {
    let color: CGColor

    func makeNSView(context: Context) -> BlinkingFaceNSView {
        let view = BlinkingFaceNSView(frame: NSRect(origin: .zero, size: BlinkingFaceNSView.size))
        view.configure(color: color)
        return view
    }

    func updateNSView(_ nsView: BlinkingFaceNSView, context: Context) {
        nsView.configure(color: color)
    }
}

final class BlinkingFaceNSView: NSView {
    static let size = CGSize(width: 26, height: 16)
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
    /// One blink every `period` seconds.
    static let period: CFTimeInterval = 1.6
    /// The open face, then the shut one on top of it.
    private let faces = [CATextLayer(), CATextLayer()]
    private var color: CGColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for f in faces { layer?.addSublayer(f) }
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks go through to the notch, which opens on a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A discrete keyframe animation of one face's opacity: `open` is the
    /// open face (shown most of the period), otherwise the shut face (shown
    /// only during the blink). Discrete keyframes take one more key time
    /// than values.
    static func blink(open: Bool) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = (open ? [1.0, 0.0, 1.0] : [0.0, 1.0, 0.0]) as [Double]
        a.keyTimes = [0, 0.82, 0.92, 1]
        a.calculationMode = .discrete
        a.duration = period
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }

    func configure(color: CGColor) {
        guard color != self.color else { return }
        self.color = color
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, layer) in faces.enumerated() {
            let str = NSAttributedString(string: i == 0 ? BlinkingFace.face : BlinkingFace.shut, attributes: [
                .font: Self.font,
                .foregroundColor: NSColor(cgColor: color ?? .white) ?? .white,
            ])
            let size = str.size()
            layer.string = str
            layer.alignmentMode = .center
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.bounds = CGRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            layer.opacity = i == 0 ? 1 : 0
            if layer.animation(forKey: "blink") == nil {
                layer.add(Self.blink(open: i == 0), forKey: "blink")
            }
        }
        CATransaction.commit()
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
    /// Empty space above the row: the notch, or the gap above a floating toast.
    let top: CGFloat
    let rowHeight: CGFloat
    let ear: CGFloat
    let open: () -> Void
    let dismiss: () -> Void
    /// Runs the banner's own button.
    var act: (BannerAction) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: top)
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
                if banner.action == .pauseFocus {
                    TextPill(title: "Pause focus", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                        act(.pauseFocus)
                    }
                    .help("Pause the focus session while you are in the meeting")
                } else if let tag = Format.sourceTag(banner.source) {
                    VText(tag).nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
                }
                IconButton(symbol: "xmark", label: "Dismiss", size: NGlyph.small, action: dismiss)
            }
            .padding(.horizontal, ear + 14)
            .frame(height: rowHeight)
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

    /// Attached, the header row shares the notch's height and steps around
    /// it; the floating panel sits below the notch and needs neither.
    private var headerHeight: CGFloat {
        model.layout.floating ? NotchGeometry.floatingHeaderHeight : model.notch.height
    }
    private var headerGap: CGFloat { model.layout.floating ? 0 : model.notch.width + 24 }

    var body: some View {
        let vm = model.view
        let pending = vm?.agents.pending ?? []
        VStack(spacing: 0) {
            if !pending.isEmpty {
                // The one being looked at; the first when it was answered or
                // none was picked.
                let i = pending.firstIndex { $0.id == shownApproval } ?? 0
                let request = pending[i]
                ApprovalHeader(index: i + 1, total: pending.count, gap: headerGap, ear: ear) { d in
                    let j = min(max(i + d, 0), pending.count - 1)
                    shownApproval = pending[j].id
                }
                .frame(height: headerHeight)
                // A new id re-arms Allow (see ApprovalView.armDelay).
                ApprovalView(request: request, send: model.send)
                    .id(request.id)
                    .padding(.horizontal, ear + 14)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
            } else {
                TabBar(model: model, ear: ear)
                    .frame(height: headerHeight)
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
            Spacer(minLength: model.layout.floating ? 0 : model.notch.width + 24)
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
