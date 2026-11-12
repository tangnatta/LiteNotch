import SwiftUI

/// Whatever macOS reports as now playing, with large artwork and controls.
struct MusicTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    var body: some View {
        if let m = vm.media {
            playing(m)
        } else {
            empty
        }
    }

    private func playing(_ m: MediaView) -> some View {
        HStack(alignment: .center, spacing: 18) {
            ArtworkView(path: m.artworkPath, size: 150, radius: 14)
            VStack(alignment: .leading, spacing: 0) {
                VText(m.title.isEmpty ? "Unknown title" : m.title)
                    .nfont(17, .semibold).foregroundStyle(NT.text1)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !m.artist.isEmpty {
                    VText(m.artist).nfont(13).foregroundStyle(NT.text2).lineLimit(1)
                        .padding(.top, 3)
                }
                VText(subtitle(m)).nfont(11.5).foregroundStyle(NT.text3).lineLimit(1)
                    .padding(.top, 3)
                Spacer(minLength: 8)
                MediaProgress(media: m)
                if m.controllable {
                    MediaControls(media: m, size: 42, spacing: 14, send: model.send)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 150)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `Album · App`, or whichever of the two is known.
    private func subtitle(_ m: MediaView) -> String {
        [m.album, m.app].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    private var empty: some View {
        let off = !vm.settings.media.enabled
        return HStack(alignment: .center, spacing: 18) {
            ArtworkView(path: nil, size: 150, radius: 14, dimmed: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: off ? "Now playing is off" : "Nothing playing")
                    .nfont(17, .semibold).foregroundStyle(NT.text2)
                Text(verbatim: off
                     ? "Turn it on to see and control what is playing."
                     : "Anything that shows in macOS Now Playing appears here: music apps, browsers, podcasts, video.")
                    .nfont(12).foregroundStyle(NT.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if off {
                    TextPill(title: "Open Settings", height: 24) { model.openSettings(.music) }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
