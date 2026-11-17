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
    /// The shrunk closed notch on a screen without a notch
    /// (`appearance.shrink`): a thin strip flush with the top edge, only
    /// there to show where the notch is.
    public static let minimizedSize = CGSize(width: 120, height: 8)
    public static let minimizedEar: CGFloat = 4
    public static let minimizedBottomRadius: CGFloat = 4

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
        switch compact.peek {
        // Room for the scrolling title.
        case .trackChanged: return 130
        // `4:59 left`.
        case .timeWarning: return 82
        // A symbol on one side, the scrolling line on the other. The eye
        // break's short line takes the `.nudge` width below.
        case .move, .quote, .stillWorking: return 130
        case .eyeBreak, .unknown, nil: break
        }
        switch compact.kind {
        case .idle, .unknown: return 0
        case .nudge: value = textWidth(compact.value) + 18
        case .pomodoro: value = 62
        case .caffeine: value = 62
        // `+12:34` over time, or `Paused`.
        case .meeting: value = 66
        case .timer: value = 62
        case .calendar: value = 62
        // Icon and `−125%` side by side on the left.
        case .day: value = 78
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

    private static func textWidth(_ s: String, chars: Int = 18) -> CGFloat {
        CGFloat(min(s.count, chars)) * 6.4
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
    /// leaves room for the island panel, which starts below the menu bar.
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

// MARK: - Island style

extension NotchGeometry {
    /// Space between the island capsule and the top and bottom of the menu
    /// bar (or of the notch), so the capsule is `bar − 2 × margin` tall.
    public static let islandMargin: CGFloat = 3
    /// Width between the wings on a screen without a notch: nothing to step
    /// around, so only a little room between the two sides.
    public static let islandCenterWidth: CGFloat = 50
    /// The island toast overlaps the bottom of the menu bar by this much.
    public static let islandToastLift: CGFloat = 8
    /// Gap between the bottom of the menu bar and the island panel, so
    /// the panel reads as island rather than hanging from the bar.
    public static let islandPanelDrop: CGFloat = 6
    /// Space between an island wing's content and the capsule's round end.
    public static let islandWingPadding: CGFloat = 7
    /// Height of the island panel's tab bar (it no longer shares a row
    /// with the notch).
    public static let islandHeaderHeight: CGFloat = 32

    /// Width of one island wing: narrower than the attached ones.
    public static func islandWingWidth(for compact: CompactView) -> CGFloat {
        let icon: CGFloat = 30
        let value: CGFloat
        switch compact.peek {
        case .trackChanged: return 80
        // `10:00 left` with the capsule's padding.
        case .timeWarning: return 72
        case .move, .quote, .stillWorking: return 80
        case .eyeBreak, .unknown, nil: break
        }
        switch compact.kind {
        case .idle, .unknown: return 0
        case .nudge: value = textWidth(compact.value) + 12
        // `24:59` in 12 pt semibold digits is about 36 pt.
        case .pomodoro, .caffeine, .timer, .calendar: value = 46
        // Icon and `−125%` side by side on the left.
        case .day: value = 72
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
    /// Width of each wing when the dot is all there is to show beside a
    /// notch. The camera housing is a little wider than the notch macOS
    /// reports and its corners are round, so the dot needs clear space
    /// between it and the housing as well as its padding at the outer end.
    public static let loneDotWing: CGFloat = 34
    /// Space between an icon and its value when two activities share the notch.
    public static let pairGap: CGFloat = 5

    /// Width of the value drawn after the icon when two activities share
    /// the notch; 0 when only the icon is drawn.
    public static func pairValueWidth(_ c: CompactView) -> CGFloat {
        switch c.kind {
        // `24:59` in 12 pt semibold digits is about 36 pt.
        case .pomodoro, .timer, .calendar: return 38
        case .day: return 44
        // `+12:34` over time; a pause mark when paused.
        case .meeting: return c.endsAtMs != nil ? 46 : 12
        case .caffeine: return c.endsAtMs != nil ? 38 : 0
        case .media: return 18
        case .agent: return c.count > 1 ? 12 : 0
        // A peek (a nudge too) always has the notch to itself.
        case .idle, .approval, .banner, .nudge, .unknown: return 0
        }
    }

    /// Width of one wing for what the closed notch shows. With one activity
    /// this is the width it always had; the dot adds a little.
    public static func wingWidth(for content: ClosedContent, island: Bool) -> CGFloat {
        let dot = content.waiting ? waitingDotSpace : 0
        guard let first = content.primary else { return content.waiting ? (island ? 16 : loneDotWing) : 0 }
        guard let second = content.secondary else {
            return (island ? islandWingWidth(for: first) : wingWidth(for: first)) + dot
        }
        let pad: CGFloat = island ? islandWingPadding : 12
        let icon: CGFloat = island ? 16 : 18
        func slot(_ c: CompactView) -> CGFloat {
            let value = pairValueWidth(c)
            return pad + icon + (value > 0 ? pairGap + value : 0) + 4
        }
        return min(max(slot(first), slot(second) + dot), island ? 90 : 104)
    }

    // MARK: One row, on a screen without a notch

    /// Room for the icon (or artwork) at the start of a row, and the gap after it.
    public static let rowIcon: CGFloat = 20
    public static let rowGap: CGFloat = 8
    /// Space between two activities sharing a row.
    public static let rowPairSpace: CGFloat = 14
    public static let maxRowWidth: CGFloat = 340

    /// Width of one activity's value when it has the row to itself; text
    /// gets the room both wings and the gap had.
    static func rowValueWidth(_ c: CompactView) -> CGFloat {
        switch c.peek {
        case .trackChanged: return 200
        // `10:00 left`.
        case .timeWarning: return 66
        // A line that scrolls, like a song title.
        case .move, .quote, .stillWorking: return 200
        // The eye break's short line takes the `.nudge` width below.
        case .eyeBreak, .unknown, nil: break
        }
        switch c.kind {
        case .idle, .unknown: return 0
        // `1:24:59` in semibold digits.
        case .pomodoro, .caffeine, .timer, .calendar: return 48
        case .day: return 50
        case .meeting: return 54
        case .media: return 24
        case .approval: return textWidth(c.value, chars: 32) + (c.count > 1 ? 20 : 0)
        case .banner, .agent: return textWidth(c.title, chars: 32)
        case .nudge: return textWidth(c.value, chars: 32)
        }
    }

    /// Without a notch there is no camera to keep clear: what the closed
    /// notch shows as one row (padding at both ends included). One activity
    /// is its icon, then its value through the middle; two sit side by side,
    /// each as icon and time, as they would around a notch. 0 when empty.
    public static func rowWidth(for content: ClosedContent, island: Bool) -> CGFloat {
        guard let first = content.primary else { return 0 }
        let edge: CGFloat = island ? islandWingPadding : 12
        let dot = content.waiting ? waitingDotSpace : 0
        let inner: CGFloat
        if let second = content.secondary {
            let icon: CGFloat = island ? 16 : 18
            func slot(_ c: CompactView) -> CGFloat {
                let value = pairValueWidth(c)
                return icon + (value > 0 ? pairGap + value : 0)
            }
            inner = slot(first) + rowPairSpace + slot(second)
        } else {
            inner = rowIcon + rowGap + rowValueWidth(first)
        }
        return min(2 * edge + inner + dot, maxRowWidth)
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
    /// Closed and shrunk to the thin strip, in either style. Never set with
    /// a hardware notch, which the shape has to cover.
    public var minimized: Bool

    public init(style: NotchStyle, notch: CGSize, hasNotch: Bool = true, menuBarHeight: CGFloat = 0,
                minimized: Bool = false) {
        self.style = style
        self.notch = notch
        self.hasNotch = hasNotch
        self.menuBarHeight = menuBarHeight
        self.minimized = minimized
    }

    /// No camera housing to keep clear: the closed notch is one row, with no
    /// gap in the middle.
    public var oneRow: Bool { !hasNotch }

    /// Whether the closed notch is shrunk for `shrink`. When empty: nothing
    /// to show and no waiting dot. Always: everything but a peek, which is
    /// the point of a peek.
    ///
    /// Around a hardware notch only Always means anything: with nothing to
    /// show the shape already is the bare notch, and a strip thinner than
    /// the camera housing could not be found with the pointer. There, the
    /// shrunk shape is the bare notch with nothing beside it.
    public static func shrinks(_ shrink: ShrinkChoice, content: ClosedContent, peek: Bool, hasNotch: Bool) -> Bool {
        switch shrink {
        case .whenEmpty: return !hasNotch && content.isEmpty
        case .always: return !peek
        case .off, .unknown: return false
        }
    }

    public var island: Bool { style == .island }

    /// The band the island capsule sits in: the notch, which on those
    /// Macs is as tall as the menu bar, or the menu bar itself.
    public var bar: CGFloat {
        if hasNotch { return notch.height }
        return menuBarHeight > 0 ? menuBarHeight : NotchGeometry.fallbackSize.height
    }

    /// Room between the wings.
    public var centerWidth: CGFloat {
        island && !hasNotch ? NotchGeometry.islandCenterWidth : notch.width
    }

    /// Height of the closed island capsule.
    public var capsuleHeight: CGFloat { max(0, bar - 2 * NotchGeometry.islandMargin) }

    public func wingWidth(for compact: CompactView) -> CGFloat {
        island ? NotchGeometry.islandWingWidth(for: compact) : NotchGeometry.wingWidth(for: compact)
    }

    public func wingWidth(for content: ClosedContent) -> CGFloat {
        NotchGeometry.wingWidth(for: content, island: island)
    }

    /// Size of the area the shape takes for what the closed notch shows
    /// (the other modes do not depend on it).
    public func size(for mode: NotchMode, content: ClosedContent) -> CGSize {
        guard mode == .closed else { return size(for: mode, compact: content.primary) }
        if minimized {
            // A strip where there is no notch; the bare notch where there is.
            guard hasNotch else { return NotchGeometry.minimizedSize }
            return island
                ? CGSize(width: centerWidth, height: top(for: .closed) + capsuleHeight)
                : NotchGeometry.closedSize(notch: notch, wing: 0)
        }
        if oneRow && content.primary != nil {
            // Never narrower than the idle shape, so something showing never
            // makes it smaller.
            let row = NotchGeometry.rowWidth(for: content, island: island)
            if island {
                return CGSize(width: max(centerWidth, row), height: top(for: .closed) + capsuleHeight)
            }
            return CGSize(width: max(notch.width, row) + 2 * NotchGeometry.closedEar, height: notch.height)
        }
        let wing = wingWidth(for: content)
        if island {
            return CGSize(width: centerWidth + 2 * wing, height: top(for: .closed) + capsuleHeight)
        }
        return NotchGeometry.closedSize(notch: notch, wing: wing)
    }

    /// Empty space between the top of the screen and the shape; always 0
    /// when attached.
    public func top(for mode: NotchMode) -> CGFloat {
        guard island else { return 0 }
        switch mode {
        // The strip is flush with the top edge; beside a camera housing the
        // shrunk shape is the ordinary capsule with nothing in it.
        case .closed: return minimized && !hasNotch ? 0 : NotchGeometry.islandMargin
        case .toast: return max(0, bar - NotchGeometry.islandToastLift)
        case .expanded: return bar + NotchGeometry.islandPanelDrop
        }
    }

    /// Size of the area the shape takes, including the space above it.
    public func size(for mode: NotchMode, compact: CompactView?) -> CGSize {
        guard island else { return NotchGeometry.size(for: mode, compact: compact, notch: notch) }
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
    /// and clicks. Above an island shape only the column over the notch
    /// does, so the pointer can travel from the notch down to the shape
    /// while the rest of the menu bar stays usable.
    public func contains(_ p: CGPoint, mode: NotchMode, in size: CGSize) -> Bool {
        if p.y >= top(for: mode) { return true }
        return abs(p.x - size.width / 2) <= centerWidth / 2
    }
}
