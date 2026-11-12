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
        await MainActor.run { self.path = path; image = img }
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
            IconButton(symbol: "backward.fill", label: "Previous", size: size * 0.42, tint: NT.text1,
                       frame: size) { send(.media(.previous)) }
            Button { send(.media(.playPause)) } label: {
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
            IconButton(symbol: "forward.fill", label: "Next", size: size * 0.42, tint: NT.text1,
                       frame: size) { send(.media(.next)) }
        }
    }
}
