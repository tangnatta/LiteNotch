import AppKit
import SwiftUI

/// Design tokens. One accent (warm orange by default, user-chosen) carries
/// focus and attention; green is reserved for Allow, red for Deny.
///
/// The neutral tokens are dynamic: they resolve against the SwiftUI
/// `colorScheme` of wherever they are drawn, so the closed notch can stay
/// dark while the open panel is light.
enum NT {
    /// The accent and the colour of text drawn on it. Main thread only;
    /// `AppModel.apply` updates them and the root view rebuilds on change.
    /// `#RRGGBB`, or `mono` for the black/white accent.
    private(set) static var accentHex = AppearanceConfig.defaultAccent
    /// The operating system's accent as `#RRGGBB`. Tests replace it.
    static var systemAccent: () -> String? = { ColorMath.hex(of: NSColor.controlAccentColor) }
    private(set) static var accent = color(AppearanceConfig.defaultAccent)
    private(set) static var onAccent = Color.black
    /// The accent for text and icons: on the light panel a pale accent
    /// (the default orange is one) is darkened until it reads.
    private(set) static var accentText = accentForeground(AppearanceConfig.defaultAccent)

    /// Sets the accent from a settings string: a colour, `system` (the
    /// operating system's accent, as it is now) or `mono`; an invalid one
    /// means the default. Returns whether anything changed.
    @discardableResult
    static func setAccent(_ raw: String) -> Bool {
        let hex: String
        switch AccentChoice(raw) {
        case .mono:
            guard accentHex != "mono" else { return false }
            accentHex = "mono"
            // The primary text colour of each scheme, and its opposite on it.
            accent = text1
            accentText = text1
            onAccent = dynamic(dark: .black, light: .white)
            return true
        case .system: hex = systemAccent().flatMap(ColorMath.normalize) ?? AppearanceConfig.defaultAccent
        case .color(let h): hex = h
        }
        guard hex != accentHex else { return false }
        accentHex = hex
        accent = color(hex)
        let dark = ColorMath.parse(hex).map { ColorMath.prefersDarkText(on: $0) } ?? true
        onAccent = dark ? .black : .white
        accentText = accentForeground(hex)
        return true
    }

    private static func accentForeground(_ hex: String) -> Color {
        let c = ColorMath.parse(hex) ?? ColorMath.RGB(r: 1, g: 0.62, b: 0.04)
        let base = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        // Darken toward black until the colour has at least 4.5:1 contrast
        // with the light panel (WCAG AA for text).
        var light = base
        for step in stride(from: 0.0, through: 0.8, by: 0.05) {
            let k = 1 - step
            light = NSColor(srgbRed: c.r * k, green: c.g * k, blue: c.b * k, alpha: 1)
            if ColorMath.contrast(
                ColorMath.RGB(r: c.r * k, g: c.g * k, b: c.b * k),
                ColorMath.RGB(r: 0.965, g: 0.965, b: 0.965)) >= 4.5
            {
                break
            }
        }
        return dynamic(dark: base, light: light)
    }

