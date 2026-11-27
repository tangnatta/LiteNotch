import AppKit
import SwiftUI

/// The sky behind Home's day card with the Default (sun) icons: a still,
/// grainy gradient that follows `Format.daySymbol`'s four parts of the day.
/// It changes only when the part of the day does; nothing moves.
enum SkyPhase: Equatable {
    case morning, day, evening, night

    static func at(startMs: Int, endMs: Int, nowMs: Int) -> SkyPhase {
        if nowMs < startMs { return .morning }
        if nowMs < Format.daySymbolChanges(startMs: startMs, endMs: endMs)[1] { return .day }
        if nowMs < endMs { return .evening }
        return .night
    }

    /// Top to bottom.
    var colors: [Color] {
        switch self {
        case .morning: [Color(red: 0.42, green: 0.62, blue: 0.86), Color(red: 0.98, green: 0.72, blue: 0.52)]
        case .day: [Color(red: 0.16, green: 0.45, blue: 0.85), Color(red: 0.45, green: 0.70, blue: 0.95)]
        case .evening: [Color(red: 0.36, green: 0.30, blue: 0.58), Color(red: 0.96, green: 0.52, blue: 0.28)]
        case .night: [Color(red: 0.04, green: 0.05, blue: 0.14), Color(red: 0.12, green: 0.14, blue: 0.30)]
        }
    }
}

struct DaySky: View {
    let phase: SkyPhase
    var body: some View {
        LinearGradient(colors: phase.colors, startPoint: .top, endPoint: .bottom)
            .overlay(Rectangle().fill(ImagePaint(image: Image(nsImage: Grain.tile), scale: 0.5)))
            .opacity(0.5)
            .accessibilityHidden(true)
    }
}

/// One 128 px tile of grey grain, made once and tiled.
private enum Grain {
    static let tile: NSImage = {
        let n = 128
        var state: UInt32 = 0x9E37_79B9
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            let v = UInt8(truncatingIfNeeded: state)
            let a: UInt8 = 22  // faint
            let c = UInt8((Int(v) * Int(a)) / 255)  // premultiplied
            bytes[i * 4] = c
            bytes[i * 4 + 1] = c
            bytes[i * 4 + 2] = c
            bytes[i * 4 + 3] = a
        }
        let rep = bytes.withUnsafeMutableBufferPointer { buf -> NSBitmapImageRep? in
            var base: UnsafeMutablePointer<UInt8>? = buf.baseAddress
            return NSBitmapImageRep(
                bitmapDataPlanes: &base, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: n * 4, bitsPerPixel: 32)?.copy() as? NSBitmapImageRep
        }
        let img = NSImage(size: NSSize(width: n, height: n))
        if let rep { img.addRepresentation(rep) }
        return img
    }()
}
