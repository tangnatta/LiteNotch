import AppKit
import SwiftUI

/// `#RRGGBB` parsing, formatting and contrast; pure so it can be unit tested.
public enum ColorMath {
    public struct RGB: Equatable {
        public var r: Double, g: Double, b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// `#rrggbb` or `rrggbb` (any case, surrounding spaces allowed); nil otherwise.
    public static func parse(_ s: String) -> RGB? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, t.allSatisfy(\.isHexDigit), let v = UInt32(t, radix: 16) else { return nil }
        return RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    /// Upper-case `#RRGGBB`; components are clamped to 0...1.
    public static func hex(_ c: RGB) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
    }

    /// Normalised `#RRGGBB`, or nil when `s` is not a colour.
    public static func normalize(_ s: String) -> String? { parse(s).map(hex) }

    /// sRGB `#RRGGBB` of any AppKit colour (the screen sampler returns the
    /// display's colour space); nil for pattern or catalog colours that
    /// cannot be converted.
    public static func hex(of color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return hex(RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)))
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio between two colours, 1 to 21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fg` drawn with `alpha` over an opaque `bg` (sRGB-space blending,
    /// which is what AppKit does).
    public static func over(_ fg: RGB, alpha: Double, _ bg: RGB) -> RGB {
        let a = min(max(alpha, 0), 1)
        return RGB(r: fg.r * a + bg.r * (1 - a), g: fg.g * a + bg.g * (1 - a), b: fg.b * a + bg.b * (1 - a))
    }

    /// True when black text reads better than white on this background:
    /// the luminance where both have the same contrast ratio is about 0.179.
    public static func prefersDarkText(on c: RGB) -> Bool {
        luminance(c) > 0.179
    }
}

/// Accent swatches offered in Settings › General; the first is the default.
/// Few on purpose: the system accent, black/white and the hue strip cover
/// the rest.
public enum AccentPresets {
    public static let all = ["#FF9E0A", "#0A84FF", "#30D158", "#FF375F"]
}

/// What `appearance.accent` asks for; mirrors `normalize_accent` in the core.
public enum AccentChoice: Equatable {
    /// The accent chosen in System Settings › Appearance.
    case system
    /// White on a dark panel, black on a light one.
    case mono
    /// `#RRGGBB`.
    case color(String)

    public init(_ raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "system": self = .system
        case "mono": self = .mono
        default: self = .color(ColorMath.normalize(raw) ?? AppearanceConfig.defaultAccent)
        }
    }

    /// The settings string.
    public var raw: String {
        switch self {
        case .system: return "system"
        case .mono: return "mono"
        case .color(let hex): return hex
        }
    }

    /// A colour that is none of the preset swatches.
    public var isCustom: Bool {
        if case .color(let hex) = self { return !AccentPresets.all.contains(hex) }
        return false
    }
}

extension ColorMath {
    /// Saturation of colours picked on the hue strip: vivid, but not so
    /// pure that text on them is hard to read.
    public static let stripSaturation = 0.85

    /// The colour at `hue` (0...1 around the wheel) on the hue strip.
    public static func fromHue(_ hue: Double) -> RGB {
        let h = (hue - floor(hue)) * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        let m = 1 - stripSaturation
        return RGB(r: r * stripSaturation + m, g: g * stripSaturation + m, b: b * stripSaturation + m)
    }

    /// Where on the hue strip a colour sits, 0..<1; 0 for a grey.
    public static func hue(of c: RGB) -> Double {
        let hi = max(c.r, c.g, c.b)
        let lo = min(c.r, c.g, c.b)
        let d = hi - lo
        guard d > 1e-9 else { return 0 }
        var h: Double
        if hi == c.r {
            h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)
        } else if hi == c.g {
            h = (c.b - c.r) / d + 2
        } else {
            h = (c.r - c.g) / d + 4
        }
        h /= 6
        return h < 0 ? h + 1 : h
    }
}
