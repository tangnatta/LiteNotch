import AppKit
import SwiftUI

// MARK: - Model (`core::body`)

/// Mirrors `body::BodyShow`: which gauges Home's big card shows.
public enum BodyShow: String, Codable, Equatable, CaseIterable {
    case both, water
    public init(from decoder: Decoder) throws {
        self = BodyShow(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .both
    }
}

/// Mirrors `body::BodyConfig`: minutes of screen time from full to empty,
/// 0 meaning off.
public struct BodyConfig: Codable, Equatable {
    public var waterMins: Int = 0
    public var stretchMins: Int = 0
    public var show: BodyShow = .both

    public static let `default` = BodyConfig()

}

extension BodyConfig {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waterMins = (try? c.decodeIfPresent(Int.self, forKey: .waterMins)) ?? 0
        stretchMins = (try? c.decodeIfPresent(Int.self, forKey: .stretchMins)) ?? 0
        show = (try? c.decodeIfPresent(BodyShow.self, forKey: .show)) ?? .both
    }
}

/// One gauge (`body::GaugeView`). While counting it is empty at
/// `emptyAtMs`; otherwise it stands at `leftMs`.
public struct GaugeView: Codable, Equatable {
    public var spanMs: Int
    public var leftMs: Int
    public var emptyAtMs: Int?
    public var lastMs: Int?
    /// What floats up when it was filled: "+1 cup", "+1 sip" or "+1".
    public var lastLabel: String?

    public init(spanMs: Int, leftMs: Int, emptyAtMs: Int?, lastMs: Int? = nil, lastLabel: String? = nil) {
        self.spanMs = spanMs
        self.leftMs = leftMs
        self.emptyAtMs = emptyAtMs
        self.lastMs = lastMs
        self.lastLabel = lastLabel
    }
}

public struct BodyView: Codable, Equatable {
    public var water: GaugeView?
    public var stretch: GaugeView?
}

/// The arithmetic the card draws with; pure so it can be tested.
public enum BodyMath {
    /// 0...1 at `nowMs`.
    public static func level(_ g: GaugeView, nowMs: Int) -> Double {
        guard g.spanMs > 0 else { return 0 }
        let left = g.emptyAtMs.map { max(0, $0 - nowMs) } ?? g.leftMs
        return min(1, max(0, Double(left) / Double(g.spanMs)))
    }

    public static func percent(_ g: GaugeView, nowMs: Int) -> Int {
        Int((level(g, nowMs: nowMs) * 100).rounded())
    }

    /// How often the number can change: one percent of the span, never
    /// more often than every 10 s.
    public static func redrawSecs(_ g: GaugeView) -> TimeInterval {
        max(10, Double(g.spanMs) / 100 / 1000)
    }

    /// "Drank 20m ago", "Drank just now", or "Not yet" before the first time.
    public static func since(_ lastMs: Int?, nowMs: Int, verb: String) -> String {
        guard let last = lastMs else { return "Not yet" }
        let mins = max(0, nowMs - last) / 60_000
        if mins < 1 { return "\(verb) just now" }
        if mins < 60 { return "\(verb) \(mins)m ago" }
        return "\(verb) \(mins / 60)h ago"
    }
}

// MARK: - Card

enum BodyKind {
    case water, stretch

    var title: String { self == .water ? "Water" : "Stretch" }
    var symbol: String { self == .water ? "drop" : "figure.flexibility" }
    var verb: String { self == .water ? "Drank" : "Stretched" }
    var button: String { self == .water ? "Drank" : "Stretch" }
    var command: ShellCommand { self == .water ? .bodyDrink : .bodyStretch }
    /// Blue water, orange stretch; the same at every level, never a warning.
    var color: NSColor { self == .water ? .systemBlue : .systemOrange }

