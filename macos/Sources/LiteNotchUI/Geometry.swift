import CoreGraphics
import Foundation

/// How much of the notch is showing.
public enum NotchMode: Equatable {
    case closed
    /// A single-row banner below the notch.
    case toast
    case expanded
}

public enum NotchPresentation {
    public static let hoverDelay: TimeInterval = 0.15
    public static let collapseDelay: TimeInterval = 0.4

    /// Pending approvals force the full panel open. A banner alone only grows
    /// the shape into a toast, unless the user already opened the panel.
    public static func mode(expanded: Bool, view: ViewModel?) -> NotchMode {
        if expanded { return .expanded }
        guard let view else { return .closed }
        if !view.agents.pending.isEmpty { return .expanded }
        if view.inbox.banner != nil { return .toast }
        return .closed
    }
}

/// Pure layout math in AppKit screen coordinates (origin bottom-left).
public enum NotchGeometry {
    public static let fallbackSize = CGSize(width: 190, height: 32)
    /// Concave "ear" radius at the top corners, closed and open.
    public static let closedEar: CGFloat = 6
    public static let expandedEar: CGFloat = 10
    public static let closedBottomRadius: CGFloat = 10
    public static let toastBottomRadius: CGFloat = 22
    public static let expandedBottomRadius: CGFloat = 28
    public static let expandedSize = CGSize(width: 600, height: 280)
    public static let toastWidth: CGFloat = 400
    public static let toastExtraHeight: CGFloat = 44
    /// Slack around the largest state so spring overshoot is never clipped.
    public static let panelMargin: CGFloat = 24

    /// The notch rectangle, or a centred pill when the screen has no notch.
    public static func notchRect(screenFrame: CGRect, safeAreaTop: CGFloat,
                                 leftAux: CGRect?, rightAux: CGRect?) -> CGRect {
        // Only the widths of the side areas are used, so the result does not
        // depend on which coordinate space AppKit reports them in.
        if safeAreaTop > 0, let l = leftAux, let r = rightAux {
            let width = screenFrame.width - l.width - r.width
            if width > 0 {
                return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - safeAreaTop,
                              width: width, height: safeAreaTop)
            }
        }
        let s = fallbackSize
        return CGRect(x: screenFrame.midX - s.width / 2, y: screenFrame.maxY - s.height,
                      width: s.width, height: s.height)
    }

    /// Width of one wing beside the notch for an activity. Wings are
    /// symmetric so the notch stays centred in the shape.
    public static func wingWidth(for compact: CompactView) -> CGFloat {
        let icon: CGFloat = 40
        let value: CGFloat
        switch compact.kind {
        case .idle, .unknown: return 0
        case .pomodoro: value = 62
        case .caffeine: value = 62
        // `+12:34` over time, or `Paused`.
        case .meeting: value = 66
        case .approval:
            let extra: CGFloat = compact.count > 1 ? 22 : 0
            value = textWidth(compact.value) + extra + 18
        // Artwork on one side, equaliser on the other; no text, like the
        // iPhone island.
        case .media: value = icon
        case .banner:
            value = textWidth(compact.title) + 18
        case .agent:
            value = textWidth(compact.title) + 18
        }
        return min(max(icon, value), 130)
    }

    private static func textWidth(_ s: String) -> CGFloat {
        CGFloat(min(s.count, 18)) * 6.4
    }

    public static func closedSize(notch: CGSize, wing: CGFloat) -> CGSize {
        CGSize(width: notch.width + 2 * closedEar + 2 * wing, height: notch.height)
    }

    public static func toastSize(notch: CGSize) -> CGSize {
        CGSize(width: max(toastWidth, notch.width + 2 * closedEar), height: notch.height + toastExtraHeight)
    }

    public static func size(for mode: NotchMode, compact: CompactView?, notch: CGSize) -> CGSize {
        switch mode {
        case .closed:
            return closedSize(notch: notch, wing: compact.map(wingWidth(for:)) ?? 0)
        case .toast: return toastSize(notch: notch)
        case .expanded: return expandedSize
        }
    }

    /// The window frame: large enough for the biggest state, centred on the
    /// notch and flush with the top of the screen.
    public static func panelFrame(screenFrame: CGRect, notch: CGRect) -> CGRect {
        let w = expandedSize.width + 2 * panelMargin
        let h = expandedSize.height + panelMargin
        return CGRect(x: notch.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// Where the shape sits inside a view of `bounds`: centred, top-aligned.
    public static func shapeRect(in bounds: CGSize, shape: CGSize, flipped: Bool) -> CGRect {
        CGRect(x: (bounds.width - shape.width) / 2,
               y: flipped ? 0 : bounds.height - shape.height,
               width: shape.width, height: shape.height)
    }
}
