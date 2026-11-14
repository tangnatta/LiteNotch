import SwiftUI

/// Liquid Glass (macOS 26) for the open panel.
///
/// Two gates: the build must use the macOS 26 SDK (Swift 6.2 or later, which
/// ships with it), and the system must be macOS 26 or later. A build made
/// with an older SDK never draws glass and Settings says why; the setting is
/// kept, so the same saved file shows glass once a newer build runs.
///
/// Only the open panel uses it. The closed notch and the toast stay black so
/// they blend with the hardware notch (glass there would show a black
/// cut-out in a translucent band, and its edge highlight would outline the
/// camera housing).
public enum GlassSupport {
    /// The build has the API.
    public static var compiled: Bool {
        #if compiler(>=6.2)
        return true
        #else
        return false
        #endif
    }

    /// The build has the API and the system can draw it.
    public static var available: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// Why the Glass choice is off, or nil when it can be used.
    public static var unavailableReason: String? {
        if available { return nil }
        if !compiled { return "This build was made without the macOS 26 SDK." }
        return "Needs macOS 26 or later."
    }
}

/// The open panel's background: the theme's solid colour, or Liquid Glass
/// (Frosted, untinted).
struct PanelFill<S: Shape>: View {
    let shape: S
    let glass: Bool

    var body: some View {
        #if compiler(>=6.2)
        if glass, #available(macOS 26, *) {
            // A static material: the window server samples and refracts
            // what is behind it, and SwiftUI does not re-render when that
            // changes. Glass over moving content (video) still costs GPU
            // compositing; not measured yet.
            // Frosted (`regular`) and untinted: the system adapts it to what is
            // behind, and applies the user's own system-wide glass setting.
            // The window server hands events over fully transparent pixels to
            // the window behind, and the glass leaves the window's own pixels
            // at alpha 0, so a scroll on an empty part of the panel scrolled
            // the app underneath. A fill too faint to see keeps them.
            shape.fill(Color.black.opacity(0.01))
                .glassEffect(.regular, in: shape)
        } else {
            shape.fill(NT.panel)
        }
        #else
        shape.fill(NT.panel)
        #endif
    }
}
