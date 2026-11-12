import AppKit
import SwiftUI

/// Keeps the current track's artwork decoded. One entry is enough: only one
/// thing plays at a time, and the path changes whenever the art does.
enum ArtworkCache {
    private static var path: String?
    private static var image: NSImage?

    /// Main thread only (called from view bodies).
    static func image(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if path == self.path { return image }
        self.path = path
        image = NSImage(contentsOfFile: path)
        return image
    }
}

/// Album art, or a quiet gradient with a note when there is none.
struct ArtworkView: View {
    let path: String?
    let size: CGFloat
    let radius: CGFloat
    var dimmed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image = ArtworkCache.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [NT.text1.opacity(dimmed ? 0.10 : 0.20),
                                            NT.text1.opacity(dimmed ? 0.04 : 0.07)],
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
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(NT.text3)
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
            IconButton(symbol: "backward.fill", label: "Previous", size: size * 0.42, tint: NT.text1,
                       frame: size) { send(.media(.previous)) }
            Button { send(.media(.playPause)) } label: {
                Image(systemName: media.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(NT.panel)
                    .frame(width: size, height: size)
                    .background(NT.text1, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: media.playing ? "Pause" : "Play"))
            IconButton(symbol: "forward.fill", label: "Next", size: size * 0.42, tint: NT.text1,
                       frame: size) { send(.media(.next)) }
        }
    }
}
