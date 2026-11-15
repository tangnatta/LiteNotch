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
        case .timer: value = 62
        case .calendar: value = 62
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
    /// notch and flush with the top of the screen. The extra `notch.height`
    /// leaves room for the floating panel, which starts below the menu bar.
    public static func panelFrame(screenFrame: CGRect, notch: CGRect) -> CGRect {
        let w = expandedSize.width + 2 * panelMargin
        let h = notch.height + expandedSize.height + panelMargin
        return CGRect(x: notch.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// Where the shape sits inside a view of `bounds`: centred, top-aligned.
    public static func shapeRect(in bounds: CGSize, shape: CGSize, flipped: Bool) -> CGRect {
        CGRect(x: (bounds.width - shape.width) / 2,
               y: flipped ? 0 : bounds.height - shape.height,
               width: shape.width, height: shape.height)
    }
}

// MARK: - Floating style

extension NotchGeometry {
    /// Space between the floating capsule and the top and bottom of the menu
    /// bar (or of the notch), so the capsule is `bar − 2 × margin` tall.
    public static let floatingMargin: CGFloat = 3
    /// Width between the wings on a screen without a notch: nothing to step
    /// around, so only a little room between the two sides.
    public static let floatingCenterWidth: CGFloat = 50
    /// The floating toast overlaps the bottom of the menu bar by this much.
    public static let floatingToastLift: CGFloat = 8
    /// Gap between the bottom of the menu bar and the floating panel, so
    /// the panel reads as floating rather than hanging from the bar.
    public static let floatingPanelDrop: CGFloat = 6
    /// Space between a floating wing's content and the capsule's round end.
    public static let floatingWingPadding: CGFloat = 7
    /// Height of the floating panel's tab bar (it no longer shares a row
    /// with the notch).
    public static let floatingHeaderHeight: CGFloat = 32

    /// Width of one floating wing: narrower than the attached ones.
    public static func floatingWingWidth(for compact: CompactView) -> CGFloat {
        let icon: CGFloat = 30
        let value: CGFloat
        switch compact.kind {
        case .idle, .unknown: return 0
        // `24:59` in 12 pt semibold digits is about 36 pt.
        case .pomodoro, .caffeine, .timer, .calendar: value = 46
        // `+12:34` over time, or `Paused`.
        case .meeting: value = 52
        case .approval:
            let extra: CGFloat = compact.count > 1 ? 20 : 0
            value = textWidth(compact.value) + extra + 12
        case .media: value = icon
        case .banner, .agent:
            value = textWidth(compact.title) + 12
        }
        return min(max(icon, value), 80)
    }
}

/// What the closed notch shows: up to two running activities and the dot
/// that says an agent is waiting.
public struct ClosedContent: Equatable {
    public var primary: CompactView?
    public var secondary: CompactView?
    public var waiting: Bool

    public init(primary: CompactView?, secondary: CompactView? = nil, waiting: Bool = false) {
        let shown = primary.flatMap { $0.kind == .idle || $0.kind == .unknown ? nil : $0 }
        self.primary = shown
        // A second activity needs a first one beside it.
        self.secondary = shown == nil ? nil : secondary
        self.waiting = waiting
    }

    public init(view: ViewModel?) {
        self.init(primary: view?.compact, secondary: view?.compactSecondary, waiting: view?.waiting ?? false)
    }

    /// Nothing to draw: the bare notch.
    public var isEmpty: Bool { primary == nil && !waiting }
}

extension NotchGeometry {
    /// The waiting dot and the space before it.
    public static let waitingDot: CGFloat = 6
    public static let waitingDotSpace: CGFloat = 11
    /// Space between an icon and its value when two activities share the notch.
    public static let pairGap: CGFloat = 5

    /// Width of the value drawn after the icon when two activities share
    /// the notch; 0 when only the icon is drawn.
    public static func pairValueWidth(_ c: CompactView) -> CGFloat {
        switch c.kind {
        // `24:59` in 12 pt semibold digits is about 36 pt.
        case .pomodoro, .timer, .calendar: return 38
        // `+12:34` over time; a pause mark when paused.
        case .meeting: return c.endsAtMs != nil ? 46 : 12
        case .caffeine: return c.endsAtMs != nil ? 38 : 0
        case .media: return 18
        case .agent: return c.count > 1 ? 12 : 0
        case .idle, .approval, .banner, .unknown: return 0
        }
    }

    /// Width of one wing for what the closed notch shows. With one activity
    /// this is the width it always had; the dot adds a little.
    public static func wingWidth(for content: ClosedContent, floating: Bool) -> CGFloat {
        let dot = content.waiting ? waitingDotSpace : 0
        guard let first = content.primary else { return content.waiting ? (floating ? 12 : 20) : 0 }
        guard let second = content.secondary else {
            return (floating ? floatingWingWidth(for: first) : wingWidth(for: first)) + dot
        }
        let pad: CGFloat = floating ? floatingWingPadding : 12
        let icon: CGFloat = floating ? 16 : 18
        func slot(_ c: CompactView) -> CGFloat {
            let value = pairValueWidth(c)
            return pad + icon + (value > 0 ? pairGap + value : 0) + 4
        }
        return min(max(slot(first), slot(second) + dot), floating ? 90 : 104)
    }
}

/// Where each state sits for one panel, in either style. Pure: everything
/// it needs about the screen comes in as values.
public struct NotchLayout: Equatable {
    public var style: NotchStyle
    /// The hardware notch, or the `fallbackSize` stand-in.
    public var notch: CGSize
    public var hasNotch: Bool
    /// Height of the menu bar; 0 when it is hidden or unknown.
    public var menuBarHeight: CGFloat

    public init(style: NotchStyle, notch: CGSize, hasNotch: Bool = true, menuBarHeight: CGFloat = 0) {
        self.style = style
        self.notch = notch
        self.hasNotch = hasNotch
        self.menuBarHeight = menuBarHeight
    }

    public var floating: Bool { style == .floating }

    /// The band the floating capsule sits in: the notch, which on those
    /// Macs is as tall as the menu bar, or the menu bar itself.
    public var bar: CGFloat {
        if hasNotch { return notch.height }
        return menuBarHeight > 0 ? menuBarHeight : NotchGeometry.fallbackSize.height
    }

    /// Room between the wings.
    public var centerWidth: CGFloat {
        floating && !hasNotch ? NotchGeometry.floatingCenterWidth : notch.width
    }

    /// Height of the closed floating capsule.
    public var capsuleHeight: CGFloat { max(0, bar - 2 * NotchGeometry.floatingMargin) }

    public func wingWidth(for compact: CompactView) -> CGFloat {
        floating ? NotchGeometry.floatingWingWidth(for: compact) : NotchGeometry.wingWidth(for: compact)
    }

    public func wingWidth(for content: ClosedContent) -> CGFloat {
        NotchGeometry.wingWidth(for: content, floating: floating)
    }

    /// Size of the area the shape takes for what the closed notch shows
    /// (the other modes do not depend on it).
    public func size(for mode: NotchMode, content: ClosedContent) -> CGSize {
        guard mode == .closed else { return size(for: mode, compact: content.primary) }
        let wing = wingWidth(for: content)
        if floating {
            return CGSize(width: centerWidth + 2 * wing, height: top(for: .closed) + capsuleHeight)
        }
        return NotchGeometry.closedSize(notch: notch, wing: wing)
    }

    /// Empty space between the top of the screen and the shape; always 0
    /// when attached.
    public func top(for mode: NotchMode) -> CGFloat {
        guard floating else { return 0 }
        switch mode {
        case .closed: return NotchGeometry.floatingMargin
        case .toast: return max(0, bar - NotchGeometry.floatingToastLift)
        case .expanded: return bar + NotchGeometry.floatingPanelDrop
        }
    }

    /// Size of the area the shape takes, including the space above it.
    public func size(for mode: NotchMode, compact: CompactView?) -> CGSize {
        guard floating else { return NotchGeometry.size(for: mode, compact: compact, notch: notch) }
        switch mode {
        case .closed:
            let wing = compact.map(wingWidth(for:)) ?? 0
            return CGSize(width: centerWidth + 2 * wing, height: top(for: .closed) + capsuleHeight)
        case .toast:
            return CGSize(width: NotchGeometry.toastWidth, height: top(for: .toast) + NotchGeometry.toastExtraHeight)
        case .expanded:
            return CGSize(width: NotchGeometry.expandedSize.width,
                          height: top(for: .expanded) + NotchGeometry.expandedSize.height)
        }
    }

    /// Whether a point (from the top-left of the shape's area) takes hover
    /// and clicks. Above a floating shape only the column over the notch
    /// does, so the pointer can travel from the notch down to the shape
    /// while the rest of the menu bar stays usable.
    public func contains(_ p: CGPoint, mode: NotchMode, in size: CGSize) -> Bool {
        if p.y >= top(for: mode) { return true }
        return abs(p.x - size.width / 2) <= centerWidth / 2
    }
}
