import AppKit
import SwiftUI

/// The current track's artwork, downsampled off the main thread. One entry
/// is enough: only one thing plays at a time, and the path changes whenever
/// the art does.
enum ArtworkCache {
    /// Longest side kept in memory; the largest place it is drawn is 150 pt.
    static let pixels = 300

    @MainActor private static var path: String?
    @MainActor private static var image: NSImage?

    @MainActor static func cached(_ path: String?) -> NSImage? {
        guard let path, path == self.path else { return nil }
        return image
    }

    /// Decodes `path` at `pixels` on a background thread. Files over
    /// `Thumbnails.maxSourceSide` pixels on a side are refused unread.
    static func load(_ path: String?) async -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let hit = await cached(path) { return hit }
        let cg = await Task.detached(priority: .utility) {
            Thumbnails.downsample(path, px: pixels, maxSourceSide: Thumbnails.maxSourceSide)
        }.value
        let img = cg.map { NSImage(cgImage: $0, size: .zero) }
        await MainActor.run {
            self.path = path
            image = img
        }
        return img
    }

    /// Snapshots only: the same decode, on the calling thread.
    @MainActor static func loadNow(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        return Thumbnails.downsample(path, px: pixels, maxSourceSide: Thumbnails.maxSourceSide)
            .map { NSImage(cgImage: $0, size: .zero) }
    }
}

/// Album art, or a quiet gradient with a note when there is none.
struct ArtworkView: View {
    let path: String?
    let size: CGFloat
    let radius: CGFloat
    var dimmed = false
    @Environment(\.isSnapshot) private var snapshot
    @State private var loaded: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let image = snapshot ? ArtworkCache.loadNow(path) : (loaded ?? ArtworkCache.cached(path))
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            NT.text1.opacity(dimmed ? 0.10 : 0.20),
                            NT.text1.opacity(dimmed ? 0.04 : 0.07),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.40, weight: .semibold))
                        .foregroundStyle(dimmed ? NT.text3 : NT.text2)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(NT.hairline, lineWidth: size >= 40 ? 1 : 0.5))
        .task(id: path) {
            guard !snapshot else { return }
            loaded = await ArtworkCache.load(path)
        }
        .accessibilityHidden(true)
    }
}

/// Track progress, extrapolated once a second while playing. The view model
/// only carries the position at one instant.
struct MediaProgress: View {
    let media: MediaView
    var showTimes = true
    var height: CGFloat = 4

    var body: some View {
        if media.durationMs != nil, media.positionMs != nil {
            if media.playing {
                EverySecond { now in bar(now: now) }
            } else {
                bar(now: media.positionAtMs)
            }
        }
    }

    private func bar(now: Int) -> some View {
        let pos = Format.mediaPosition(media, nowMs: now) ?? 0
        let dur = media.durationMs ?? 0
        return VStack(spacing: 4) {
            ProgressBar(value: dur > 0 ? Double(pos) / Double(dur) : 0, height: height)
            if showTimes {
                HStack {
                    Text(verbatim: Format.clock(ms: pos))
                    Spacer()
                    Text(verbatim: Format.clock(ms: dur))
                }
                .nfont(.caption).monospacedDigit().foregroundStyle(NT.text3)
            }
        }
    }
}

/// Previous / play-pause / next.
struct MediaControls: View {
    let media: MediaView
    /// Diameter of the play button; the side buttons scale with it.
    var size: CGFloat = 30
    var spacing: CGFloat = 4
    let send: (ShellCommand) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            IconButton(
                symbol: "backward.fill", label: "Previous", size: size * 0.42, tint: NT.text1,
                frame: size
            ) { send(.media(.previous)) }
            Button {
                send(.media(.playPause))
            } label: {
                Image(systemName: media.playing ? "pause.fill" : "play.fill")
                    .glyph(size * 0.42, .bold).foregroundStyle(NT.panel)
                    .frame(width: size, height: size)
                    .background(NT.text1, in: Circle())
                    .contentShape(Circle())
                    .controlHover(Circle())
            }
            .buttonStyle(.plain)
            .help(media.playing ? "Pause" : "Play")
            .accessibilityLabel(Text(verbatim: media.playing ? "Pause" : "Play"))
            IconButton(
                symbol: "forward.fill", label: "Next", size: size * 0.42, tint: NT.text1,
                frame: size
            ) { send(.media(.next)) }
        }
    }
}

// MARK: - Progress ring

/// The closed notch's artwork. With the progress ring on and a track length
/// known, the artwork sits inside a ring that fills as the song plays. The
/// ring takes its space from the artwork, not from the layout: the whole
/// thing is `size` wide, so nothing around it moves.
struct ClosedArtwork: View {
    let path: String?
    let size: CGFloat
    /// Island: round. Attached: a rounded square.
    let round: Bool
    var media: MediaView?