    static func color(_ hex: String) -> Color {
        let c = ColorMath.parse(hex) ?? ColorMath.RGB(r: 1, g: 0.62, b: 0.04)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    static let allow = Color(red: 0.20, green: 0.80, blue: 0.40)
    static let deny = dynamic(
        dark: NSColor(srgbRed: denyRGB.dark.r, green: denyRGB.dark.g, blue: denyRGB.dark.b, alpha: 1),
        light: NSColor(srgbRed: denyRGB.light.r, green: denyRGB.light.g, blue: denyRGB.light.b, alpha: 1))
    /// Warnings that need the user (a missing permission, a password
    /// prompt): the system's amber, darkened on the light panel to stay
    /// readable. Kept apart from the accent, which means "act here".
    static let warningRGB = (
        dark: ColorMath.RGB(r: 1.0, g: 0.72, b: 0.25),
        light: ColorMath.RGB(r: 0.55, g: 0.31, b: 0.0)
    )
    static let warning = dynamic(
        dark: NSColor(srgbRed: warningRGB.dark.r, green: warningRGB.dark.g, blue: warningRGB.dark.b, alpha: 1),
        light: NSColor(srgbRed: warningRGB.light.r, green: warningRGB.light.g, blue: warningRGB.light.b, alpha: 1))
    /// Over-time and destructive text; `denyRGB` is what the test checks.
    static let denyRGB = (
        dark: ColorMath.RGB(r: 1.0, g: 0.40, b: 0.36),
        light: ColorMath.RGB(r: 0.80, g: 0.13, b: 0.10)
    )

    /// Primary text: titles, values.
    static let text1 = dynamic(.text1)
    /// Day progress's plant in the closed notch; the only place it is green.
    static let grow = Color(nsColor: .systemGreen)
    /// Secondary text: subtitles, body copy.
    static let text2 = dynamic(.text2)
    /// Captions, timestamps, inactive icons. Still 4.5:1 on every surface
    /// (a test checks it), so it is quiet but never faint.
    static let text3 = dynamic(.text3)
    /// The one card per screen, and controls at rest.
    static let fill = dynamic(.fill)
    /// Selected and hovered controls.
    static let fillHi = dynamic(.fillHi)
    static let hairline = dynamic(.hairline)
    /// Background of the open panel, and of the closed notch and the toast
    /// when they follow the theme (`ClosedNotchChoice.theme`); otherwise
    /// those are `Color.black`.
    static let panel = dynamic(.panel)
    /// Knob of a switched-off toggle.
    static let knob = dynamic(dark: NSColor(white: 1, alpha: 0.85), light: .white)

    /// Two radii by role: a container (the card, the settings pane, the
    /// approval detail) and a control or row (fields, hover fills, tiles).
    static let radiusContainer: CGFloat = 14
    static let radiusControl: CGFloat = 8

    /// The neutral tokens as grey levels with alpha, per scheme. The colours
    /// are built from this table and the contrast test reads it.
    enum Tone: CaseIterable {
        case text1, text2, text3, fill, fillHi, hairline, panel

        /// `(white, alpha)` in sRGB.
        func value(dark: Bool) -> (white: Double, alpha: Double) {
            switch (self, dark) {
            case (.text1, true): return (1, 1)
            case (.text1, false): return (0.07, 1)
            case (.text2, true): return (1, 0.72)
            case (.text2, false): return (0, 0.72)
            case (.text3, true): return (1, 0.52)
            case (.text3, false): return (0, 0.58)
            case (.fill, true): return (1, 0.08)
            case (.fill, false): return (0, 0.05)
            case (.fillHi, true): return (1, 0.14)
            case (.fillHi, false): return (0, 0.10)
            case (.hairline, true): return (1, 0.12)
            case (.hairline, false): return (0, 0.10)
            case (.panel, true): return (0, 1)
            case (.panel, false): return (0.965, 1)
            }
        }

        /// The opaque colour this tone shows over `background`.
        func resolved(dark: Bool, over background: ColorMath.RGB) -> ColorMath.RGB {
            let v = value(dark: dark)
            return ColorMath.over(ColorMath.RGB(r: v.white, g: v.white, b: v.white), alpha: v.alpha, background)
        }
    }

    private static func dynamic(_ t: Tone) -> Color {
        let d = t.value(dark: true)
        let l = t.value(dark: false)
        return dynamic(
            dark: NSColor(srgbRed: d.white, green: d.white, blue: d.white, alpha: d.alpha),
            light: NSColor(srgbRed: l.white, green: l.white, blue: l.white, alpha: l.alpha))
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? light : dark
            })
    }
}

extension ThemeChoice {
    /// The scheme to draw the open panel in; `system` is what the window
    /// reports, which follows the system setting live.
    func scheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system, .unknown: return system
        }
    }
}

extension AppearanceConfig {
    /// Whether the closed notch and the toast follow the theme. Never on a
    /// display with a hardware notch: the camera housing stays black, so a
    /// light shape around it would read as two white wings.
    func closedFollowsTheme(hardwareNotch: Bool) -> Bool {
        closedNotch == .theme && !hardwareNotch
    }

