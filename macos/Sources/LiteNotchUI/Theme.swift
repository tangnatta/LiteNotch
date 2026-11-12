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
    private(set) static var accentHex = AppearanceConfig.defaultAccent
    private(set) static var accent = color(AppearanceConfig.defaultAccent)
    private(set) static var onAccent = Color.black
    /// The accent for text and icons: on the light panel a pale accent
    /// (the default orange is one) is darkened until it reads.
    private(set) static var accentText = accentForeground(AppearanceConfig.defaultAccent)

    /// Sets the accent from a settings string; an invalid one means the
    /// default. Returns whether anything changed.
    @discardableResult
    static func setAccent(_ raw: String) -> Bool {
        let hex = ColorMath.normalize(raw) ?? AppearanceConfig.defaultAccent
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
            if ColorMath.contrast(ColorMath.RGB(r: c.r * k, g: c.g * k, b: c.b * k),
                                  ColorMath.RGB(r: 0.965, g: 0.965, b: 0.965)) >= 4.5 { break }
        }
        return dynamic(dark: base, light: light)
    }

    static func color(_ hex: String) -> Color {
        let c = ColorMath.parse(hex) ?? ColorMath.RGB(r: 1, g: 0.62, b: 0.04)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    static let allow = Color(red: 0.20, green: 0.80, blue: 0.40)
    static let deny = dynamic(dark: NSColor(srgbRed: 1.0, green: 0.30, blue: 0.27, alpha: 1),
                              light: NSColor(srgbRed: 0.86, green: 0.17, blue: 0.14, alpha: 1))
    static let text1 = dynamic(dark: .white, light: NSColor(white: 0.07, alpha: 1))
    static let text2 = dynamic(dark: NSColor(white: 1, alpha: 0.62), light: NSColor(white: 0, alpha: 0.64))
    static let text3 = dynamic(dark: NSColor(white: 1, alpha: 0.38), light: NSColor(white: 0, alpha: 0.45))
    static let fill = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.05))
    static let fillHi = dynamic(dark: NSColor(white: 1, alpha: 0.14), light: NSColor(white: 0, alpha: 0.10))
    static let hairline = dynamic(dark: NSColor(white: 1, alpha: 0.10), light: NSColor(white: 0, alpha: 0.10))
    /// Background of the open panel and the toast. The closed notch is
    /// always `Color.black`.
    static let panel = dynamic(dark: .black, light: NSColor(white: 0.965, alpha: 1))
    /// Knob of a switched-off toggle.
    static let knob = dynamic(dark: NSColor(white: 1, alpha: 0.85), light: .white)

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
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

// MARK: - Environment

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
private struct ClockOffsetKey: EnvironmentKey { static let defaultValue = 0 }

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
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                content.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Shape

/// The notch silhouette: flush top edge with small concave ears, convex
/// rounded bottom corners. `rect.width` includes the ears.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.height / 2)
        let b = min(bottomRadius, max(0, r.height - t), (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t),
                       control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY),
                       control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b),
                       control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Text

/// Text that can never be interpreted as markdown or a localisation key.
/// Every string that comes from the view model goes through this.
func VText(_ s: String) -> Text { Text(verbatim: s) }

extension View {
    func nfont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
    }
}

// MARK: - Controls

struct NotchToggle: View {
    @Binding var isOn: Bool
    var label: String = ""

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? NT.accent : NT.fillHi)
                Circle().fill(isOn ? NT.onAccent : NT.knob)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .animation(.snappy(duration: 0.16), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

struct MiniStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var label: String = ""

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", delta: -step, name: "Decrease")
            Text(verbatim: "\(value)")
                .nfont(11.5, .medium).monospacedDigit()
                .foregroundStyle(NT.text1)
                .frame(minWidth: 26)
            stepButton("plus", delta: step, name: "Increase")
        }
        .background(NT.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }

    private func stepButton(_ symbol: String, delta: Int, name: String) -> some View {
        Button { value = min(max(value + delta, range.lowerBound), range.upperBound) } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(NT.text2)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(name) \(label)"))
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 13
    var tint: Color = NT.text2
    var frame: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: frame, height: frame)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .nfont(11.5, weight)
                .foregroundStyle(tint)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(verbatim: text.uppercased())
            .nfont(10, .semibold).tracking(0.8)
            .foregroundStyle(NT.text3)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var expand = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: expand ? .infinity : nil)
            .padding(padding)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Two or more options in one capsule; the selected one is highlighted.
struct SegmentedPill<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String = ""
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == selection
                Button { selection = o.value } label: {
                    Text(verbatim: o.title)
                        .nfont(11.5, on ? .semibold : .medium)
                        .foregroundStyle(on ? NT.text1 : NT.text2)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: height - 4)
                        .background(on ? NT.fillHi : Color.clear, in: Capsule())
                        .contentShape(Capsule())
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

/// Centred icon + line(s) for a tab with nothing to show.
struct EmptyState: View {
    let symbol: String
    let title: String
    var hint: String = ""

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(NT.text3)
            Text(verbatim: title).nfont(12).foregroundStyle(NT.text3)
            if !hint.isEmpty {
                Text(verbatim: hint).nfont(11).foregroundStyle(NT.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