    /// The "+200 ml" that floats up: the gauge's colour made lighter on dark
    /// and deeper on light, so it stands out from the water it rises over.
    func floatColor(dark: Bool) -> Color {
        let base = color.resolved(dark: dark)
        let ns = NSColor(cgColor: base) ?? color
        let mixed = dark ? ns.blended(withFraction: 0.6, of: .white) : ns.blended(withFraction: 0.25, of: .black)
        return Color(nsColor: mixed ?? ns)
    }
}

/// Home's big card as the water and stretch gauges: each column is its own
/// tank, filled from the bottom, the number centred like day progress.
struct BodyCard: View {
    let gauges: BodyView
    let show: BodyShow
    let send: (ShellCommand) -> Void

    var body: some View {
        let columns: [(BodyKind, GaugeView)] = [
            gauges.water.map { (BodyKind.water, $0) },
            show == .both ? gauges.stretch.map { (BodyKind.stretch, $0) } : nil,
        ].compactMap { $0 }
        // Water alone, or stretch alone when water is off.
        let shown = columns.isEmpty ? gauges.stretch.map { [(BodyKind.stretch, $0)] } ?? [] : columns
        HStack(spacing: 6) {
            ForEach(shown, id: \.0.title) { kind, gauge in
                GaugeColumn(kind: kind, gauge: gauge, wide: shown.count == 1, send: send)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GaugeColumn: View {
    let kind: BodyKind
    let gauge: GaugeView
    let wide: Bool
    let send: (ShellCommand) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floats: [FloatingLabel] = []
    /// Stretch taps in a row, for "+2", "+3" …
    @State private var combo = 0
    @State private var comboAt = Date.distantPast

    var body: some View {
        ZStack {
            Liquid(gauge: gauge, color: kind.color, scheme: scheme, animated: !reduceMotion)
            EverySecond(interval: BodyMath.redrawSecs(gauge)) { now in
                VStack(spacing: wide ? 6 : 4) {
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: kind.symbol).glyph(11, .medium)
                        Text(verbatim: kind.title).nfont(.caption)
                    }
                    .foregroundStyle(NT.text2)
                    let p = BodyMath.percent(gauge, nowMs: now)
                    (Text(verbatim: "\(p)").font(.system(size: wide ? 52 : 36, weight: .light)).monospacedDigit()
                        + Text(verbatim: "%").font(.system(size: wide ? 26 : 18, weight: .light)))
                        .foregroundStyle(NT.text1).lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityLabel(Text(verbatim: "\(kind.title) \(p)%"))
                    Text(verbatim: BodyMath.since(gauge.lastMs, nowMs: now, verb: kind.verb))
                        .nfont(.caption).foregroundStyle(NT.text2).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    // The button sits at the bottom, the reading centred above it.
                    TextPill(title: kind.button, tint: NT.text1, background: NT.fillHi, height: 22) { send(kind.command) }
                        // "+1 cup" rises from the button, past the number.
                        .overlay {
                            ForEach(floats) { f in
                                FloatingText(label: f, reduceMotion: reduceMotion, color: kind.floatColor(dark: scheme == .dark)) {
                                    floats.removeAll { $0.id == f.id }
                                }
                            }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))
        .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))
        // A click anywhere on the tank counts like its button: a near miss
        // used to open Settings instead.
        .contentShape(RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))
        .onTapGesture { send(kind.command) }
        .onChange(of: gauge.lastMs) { _, _ in
            guard let label = gauge.lastLabel else { return }
            var text = label
            if kind == .stretch {
                combo = Date().timeIntervalSince(comboAt) < 1.5 ? combo + 1 : 1
                comboAt = Date()
                text = "+\(combo)"
            }
            floats.append(FloatingLabel(text: text))
        }
    }
}

struct FloatingLabel: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// "+1 cup" rising from the button and fading, once.
private struct FloatingText: View {
    let label: FloatingLabel
    let reduceMotion: Bool
    let color: Color
    let done: () -> Void
    @State private var up = false

    var body: some View {
        Text(verbatim: label.text)
            .nfont(.emphasis)
            .foregroundStyle(color)
            .offset(y: up ? -64 : -8)
            .opacity(up ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 1.1)) { up = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
            }
    }
}