    /// The scheme of the closed notch and the toast: dark unless the user
    /// asked for them to follow the theme and the display has no notch.
    func closedScheme(system: ColorScheme, hardwareNotch: Bool = false) -> ColorScheme {
        closedFollowsTheme(hardwareNotch: hardwareNotch) ? theme.scheme(system: system) : .dark
    }

    /// Whether the closed notch and the toast are glass too, not only the
    /// open panel. Only where they already follow the theme: with a camera
    /// housing glass would show a black cut-out in a translucent band, and
    /// "Always dark" keeps them black. The Shrink strip stays solid: on an
    /// 8 pt strip the glass would be little more than its edge highlight.
    /// Never while an approval waits (see `drawsGlass`).
    func closedDrawsGlass(hardwareNotch: Bool, approvalPending: Bool, minimized: Bool) -> Bool {
        !minimized && closedFollowsTheme(hardwareNotch: hardwareNotch) && drawsGlass(approvalPending: approvalPending)
    }
}

// MARK: - Environment

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
private struct ClockOffsetKey: EnvironmentKey { static let defaultValue = 0 }
private struct DayIconsKey: EnvironmentKey { static let defaultValue = DayIcons.sun }
private struct MarqueeShiftKey: EnvironmentKey { static let defaultValue = 0 }
private struct KeyboardRequestKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

private struct DayMotionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when rendering with `ImageRenderer`, which cannot draw AppKit-backed
    /// controls or scroll views.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
    /// Added to the wall clock; lets snapshots pin "now" to the fixtures' time.
    var clockOffsetMs: Int {
        get { self[ClockOffsetKey.self] }
        set { self[ClockOffsetKey.self] = newValue }
    }
    /// How many leading words a scrolling title has moved past, for
    /// snapshots only: the README's previews step it per frame so a long
    /// line is read, not cut off.
    var marqueeShift: Int {
        get { self[MarqueeShiftKey.self] }
        set { self[MarqueeShiftKey.self] = newValue }
    }
    /// How the closed notch draws day progress (`settings.day.icons`).
    var dayIcons: DayIcons {
        get { self[DayIconsKey.self] }
        set { self[DayIconsKey.self] = newValue }
    }
    /// Whether the day icon moves (`settings.day.motion`).
    var dayMotion: Bool {
        get { self[DayMotionKey.self] }
        set { self[DayMotionKey.self] = newValue }
    }
    /// Asks the panel to take (or give back) the keyboard, for controls that
    /// have a text field but no `PanelState` of their own.
    var requestKeyboard: (Bool) -> Void {
        get { self[KeyboardRequestKey.self] }
        set { self[KeyboardRequestKey.self] = newValue }
    }
}

func nowMs(_ date: Date, offset: Int) -> Int {
    Int(date.timeIntervalSince1970 * 1000) + offset
}

/// A view that re-renders once a second, and only while it is on screen.
/// Idle notch = no instance exists = zero wakeups.
struct EverySecond<Content: View>: View {
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.clockOffsetMs) private var offset
    var interval: TimeInterval = 1
    @ViewBuilder var content: (_ nowMs: Int) -> Content

    var body: some View {
        if snapshot {
            content(nowMs(Date(), offset: offset))
        } else {
            TimelineView(.periodic(from: .now, by: interval)) { ctx in
                content(nowMs(ctx.date, offset: offset))
            }
        }
    }
}

/// Scroll view that degrades to clipped static content for snapshots.
struct NotchScroll<Content: View>: View {
    @Environment(\.isSnapshot) private var snapshot
    @ViewBuilder var content: Content

