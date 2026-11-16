import SwiftUI

/// The pomodoro's tomato, drawn from shapes (SF Symbols has none, and the
/// emoji differs between macOS versions). `tint` nil draws it ripe: red
/// with green leaves; a tint draws the whole silhouette in that colour.
struct TomatoIcon: View {
    var size: CGFloat
    var tint: Color?

    static let red = Color(red: 0.91, green: 0.33, blue: 0.24)
    static let leaf = Color(red: 0.36, green: 0.75, blue: 0.29)

    var body: some View {
        ZStack {
            TomatoBody().fill(tint ?? Self.red)
            TomatoLeaves().fill(tint ?? Self.leaf)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shapes in a 24 x 24 frame, scaled to the rect.
private func scaled(_ rect: CGRect, _ build: (inout Path) -> Void) -> Path {
    var p = Path()
    build(&p)
    let k = min(rect.width, rect.height) / 24
    return p.applying(CGAffineTransform(scaleX: k, y: k)
        .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
}

private struct TomatoBody: Shape {
    func path(in rect: CGRect) -> Path {
        scaled(rect) { $0.addEllipse(in: CGRect(x: 2.5, y: 5.5, width: 19, height: 17)) }
    }
}

private struct TomatoLeaves: Shape {
    func path(in rect: CGRect) -> Path {
        scaled(rect) { p in
            let c = CGPoint(x: 12, y: 7.2)
            p.move(to: c)
            p.addCurve(to: CGPoint(x: 5.6, y: 8.2), control1: CGPoint(x: 9.6, y: 5.2),
                       control2: CGPoint(x: 6.6, y: 5.8))
            p.addCurve(to: c, control1: CGPoint(x: 8.2, y: 7.8), control2: CGPoint(x: 10.4, y: 8.0))
            p.move(to: c)
            p.addCurve(to: CGPoint(x: 18.4, y: 8.2), control1: CGPoint(x: 14.4, y: 5.2),
                       control2: CGPoint(x: 17.4, y: 5.8))
            p.addCurve(to: c, control1: CGPoint(x: 15.8, y: 7.8), control2: CGPoint(x: 13.6, y: 8.0))
            p.addRoundedRect(in: CGRect(x: 11.1, y: 1.8, width: 1.8, height: 5.6),
                             cornerSize: CGSize(width: 0.9, height: 0.9))
        }
    }
}