// MARK: - Liquid

/// The water in a tank. Like the progress ring it moves only by Core
/// Animation (one fall from the level now to empty, and the little wave
/// sliding sideways), so the panel is not re-rendered while it drains.
private struct Liquid: View {
    let gauge: GaugeView
    let color: NSColor
    let scheme: ColorScheme
    let animated: Bool
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.clockOffsetMs) private var offset

    var body: some View {
        let now = nowMs(Date(), offset: offset)
        let fill = Color(nsColor: color).opacity(LiquidNSView.alpha)
        if snapshot {
            GeometryReader { geo in
                let h = (geo.size.height - LiquidNSView.waveHeight) * BodyMath.level(gauge, nowMs: now)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(fill).frame(height: h + LiquidNSView.waveHeight / 2)
                }
            }
            .accessibilityHidden(true)
        } else {
            LiquidLayer(
                gauge: gauge, nowMs: now,
                color: color.resolved(dark: scheme == .dark),
                animated: animated
            )
            .accessibilityHidden(true)
        }
    }
}

private struct LiquidLayer: NSViewRepresentable {
    let gauge: GaugeView
    let nowMs: Int
    let color: CGColor
    let animated: Bool

    func makeNSView(context: Context) -> LiquidNSView { LiquidNSView(frame: .zero) }

    func updateNSView(_ view: LiquidNSView, context: Context) {
        view.configure(gauge: gauge, nowMs: nowMs, color: color, animated: animated)
    }
}

final class LiquidNSView: NSView {
    static let alpha: CGFloat = 0.38
    static let waveHeight: CGFloat = 6
    /// One wave length, so the wave slides seamlessly by this much.
    private static let waveLength: CGFloat = 40
    private static let waveSecs: CFTimeInterval = 3.2
    /// How long the water takes to rise after a tap.
    static let riseSecs: CFTimeInterval = 0.6

    /// Body and wave move together.
    let water = CALayer()
    /// Holds the water; only the rise after a tap moves it, so the rise and
    /// the fall never animate the same property (Core Animation orders those
    /// by start time, and the fall, starting later, overwrote the rise).
    let lift = CALayer()
    private let fill = CALayer()
    let wave = CAShapeLayer()
    private var gauge: GaugeView?
    private var nowMs = 0
    private var configuredAt = Date()
    private var animated = true
    /// What the running fall was made from; SwiftUI calls `configure` on
    /// every redraw, only a new level or state starts it again.
    private var anchor: [Int]?
    /// Width and motion the wave was built for; it restarts only when one
    /// changes, not on every tap.
    private var waveKey: (CGFloat, Bool)?
    /// The tank height of the last layout; a rise only within one size.
    private var laidOutHeight: CGFloat?
    /// A new level (or motion setting) since the last layout. Layout runs
    /// more often than that, sometimes twice in one pass; only then, or on
    /// a new size, are the fall and the rise set again. Setting them on
    /// every layout cancelled the rise the moment it started.
    private var levelChanged = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The card's `clipShape` does not reach a hosted NSView: clip here,
        // with the card's corners, or low water shows below the card.
        clipsToBounds = true
        layer?.cornerRadius = NT.radiusContainer
        layer?.cornerCurve = .continuous
        // Opaque colour in body and wave, transparency once on their
        // parent: two translucent layers overlapping drew a dark line.
        water.opacity = Float(Self.alpha)
        water.addSublayer(fill)
        water.addSublayer(wave)
        lift.addSublayer(water)
        layer?.addSublayer(lift)
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks go through to the card and its button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(gauge: GaugeView, nowMs: Int, color: CGColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        fill.backgroundColor = color
        wave.fillColor = color
        self.gauge = gauge
        self.nowMs = nowMs
        configuredAt = Date()
        if animated != self.animated {
            self.animated = animated
            anchor = nil
            levelChanged = true
            needsLayout = true
        }
        let key = [gauge.spanMs, gauge.leftMs, gauge.emptyAtMs ?? -1]
        guard key != anchor else { return }
        anchor = key
        levelChanged = true
        needsLayout = true
    }