    /// Ring line and the gap between it and the artwork.
    static let line: CGFloat = 1.5
    static let gap: CGFloat = 1
    static var inset: CGFloat { line + gap }

    var body: some View {
        if let media, media.durationMs != nil, media.positionMs != nil {
            let art = size - 2 * Self.inset
            let artRadius = round ? art / 2 : art / 4
            ZStack {
                ProgressRing(media: media, radius: artRadius + Self.inset, line: Self.line)
                    .frame(width: size, height: size)
                ArtworkView(path: path, size: art, radius: artRadius)
            }
            .frame(width: size, height: size)
        } else {
            ArtworkView(path: path, size: size, radius: round ? size / 2 : size / 4)
        }
    }
}

/// A rounded square (a circle when `radius` is half the side) drawn from the
/// top, clockwise, so `trim` fills it the way a progress ring does.
struct RingShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        p.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        p.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        p.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// How far through the track, 0...1, at `nowMs`.
func mediaFraction(_ media: MediaView, nowMs: Int) -> Double {
    guard let dur = media.durationMs, dur > 0,
        let pos = Format.mediaPosition(media, nowMs: nowMs)
    else { return 0 }
    return min(1, max(0, Double(pos) / Double(dur)))
}

/// The ring itself. Like the equaliser bars it moves by a Core Animation
/// the window server runs (one animation from where the song is to its end),
/// never a SwiftUI animation or a timer: those would re-render the notch.
struct ProgressRing: View {
    let media: MediaView
    /// Outer corner radius of the ring.
    let radius: CGFloat
    let line: CGFloat
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.clockOffsetMs) private var offset
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let now = nowMs(Date(), offset: offset)
        if snapshot {
            ZStack {
                RingShape(radius: radius - line / 2).stroke(NT.text1.opacity(0.2), lineWidth: line)
                RingShape(radius: radius - line / 2)
                    .trim(from: 0, to: mediaFraction(media, nowMs: now))
                    .stroke(NT.accentText, lineWidth: line)
            }
            .padding(line / 2)
        } else {
            ProgressRingLayer(
                media: media, nowMs: now, radius: radius, line: line,
                fill: NSColor(NT.accentText).resolved(dark: scheme == .dark),
                track: NSColor(NT.text1).resolved(dark: scheme == .dark).copy(alpha: 0.2) ?? .clear)
        }
    }
}

private struct ProgressRingLayer: NSViewRepresentable {
    let media: MediaView
    let nowMs: Int
    let radius: CGFloat
    let line: CGFloat
    let fill: CGColor
    let track: CGColor

    func makeNSView(context: Context) -> ProgressRingNSView { ProgressRingNSView(frame: .zero) }

    func updateNSView(_ view: ProgressRingNSView, context: Context) {
        view.configure(media: media, nowMs: nowMs, radius: radius, line: line, fill: fill, track: track)
    }
}

final class ProgressRingNSView: NSView {
    private let trackLayer = CAShapeLayer()
    let fillLayer = CAShapeLayer()
    private var radius: CGFloat = 0
    private var line: CGFloat = 0
    /// What the running animation was made from. SwiftUI calls `configure`
    /// on every redraw of the notch; only a new position, play state or
    /// track length starts the animation again.
    private var anchor: [Int]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [trackLayer, fillLayer] {
            l.fillColor = nil
            l.lineCap = .butt
            layer?.addSublayer(l)
        }
        fillLayer.strokeEnd = 0
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks go through to the notch, which opens on a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(media: MediaView, nowMs: Int, radius: CGFloat, line: CGFloat, fill: CGColor, track: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        fillLayer.strokeColor = fill
        trackLayer.strokeColor = track
        if radius != self.radius || line != self.line {
            self.radius = radius
            self.line = line
            needsLayout = true
        }
        let key = [media.positionMs ?? -1, media.positionAtMs, media.durationMs ?? -1, media.playing ? 1 : 0]
        guard key != anchor else { return }
        anchor = key

        let start = mediaFraction(media, nowMs: nowMs)
        fillLayer.removeAnimation(forKey: "progress")
        let dur = media.durationMs ?? 0
        let left = Double(dur) * (1 - start) / 1000
        if media.playing, left > 0.05 {
            fillLayer.strokeEnd = 1
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = start
            a.toValue = 1
            a.duration = left
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            fillLayer.add(a, forKey: "progress")
        } else {
            fillLayer.strokeEnd = start
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The line is centred on the path, so the path sits half a line in.
        let rect = bounds.insetBy(dx: line / 2, dy: line / 2)
        let shape = RingShape(radius: radius - line / 2).path(in: rect)
        // The layer's y axis points up; the shape was drawn with it down.
        var flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -bounds.height)
        let cg = shape.cgPath.copy(using: &flip)
        for l in [trackLayer, fillLayer] {
            l.frame = bounds
            l.lineWidth = line
            l.path = cg
        }
        CATransaction.commit()
    }
}