    var body: some View {
        if snapshot {
            // At its own height, cut off at the bottom like the top of a
            // scroll view: proposed the panel's height, a long page squeezed
            // its rows on top of each other.
            VStack(spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            // The content shapes make the gaps between rows, and the space
            // below a short list, part of the scroll view for the pointer:
            // without them the wheel did nothing there.
            ScrollView(.vertical, showsIndicators: false) {
                content.frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Shape

/// The notch silhouette: flush top edge with small concave ears
/// (`topRadius`), convex rounded bottom corners. With `topCorner` > 0 and no
/// ears the top corners are convex too, which makes the closed activity
/// shape a capsule. Both are animatable so the shape morphs between them.
/// `rect.width` includes the ears.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var topCorner: CGFloat = 0
    /// Space left empty above the shape (the island capsule sits below
    /// the hardware notch).
    var topInset: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), AnimatablePair(topCorner, topInset)) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            topCorner = newValue.second.first
            topInset = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var r = rect
        let inset = max(0, min(topInset, r.height))
        r.origin.y += inset
        r.size.height -= inset
        let t = max(0, min(topRadius, r.height / 2))
        let body = max(0, r.width - 2 * t)
        let c = max(0, min(topCorner, body / 2, r.height / 2))
        let b = max(0, min(bottomRadius, r.height - t - c, body / 2))
        // Top corner: a concave ear (start at the edge, end inside), a convex
        // corner (start inside on the top edge, end on the side), or a blend
        // of the two while animating.
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addQuadCurve(
            to: CGPoint(x: r.minX + t, y: r.minY + t + c),
            control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(
            to: CGPoint(x: r.minX + t + b, y: r.maxY),
            control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(
            to: CGPoint(x: r.maxX - t, y: r.maxY - b),
            control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t + c))
        p.addQuadCurve(
            to: CGPoint(x: r.maxX - c, y: r.minY),
            control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The area that takes the pointer: the shape, plus, above an island
/// shape, the column under the notch so the pointer can travel between them.
struct PointerShape: Shape {
    var shape: NotchShape
    var top: CGFloat
    var column: CGFloat

    func path(in r: CGRect) -> Path {
        var p = shape.path(in: r)
        if top > 0 {
            p.addRect(CGRect(x: r.midX - column / 2, y: r.minY, width: column, height: min(top, r.height)))
        }
        return p
    }
}

// MARK: - Text

/// Text that can never be interpreted as markdown or a localisation key.
/// Every string that comes from the view model goes through this.
func VText(_ s: String) -> Text { Text(verbatim: s) }

/// The type scale. SF Pro (the system font) throughout; hierarchy comes
/// from size, weight and the three text colours, never from capitals or
/// letter spacing.
enum NType: CaseIterable {
    /// Timestamps, units, secondary lines in dense rows.
    case caption
    /// A caption that labels something (a section, a status).
    case captionStrong
    /// Running text and row titles.
    case body
    /// Body on a control (pills, segmented options).
    case bodyMedium
    /// The one line in a row that matters most.
    case emphasis
    /// A block's title.
    case title
    /// The largest title on a screen, and countdowns in rows.
    case heading
    /// The big number on a screen (a clock, a total).
    case display
    /// Counters on badges.
    case badge

    var size: CGFloat {
        switch self {
        case .caption, .captionStrong: return 10.5
        case .body, .bodyMedium, .emphasis: return 12
        case .title: return 13.5
        case .heading: return 17
        case .display: return 26
        case .badge: return 9
        }
    }

    var weight: Font.Weight {
        switch self {
        case .caption, .body: return .regular
        case .bodyMedium: return .medium
        case .captionStrong, .emphasis, .title, .heading, .display: return .semibold
        case .badge: return .bold
        }
    }

    var font: Font {
        let f = Font.system(size: size, weight: weight)
        return self == .display || self == .badge ? f.monospacedDigit() : f
    }
}

/// Glyph sizes for SF Symbols that sit beside text.
enum NGlyph {
    /// Chevrons, row affordances, small status marks.
    static let small: CGFloat = 10
    /// Icons in rows and on buttons.
    static let regular: CGFloat = 12
    /// Empty-state and toolbar icons.
    static let large: CGFloat = 20
}

extension View {
    func nfont(_ t: NType) -> some View { font(t.font) }

    /// A symbol's size and weight.
    func glyph(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight))
    }

    /// A subtle fill under the pointer for a clickable row. The fill reaches
    /// `inset` past the row's edges so text stays aligned with its header.
    func rowHover(inset: CGFloat = 6) -> some View { modifier(RowHover(inset: inset)) }
}

private struct RowHover: ViewModifier {
    let inset: CGFloat
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous)
                    .fill(hover ? NT.fill : Color.clear)
                    .padding(.horizontal, -inset)
            )
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// Fill shown under a control while the pointer is on it.
private struct ControlHover<S: Shape>: ViewModifier {
    let shape: S
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .overlay(shape.fill(hover ? NT.fill : Color.clear).allowsHitTesting(false))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

extension View {
    func controlHover<S: Shape>(_ shape: S) -> some View { modifier(ControlHover(shape: shape)) }
}

// MARK: - Controls

struct NotchToggle: View {
    @Binding var isOn: Bool
    var label: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? NT.accent : NT.fillHi)
                Circle().fill(isOn ? NT.onAccent : NT.knob)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// A `− 12 +` pill. The number is a button: click it to type a value,
/// Return (or clicking elsewhere) applies it, Esc keeps the old one.
struct MiniStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var label: String = ""

    @Environment(\.requestKeyboard) private var requestKeyboard
    /// The text being typed; nil when showing the value.
    @State private var typed: String?
    /// The value when typing began, for Escape.
    @State private var original = 0
    /// The field's frame in the window, top-left origin.
    @State private var fieldFrame = CGRect.zero
    /// Watches for a click elsewhere while typing.
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool
    /// The field has had the keyboard since typing began.
    @State private var hadFocus = false

    /// What typed text sets the value to: a whole number, clamped to the
    /// range. Nil when it is not a number, so the old value stays.
    static func typedValue(_ text: String, range: ClosedRange<Int>) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 6, t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(t) else {
            return nil
        }
        return min(max(n, range.lowerBound), range.upperBound)
    }

    /// Whether a click ends the typing: any click that is not on the field.
    /// `windowPoint` is AppKit's (origin bottom-left), `field` is SwiftUI's
    /// global frame (origin top-left).
    static func clickEndsTyping(windowPoint: CGPoint, contentHeight: CGFloat, field: CGRect) -> Bool {
        !field.contains(CGPoint(x: windowPoint.x, y: contentHeight - windowPoint.y))
    }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", delta: -step, name: "Decrease")
            number
            stepButton("plus", delta: step, name: "Increase")
        }
        .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
        .onDisappear(perform: finish)
    }

    @ViewBuilder private var number: some View {
        if typed != nil {
            TextField(
                "",
                text: Binding(
                    get: { typed ?? "" },
                    set: { typed = Self.edited($0, typing: typed) })
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(NType.bodyMedium.font)
            .monospacedDigit()
            .foregroundStyle(NT.text1)
            .frame(width: 34, height: 22)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { fieldFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in fieldFrame = f }
                }
            )
            .focused($focused)
            .onSubmit(finish)
            .onExitCommand(perform: revert)
            .onChange(of: typed) { _, text in apply(text) }
            .onChange(of: focused) { _, f in
                if f { hadFocus = true }
                if Self.endsTyping(focused: f, hadFocus: hadFocus) { finish() }
            }
            .accessibilityLabel(Text(verbatim: label))
        } else {
            Button(action: begin) {
                Text(verbatim: "\(value)")
                    .nfont(.bodyMedium).monospacedDigit()
                    .foregroundStyle(NT.text1)
                    .frame(minWidth: 26, minHeight: 22)
                    .contentShape(Rectangle())
                    .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Click to type \(label.isEmpty ? "a value" : label.lowercased())")
            .accessibilityLabel(Text(verbatim: "\(label): \(value). Click to type."))
        }
    }

    /// Typing starts from the current value, selected, so it shows in the
    /// normal text colour and the first digit replaces it.
    private func begin() {
        original = value
        typed = Self.startingText(value)
        requestKeyboard(true)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            let height = event.window?.contentView?.bounds.height ?? 0
            if Self.clickEndsTyping(windowPoint: event.locationInWindow, contentHeight: height, field: fieldFrame) {
                finish()
            }
            return event
        }
        hadFocus = false
        focus(tries: 5)
    }

    /// Gives the field the keyboard. The panel only becomes able to take
    /// keys a moment after `requestKeyboard`, and a focus asked for before
    /// that is dropped, so this asks again until it holds.
    private func focus(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 5 ? 0 : 0.06)) {
            guard typed != nil, !hadFocus else { return }
            focused = true
            DispatchQueue.main.async {
                if focused {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else if tries > 1 {
                    focus(tries: tries - 1)
                }
            }
        }
    }

    /// Whether a change of focus ends the typing: only losing a focus the
    /// field really had. Before it ever had the keyboard, "not focused" is
    /// just the starting state, and ending there made the number impossible
    /// to edit.
    static func endsTyping(focused: Bool, hadFocus: Bool) -> Bool { !focused && hadFocus }

    /// The value follows the text as it is typed, so nothing is lost when
    /// the typing ends without Return (a click elsewhere, the panel closing).
    private func apply(_ text: String?) {
        if let v = Self.liveValue(text, current: value, range: range) { value = v }
    }

    /// The value to set while `text` is being typed, or nil to leave it:
    /// every keystroke that makes a number counts, with no Return needed.
    static func liveValue(_ text: String?, current: Int, range: ClosedRange<Int>) -> Int? {
        guard let text, let v = typedValue(text, range: range), v != current else { return nil }
        return v
    }

    /// The typing state after the field reports `text`. Once typing has
    /// ended (nil) it stays ended: as the field is torn down it reports an
    /// empty string, and taking that as new typing left an empty field
    /// where the number should be.
    static func edited(_ text: String, typing: String?) -> String? {
        guard typing != nil else { return nil }
        return String(text.filter { $0.isASCII && $0.isNumber }.prefix(4))
    }

    /// What the field holds when typing starts: the current value, so it is
    /// drawn as ordinary text, not as a dimmed placeholder.
    static func startingText(_ value: Int) -> String { "\(value)" }

    /// Ends the typing and keeps what was typed.
    private func finish() {
        guard let text = typed else { return }
        apply(text)
        typed = nil
        focused = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        requestKeyboard(false)
    }

    /// Escape: back to the value from before the typing.
    private func revert() {
        guard typed != nil else { return }
        typed = "\(original)"
        if value != original { value = original }
        finish()
    }

    private func stepButton(_ symbol: String, delta: Int, name: String) -> some View {
        Button {
            // A number being typed is applied first, then stepped.
            finish()
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: symbol).glyph(9, .bold)
                .foregroundStyle(NT.text2)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(name) \(label.lowercased())")
        .accessibilityLabel(Text(verbatim: "\(name) \(label)"))
    }
}