    /// The water's offset below full at `level`.
    private func drop(_ level: Double) -> CGFloat {
        -(bounds.height - Self.waveHeight) * (1 - level)
    }

    override func layout() {
        super.layout()
        guard let gauge else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let w = bounds.width
        let body = bounds.height - Self.waveHeight
        // Not `frame`: the water carries a transform (its fall), and setting
        // `frame` then moves the layer to cancel it, which drew the water
        // hanging from the top after every tap.
        for l in [lift, water] {
            l.bounds = CGRect(origin: .zero, size: bounds.size)
            l.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        fill.frame = CGRect(x: 0, y: 0, width: w, height: body)
        // Twice as wide as the tank plus a wave length, sliding left by one
        // wave length forever.
        let len = Self.waveLength
        let path = CGMutablePath()
        let width = w + 2 * len
        path.move(to: CGPoint(x: 0, y: 0))
        var x: CGFloat = 0
        path.addLine(to: CGPoint(x: 0, y: Self.waveHeight / 2))
        while x < width {
            path.addQuadCurve(
                to: CGPoint(x: x + len / 2, y: Self.waveHeight / 2),
                control: CGPoint(x: x + len / 4, y: Self.waveHeight))
            path.addQuadCurve(
                to: CGPoint(x: x + len, y: Self.waveHeight / 2),
                control: CGPoint(x: x + 3 * len / 4, y: 0))
            x += len
        }
        path.addLine(to: CGPoint(x: x, y: 0))
        path.closeSubpath()
        wave.frame = CGRect(x: 0, y: body - 0.5, width: width, height: Self.waveHeight)
        if waveKey.map({ $0 != (w, animated) }) ?? true {
            waveKey = (w, animated)
            wave.path = path
            wave.removeAnimation(forKey: "slide")
        }
        if animated, wave.animation(forKey: "slide") == nil {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0
            slide.toValue = -len
            slide.duration = Self.waveSecs
            slide.repeatCount = .infinity
            // A slow wave reads as smooth at 30 fps; at the display's full
            // rate it cost about 1 % CPU.
            slide.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            wave.add(slide, forKey: "slide")
        }

        // Layout can come later than `configure` (a resize): go by the time
        // now.
        let nowMs = self.nowMs + Int(Date().timeIntervalSince(configuredAt) * 1000)
        let level = BodyMath.level(gauge, nowMs: nowMs)
        // Where the water is on screen now, before it is moved: after a tap
        // it rises from there instead of jumping (same tank size only, not
        // on a resize).
        let resized = laidOutHeight != bounds.height
        guard levelChanged || resized else { return }
        levelChanged = false
        // Both layers count: a tap during a rise starts from where it is.
        let y = { (l: CALayer) in l.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat }
        let shown = y(water).map { $0 + (y(lift) ?? 0) }
        let rise: CGFloat? =
            animated && !resized
            ? shown.flatMap { drop(level) > $0 + 0.5 ? $0 : nil } : nil
        laidOutHeight = bounds.height
        water.removeAnimation(forKey: "fall")
        lift.removeAnimation(forKey: "rise")
        water.setAffineTransform(CGAffineTransform(translationX: 0, y: drop(level)))
        if let end = gauge.emptyAtMs, end > nowMs {
            let fall = CABasicAnimation(keyPath: "transform.translation.y")
            fall.fromValue = drop(level)
            fall.toValue = drop(0)
            fall.duration = Double(end - nowMs) / 1000
            fall.timingFunction = CAMediaTimingFunction(name: .linear)
            // It moves a point every few seconds; no need for more frames.
            fall.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 2, preferred: 1)
            water.setAffineTransform(CGAffineTransform(translationX: 0, y: drop(0)))
            water.add(fall, forKey: "fall")
        }
        if let from = rise {
            // The holder starts as far below as the water was and comes back
            // to rest, while the water inside goes on falling. One short
            // animation per tap, nothing between taps.
            let up = CABasicAnimation(keyPath: "transform.translation.y")
            up.fromValue = from - drop(level)
            up.toValue = 0
            up.duration = Self.riseSecs
            up.timingFunction = CAMediaTimingFunction(name: .easeOut)
            lift.add(up, forKey: "rise")
        }
    }
}

