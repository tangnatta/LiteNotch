import AppKit
import SwiftUI

/// PoC: the day glyph moving, to measure what it costs. On only with
/// `LITENOTCH_DAY_ANIM=1`. The glyph is drawn once into a bitmap and a
/// Core Animation layer moves that bitmap (the rule for anything that
/// moves continuously), so SwiftUI never redraws per frame.
enum DayMotion {
    static let enabled = ProcessInfo.processInfo.environment["LITENOTCH_DAY_ANIM"] == "1"

    enum Kind { case spin, sway, bob }

    static func kind(icons: DayIcons, symbol: String) -> Kind {
        if icons == .tree { return .sway }
        return symbol == "sun.max.fill" ? .spin : .bob
    }

    static func animation(_ kind: Kind) -> CAAnimation {
        switch kind {
        case .spin:
            // One turn a minute: the rays drift.
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = 60
            a.repeatCount = .infinity
            return a
        case .sway:
            // A tree in a light wind: ±5° about its base, 3 s each way.
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 5 * Double.pi / 180
            a.toValue = -5 * Double.pi / 180
            a.duration = 3
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        case .bob:
            // Horizon and moon: rise and settle by 1 pt.
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = -0.5
            a.toValue = 0.5
            a.duration = 4
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        }
    }
}

/// Shows `content` rendered once, moving by `kind`.
struct MovingGlyph<Content: View>: View {
    let kind: DayMotion.Kind
    let key: String  // re-render the bitmap only when this changes
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
        renderer.scale = max(scale, 2)
        let image = renderer.cgImage
        let size = image.map { CGSize(width: CGFloat($0.width) / renderer.scale, height: CGFloat($0.height) / renderer.scale) } ?? .zero
        return MovingLayer(image: image, kind: kind, key: key + "\(scheme)")
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

private struct MovingLayer: NSViewRepresentable {
    let image: CGImage?
    let kind: DayMotion.Kind
    let key: String

    func makeNSView(context: Context) -> MovingNSView { MovingNSView() }

    func updateNSView(_ v: MovingNSView, context: Context) {
        v.configure(image: image, kind: kind, key: key)
    }
}

final class MovingNSView: NSView {
    private let glyph = CALayer()
    private var key = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(glyph)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(image: CGImage?, kind: DayMotion.Kind, key: String) {
        guard key != self.key else { return }
        self.key = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.contents = image
        glyph.contentsGravity = .resizeAspect
        glyph.anchorPoint = kind == .sway ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0.5, y: 0.5)
        CATransaction.commit()
        glyph.removeAllAnimations()
        glyph.add(DayMotion.animation(kind), forKey: "motion")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.bounds = bounds
        glyph.position = glyph.anchorPoint.y == 0 ? CGPoint(x: bounds.midX, y: 0) : CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
