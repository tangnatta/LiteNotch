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
                    .nfont(.heading).foregroundStyle(NT.text1)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                // Artist on the left, the player on the right; the album
                // gets its own quieter line.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VText(m.artist.isEmpty ? m.album : m.artist).nfont(.body).foregroundStyle(NT.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    if !m.app.isEmpty {
                        VText(m.app).nfont(.caption).foregroundStyle(NT.text3).lineLimit(1).fixedSize()
                    }
                }
                .padding(.top, 3)
                if !m.artist.isEmpty && !m.album.isEmpty {
                    VText(m.album).nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
                        .padding(.top, 2)
                }
                if !m.controllable {
                    Text(verbatim: MediaText.notControllable).nfont(.caption).foregroundStyle(NT.text3)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
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

    private var empty: some View {
        let off = !vm.settings.media.enabled
        return HStack(alignment: .center, spacing: 18) {
            ArtworkView(path: nil, size: 150, radius: 14, dimmed: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: off ? "Now playing is off" : "Nothing playing")
                    .nfont(.heading).foregroundStyle(NT.text2)
                Text(verbatim: off
                     ? "Turn it on to see and control what\u{2019}s playing."
                     : "Play something in Music, Spotify or a browser and it shows up here.")
                    .nfont(.body).foregroundStyle(NT.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if off {
                    TextPill(title: "Turn on in Settings", height: 24) { model.openSettings(.music) }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum MediaText {
    static let notControllable = "This app doesn\u{2019}t accept controls from LiteNotch."
}
