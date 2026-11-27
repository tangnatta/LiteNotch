import AppKit
import SwiftUI

/// The day icon moving (Settings › Day › Animate, `day.motion`). The
/// glyph is drawn once into a bitmap and a Core Animation layer moves that
/// bitmap (the rule for anything that moves continuously), so SwiftUI
/// never redraws per frame.
enum DayMotion {
    enum Kind { case spin, sway, bob }

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
        let s = max(scale, 2)
        let id = "\(key)|\(scheme)|\(s)"
        let image = GlyphCache.image(id) {
            let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
            renderer.scale = s
            return renderer.cgImage
        }
        let size = image.map { CGSize(width: CGFloat($0.width) / s, height: CGFloat($0.height) / s) } ?? .zero
        return MovingLayer(image: image, kind: kind, key: id)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

/// Bitmaps already drawn, by glyph, colour scheme and scale. The body runs
/// on every SwiftUI update (each minute on Home, every percent in the
/// notch); drawing the glyph again each time cost an `ImageRenderer` pass
/// for nothing. A day has at most a handful of glyphs.
@MainActor
private enum GlyphCache {
    private static var images: [String: CGImage] = [:]

    static func image(_ id: String, draw: () -> CGImage?) -> CGImage? {
        if let hit = images[id] { return hit }
        guard let made = draw() else { return nil }
        if images.count >= 32 { images.removeAll() }
        images[id] = made
        return made
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
        // The tree sways about the soil line.
        glyph.anchorPoint = CGPoint(x: 0.5, y: kind == .sway ? GrowthIcon.groundY : 0.5)
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
        glyph.position = CGPoint(x: bounds.midX, y: bounds.height * glyph.anchorPoint.y)
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
