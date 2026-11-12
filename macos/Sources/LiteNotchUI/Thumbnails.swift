import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// Downsampled previews of copied images and files, decoded off the main
/// thread and kept in a small cache. Snapshots never load anything.
enum Thumbnails {
    static let rowPixels = 128
    static let previewPixels = 720

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 48
        return c
    }()

    private static func key(_ path: String, _ px: Int) -> NSString { "\(px)|\(path)" as NSString }

    /// Main thread.
    static func cached(_ path: String, px: Int) -> NSImage? {
        cache.object(forKey: key(path, px))
    }

    /// The image file `path` scaled so its longer side is at most `px`.
    static func image(at path: String, px: Int) async -> NSImage? {
        if let hit = await MainActor.run(body: { cached(path, px: px) }) { return hit }
        let cg = await Task.detached(priority: .utility) { downsample(path, px: px) }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        await MainActor.run { cache.setObject(image, forKey: key(path, px)) }
        return image
    }

    /// Quick Look's thumbnail for any file (images, video, PDF, documents).
    static func file(at path: String, px: Int) async -> NSImage? {
        if let hit = await MainActor.run(body: { cached(path, px: px) }) { return hit }
        let side = CGFloat(px) / 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = rep.nsImage
        await MainActor.run { cache.setObject(image, forKey: key(path, px)) }
        return image
    }

    /// Pixel size of an image file without decoding it.
    static func pixelSize(at path: String) async -> CGSize? {
        await Task.detached(priority: .utility) { () -> CGSize? in
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return CGSize(width: w, height: h)
        }.value
    }

    private static func downsample(_ path: String, px: Int) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, opts) else { return nil }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary)
    }

    /// The file to preview for a clip, if it has one.
    static func source(of item: ClipView) -> (path: String, isImage: Bool)? {
        switch item.kind {
        case .image:
            guard let p = item.imagePath, !p.isEmpty else { return nil }
            return (p, true)
        case .files:
            guard let p = item.files.first, !p.isEmpty else { return nil }
            return (p, false)
        case .text, .unknown:
            return nil
        }
    }

    static func load(_ source: (path: String, isImage: Bool), px: Int) async -> NSImage? {
        source.isImage ? await image(at: source.path, px: px) : await file(at: source.path, px: px)
    }
}

/// A clip's thumbnail: a placeholder at once (the file's Finder icon, or a
/// photo glyph), the real preview when it has loaded.
struct ClipThumb: View {
    let source: (path: String, isImage: Bool)
    var size: CGFloat = 34
    var radius: CGFloat = 6
    var px: Int = Thumbnails.rowPixels
    var fit = false

    @Environment(\.isSnapshot) private var snapshot
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else if source.isImage {
                ZStack {
                    NT.fill
                    Image(systemName: "photo").font(.system(size: min(size * 0.4, 28), weight: .medium))
                        .foregroundStyle(NT.text3)
                }
            } else {
                // Synchronous and cheap; also the fallback when Quick Look has nothing.
                Image(nsImage: NSWorkspace.shared.icon(forFile: source.path)).resizable()
                    .aspectRatio(contentMode: .fit).padding(size * 0.08)
            }
        }
        .frame(width: fit ? nil : size, height: fit ? nil : size)
        .frame(maxWidth: fit ? .infinity : nil, maxHeight: fit ? .infinity : nil)
        .clipShape(shape)
        .overlay(fit ? nil : shape.strokeBorder(NT.hairline, lineWidth: 0.5))
        .task(id: "\(px)|\(source.path)") {
            guard !snapshot else { return }
            if let hit = Thumbnails.cached(source.path, px: px) { image = hit; return }
            image = nil
            image = await Thumbnails.load(source, px: px)
        }
        .accessibilityHidden(true)
    }
}

/// A larger look at one clip, shown in place of the list.
struct ClipPreview: View {
    let item: ClipView
    let source: (path: String, isImage: Bool)
    let copy: () -> Void
    let close: () -> Void

    @Environment(\.isSnapshot) private var snapshot
    @State private var pixels: CGSize?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button(action: close) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text(verbatim: "Back").nfont(11.5, .medium)
                    }
                    .foregroundStyle(NT.text1)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(NT.fill, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Back to the list"))
                VText(caption).nfont(11.5).foregroundStyle(NT.text2).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                TextPill(title: "Copy", tint: NT.onAccent, background: NT.accent, height: 24, weight: .semibold,
                         action: copy)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NT.fill)
                ClipThumb(source: source, size: 120, radius: 8, px: Thumbnails.previewPixels, fit: true)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: 220)
        }
        .task(id: source.path) {
            guard !snapshot, source.isImage else { return }
            pixels = await Thumbnails.pixelSize(at: source.path)
        }
    }

    private var caption: String {
        if source.isImage {
            guard let p = pixels else { return item.sourceApp ?? "Image" }
            let dims = "\(Int(p.width)) \u{00D7} \(Int(p.height))"
            return [dims, item.sourceApp ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        }
        let name = (item.files.first.map { ($0 as NSString).lastPathComponent }) ?? item.preview
        return item.files.count > 1 ? "\(name) +\(item.files.count - 1) more" : name
    }
}