// MARK: - Closed notch

extension BodyMath {
    /// The gauge a closed-notch `body` activity stands for: counting down
    /// to `endsAtMs` over `totalSecs`, or standing still at `value` ("48%").
    public static func gauge(_ c: CompactView) -> GaugeView {
        // Without a span (a stand-in, such as the Settings › Notch preview)
        // percent itself is the unit, so "48%" stays 48 %.
        let span = (c.totalSecs ?? 0) > 0 ? (c.totalSecs ?? 0) * 1000 : 100
        let still = Int(c.value.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0
        return GaugeView(spanMs: span, leftMs: span * still / 100, emptyAtMs: c.endsAtMs)
    }

    /// When the whole percent next goes down, while counting; nil when still
    /// or empty.
    public static func nextPercentMs(_ g: GaugeView, nowMs: Int) -> Int? {
        guard let end = g.emptyAtMs, g.spanMs > 0 else { return nil }
        let p = percent(g, nowMs: nowMs)
        guard p > 0 else { return nil }
        // Below p − 0.5 % from this moment on.
        return end - g.spanMs * (2 * p - 1) / 200 + 1
    }
}

/// One entry each time a gauge's whole percent goes down.
struct BodySchedule: TimelineSchedule {
    let gauge: GaugeView
    let offsetMs: Int

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        let (g, off) = (gauge, offsetMs)
        return AnySequence(
            sequence(first: startDate) { date in
                let now = nowMs(date, offset: off)
                guard let next = BodyMath.nextPercentMs(g, nowMs: now) else { return nil }
                return date.addingTimeInterval(Double(max(next - now, 1)) / 1000)
            })
    }
}

/// Redraws `content` with the level each time the whole percent changes;
/// a still gauge draws once.
private struct BodyReading<Content: View>: View {
    let compact: CompactView
    @ViewBuilder var content: (_ gauge: GaugeView, _ nowMs: Int) -> Content
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.clockOffsetMs) private var offset

    var body: some View {
        let g = BodyMath.gauge(compact)
        if snapshot || g.emptyAtMs == nil {
            content(g, nowMs(Date(), offset: offset))
        } else {
            TimelineView(BodySchedule(gauge: g, offsetMs: offset)) { _ in
                // The clock, not the entry's date (see `DayPercent`).
                content(g, nowMs(Date(), offset: offset))
            }
        }
    }
}

extension BodyKind {
    init(title: String) { self = title == "Stretch" ? .stretch : .water }
}

/// The gauge's own symbol in its colour: a drop for water, a stretching
/// figure for stretch. (A battery filled to the level was tried and read as
/// the Mac's battery.) Still: it never changes while shown.
struct BodyIcon: View {
    let compact: CompactView

    var body: some View {
        let kind = BodyKind(title: compact.title)
        Image(systemName: kind == .water ? "drop.fill" : "figure.flexibility")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color(nsColor: kind.color))
            .accessibilityHidden(true)
    }
}

/// The level, "48%", regular weight in the secondary text colour: a reading.
struct BodyPercent: View {
    let compact: CompactView

    var body: some View {
        BodyReading(compact: compact) { g, now in
            let reading = String(BodyMath.percent(g, nowMs: now)) + "%"
            // Secondary text: a quiet reading, quieter than a countdown.
            VText(reading).font(NType.body.font).monospacedDigit()
                .foregroundStyle(NT.text2).lineLimit(1)
                // The icon is hidden: say which gauge.
                .accessibilityLabel(Text(verbatim: compact.title + " " + reading))
        }
    }
}