/// An icon-only button. The glyph can be small, but the hit area is at
/// least 28 × 28 pt, and the label doubles as the tooltip unless `help`
/// says more.
struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = NGlyph.regular
    var tint: Color = NT.text2
    var frame: CGFloat = 28
    var help: String?
    let action: () -> Void

    var body: some View {
        let side = max(frame, 28)
        Button(action: action) {
            Image(systemName: symbol)
                .glyph(size)
                .foregroundStyle(tint)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .controlHover(Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

struct TextPill: View {
    let title: String
    var tint: Color = NT.text1
    var background: Color = NT.fill
    var height: CGFloat = 24
    var weight: Font.Weight = .medium
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: NType.body.size, weight: weight))
                .foregroundStyle(tint)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(background, in: Capsule())
                .contentShape(Capsule())
                .controlHover(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Two-step confirmation for a destructive button: the first click arms
/// it, a second click within `window` acts, and anything else (the time
/// running out, the pointer leaving, the view going away) disarms it.
public struct ConfirmGate: Equatable {
    public static let window: TimeInterval = 3
    public private(set) var armedAt: Date?

    public init() {}

    public func isArmed(at now: Date) -> Bool {
        guard let t = armedAt else { return false }
        let age = now.timeIntervalSince(t)
        return age >= 0 && age < Self.window
    }

    /// A click. True when the action should run now.
    public mutating func tap(at now: Date) -> Bool {
        if isArmed(at: now) {
            armedAt = nil
            return true
        }
        armedAt = now
        return false
    }

    public mutating func disarm() { armedAt = nil }

    /// `Clear 12 items?`, `Clear 1 item?`, or `Clear all?` when the count
    /// is not known.
    public static func question(count: Int?) -> String {
        guard let n = count, n > 0 else { return "Clear all?" }
        return n == 1 ? "Clear 1 item?" : "Clear \(n) items?"
    }
}

/// A pill that asks before it acts: the first click turns it red and asks,
/// the second click acts.
struct ConfirmPill: View {
    let title: String
    let question: String
    var help: String = ""
    var enabled = true
    var height: CGFloat = 24
    let action: () -> Void

    @State private var gate = ConfirmGate()
    @State private var armed = false

    var body: some View {
        Button(action: tap) {
            Text(verbatim: armed ? question : title)
                .nfont(armed ? .emphasis : .bodyMedium)
                .foregroundStyle(armed ? NT.deny : (enabled ? NT.text2 : NT.text3))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(armed ? NT.deny.opacity(0.16) : Color.clear, in: Capsule())
                .contentShape(Capsule())
                .controlHover(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(armed ? "Click again to confirm" : help)
        .accessibilityLabel(Text(verbatim: armed ? "\(question) Activate again to confirm." : title))
        .onHover { inside in if !inside { disarm() } }
        .onDisappear(perform: disarm)
    }

    private func tap() {
        let now = Date()
        if gate.tap(at: now) {
            armed = false
            action()
            return
        }
        armed = true
        let stamp = gate.armedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + ConfirmGate.window) {
            if gate.armedAt == stamp { disarm() }
        }
    }

    private func disarm() {
        gate.disarm()
        armed = false
    }
}

struct ProgressBar: View {
    var value: Double
    var tint: Color = NT.text1
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(NT.fillHi)
                Capsule().fill(tint)
                    .frame(width: max(height, g.size.width * min(max(value, 0), 1)))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((value * 100).rounded())) percent"))
    }
}

/// A sentence-case label over a group, set apart by weight and colour.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .nfont(.captionStrong)
            .foregroundStyle(NT.text2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The primary block of a screen. Only one per screen: everything else
/// sits on the panel as rows.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var expand = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: expand ? .infinity : nil)
            .padding(padding)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))
    }
}

