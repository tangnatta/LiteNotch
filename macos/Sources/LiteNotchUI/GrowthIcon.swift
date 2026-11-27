import SwiftUI

/// Day progress drawn as a plant (Settings › Day › Icon: Grow a tree):
/// a seed before office hours, then two leaves, a sapling, a young tree,
/// and a full tree once they end. It never withers: the evening is not a
/// failure, the tree is simply grown.
public enum GrowthStage: Int, CaseIterable {
    case seed, leaves, sapling, youngTree, tree

    var name: String {
        switch self {
        case .seed: return "Seed"
        case .leaves: return "Two leaves"
        case .sapling: return "Sapling"
        case .youngTree: return "Young tree"
        case .tree: return "Tree"
        }
    }
}

/// The five stages, drawn on a 24-point grid with a line of soil under
/// each so they read as one family. Static: nothing here animates.
struct GrowthIcon: View {
    let stage: GrowthStage
    var size: CGFloat = 14
    var color: Color = NT.text1
    /// The soil, the plant, or both (the plant sways on its own when the
    /// icon moves, the soil stays put).
    var part: Part = .all

    enum Part { case all, ground, plant }

    /// Where the soil line is, as a fraction of the height from the bottom.
    static let groundY: CGFloat = 3.0 / 24

    var body: some View {
        Canvas { ctx, box in
            let k = box.width / 24
            // Drawn with y up, as the grid was designed.
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: k, y: -k)
            let shading = GraphicsContext.Shading.color(color)
            func line(_ p: Path, _ w: CGFloat) {
                ctx.stroke(p, with: shading, style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            if part != .plant {
                line(
                    Path {
                        $0.move(to: CGPoint(x: 4, y: 3))
                        $0.addLine(to: CGPoint(x: 20, y: 3))
                    }, 1.8)
            }
            guard part != .ground else { return }
            for (top, width) in Self.stems[stage] ?? [] {
                line(
                    Path {
                        $0.move(to: CGPoint(x: 12, y: 3))
                        $0.addLine(to: CGPoint(x: 12, y: top))
                    }, width)
            }
            ctx.fill(Self.body(stage), with: shading)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let stems: [GrowthStage: [(CGFloat, CGFloat)]] = [
        .leaves: [(13, 1.8)], .sapling: [(19, 1.8)], .youngTree: [(12, 2.2)], .tree: [(11, 2.4)],
    ]

    /// Everything filled: the seed, the leaves, the crowns.
    static func body(_ stage: GrowthStage) -> Path {
        var p = Path()
        switch stage {
        case .seed:
            p.addEllipse(
                in: CGRect(x: 9, y: 5, width: 6, height: 8),
                transform: CGAffineTransform(translationX: 12, y: 9).rotated(by: -.pi / 9).translatedBy(x: -12, y: -9))
        case .leaves:
            leaf(&p, from: CGPoint(x: 12, y: 12.5), angle: .pi * 0.18, len: 8, width: 3.4)
            leaf(&p, from: CGPoint(x: 12, y: 11), angle: .pi * 0.82, len: 7, width: 3.2)
        case .sapling:
            leaf(&p, from: CGPoint(x: 12, y: 18.5), angle: .pi * 0.42, len: 4.5, width: 2.2)
            leaf(&p, from: CGPoint(x: 12, y: 15), angle: .pi * 0.15, len: 7, width: 3)
            leaf(&p, from: CGPoint(x: 12, y: 12.5), angle: .pi * 0.85, len: 7, width: 3)
            leaf(&p, from: CGPoint(x: 12, y: 8.5), angle: .pi * 0.12, len: 5.5, width: 2.6)
        case .youngTree:
            p.addEllipse(in: CGRect(x: 6, y: 9.5, width: 8, height: 8))
            p.addEllipse(in: CGRect(x: 10, y: 9.5, width: 8, height: 8))
            p.addEllipse(in: CGRect(x: 7.5, y: 13, width: 9, height: 9))
        case .tree:
            p.addEllipse(in: CGRect(x: 3.5, y: 9, width: 10, height: 10))
            p.addEllipse(in: CGRect(x: 10.5, y: 9, width: 10, height: 10))
            p.addEllipse(in: CGRect(x: 6.5, y: 13, width: 11, height: 10))
        }
        return p
    }

    private static func leaf(_ p: inout Path, from a: CGPoint, angle: CGFloat, len: CGFloat, width: CGFloat) {
        let (dx, dy) = (cos(angle), sin(angle))
        let (nx, ny) = (-dy, dx)
        let tip = CGPoint(x: a.x + dx * len, y: a.y + dy * len)
        let mid = CGPoint(x: a.x + dx * len / 2, y: a.y + dy * len / 2)
        p.move(to: a)
        p.addCurve(
            to: tip, control1: CGPoint(x: mid.x + nx * width, y: mid.y + ny * width),
            control2: CGPoint(x: tip.x + nx * width * 0.3, y: tip.y + ny * width * 0.3))
        p.addCurve(
            to: a, control1: CGPoint(x: tip.x - nx * width * 0.3, y: tip.y - ny * width * 0.3),
            control2: CGPoint(x: mid.x - nx * width, y: mid.y - ny * width))
        p.closeSubpath()
    }
}

/// The day's icon in either style: the sun and moon symbol, or the plant.
struct DayGlyph: View {
    let icons: DayIcons
    let startMs: Int
    let endMs: Int
    let nowMs: Int
    var symbolFont: Font
    var plantSize: CGFloat
    var color: Color

    /// Settings › Day › Animate. Off: exactly the still icon, no layer.
    var motion = false

    var body: some View {
        if motion {
            moving
        } else {
            still
        }
    }

    @ViewBuilder private var moving: some View {
        let key = "\(plantSize)\(color)"
        switch icons {
        case .sun:
            let symbol = Format.daySymbol(startMs: startMs, endMs: endMs, nowMs: nowMs)
            MovingGlyph(kind: symbol == "sun.max.fill" ? .spin : .bob, key: symbol + key) { still }
        case .tree:
            let stage = Format.growthStage(startMs: startMs, endMs: endMs, nowMs: nowMs)
            ZStack {
                GrowthIcon(stage: stage, size: plantSize, color: color, part: .ground)
                MovingGlyph(kind: .sway, key: "\(stage)" + key) {
                    GrowthIcon(stage: stage, size: plantSize, color: color, part: .plant)
                }
            }
        }
    }

    @ViewBuilder private var still: some View {
        switch icons {
        case .sun:
            Image(systemName: Format.daySymbol(startMs: startMs, endMs: endMs, nowMs: nowMs))
                .font(symbolFont).foregroundStyle(color).accessibilityHidden(true)
        case .tree:
            GrowthIcon(
                stage: Format.growthStage(startMs: startMs, endMs: endMs, nowMs: nowMs),
                size: plantSize, color: color)
        }
    }
}