/// A hairline between rows.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(NT.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// Two or more options in one capsule; the selected one is highlighted.
struct SegmentedPill<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String = ""
    var height: CGFloat = 24
    /// Drawn before each option's title, if given.
    var optionIcon: ((Value) -> AnyView)? = nil
    /// An SF Symbol before each title, in the same order; none if empty.
    /// `optionIcon` wins when both are given.
    var symbols: [String] = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                let on = o.value == selection
                Button {
                    selection = o.value
                } label: {
                    HStack(spacing: optionIcon == nil ? 4 : 5) {
                        if let optionIcon {
                            optionIcon(o.value)
                        } else if i < symbols.count {
                            Image(systemName: symbols[i]).glyph(10, on ? .semibold : .medium)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: o.title)
                    }
                    .nfont(on ? .emphasis : .bodyMedium)
                    .foregroundStyle(on ? NT.text1 : NT.text2)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: height - 4)
                    .background(on ? NT.fillHi : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .controlHover(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(NT.fill, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

extension SegmentedPill {
    init<Icon: View>(
        options: [(value: Value, title: String)], selection: Binding<Value>, label: String = "",
        height: CGFloat = 24, @ViewBuilder icon: @escaping (Value) -> Icon
    ) {
        // `optionIcon:`, not `icon:`: with `icon:` this init called itself
        // forever and hung the app the moment Settings › Day opened.
        self.init(
            options: options, selection: selection, label: label, height: height,
            optionIcon: { AnyView(icon($0)) })
    }
}

/// Centred icon + what the feature does and how to start it.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    var hint: String = ""
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).glyph(NGlyph.large, .regular).foregroundStyle(NT.text3)
                .padding(.bottom, 2)
            Text(verbatim: title).nfont(.emphasis).foregroundStyle(NT.text2)
            if !hint.isEmpty {
                Text(verbatim: hint).nfont(.caption).foregroundStyle(NT.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }
            action.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, hint: String = "") {
        self.init(symbol: symbol, title: title, hint: hint) { EmptyView() }
    }
}

/// A warning line: amber icon and text, never the accent.
struct WarningText: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").glyph(NGlyph.small)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(NT.warning)
    }
}
