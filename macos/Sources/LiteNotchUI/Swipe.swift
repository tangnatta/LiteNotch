import AppKit
import SwiftUI

/// Turns a two-finger trackpad swipe into one page step.
///
/// The first few points of movement pick the axis, so a diagonal swipe
/// moves along one only. Once the fingers have gone `fireAfter` along it,
/// one step fires; nothing more until they lift. Momentum after the lift
/// and a mouse wheel (no precise deltas, no phase) are ignored, so a wheel
/// never turns a page.
public struct SwipeTracker {
    public enum Axis: Equatable { case horizontal, vertical }

    public enum Phase: Equatable {
        /// Fingers down (`began` or `mayBegin`).
        case began
        case changed
        /// Fingers up or the gesture cancelled.
        case ended
        /// Anything else: momentum, a mouse wheel.
        case ignored
    }

    /// One page step. `forward` is the next page: right for tabs, down for
    /// the card, the way content would scroll with the user's own setting
    /// (the deltas already follow natural scrolling).
    public struct Step: Equatable {
        public var axis: Axis
        public var forward: Bool
    }

    static let lockAfter: CGFloat = 8
    static let fireAfter: CGFloat = 40

    private var sum = CGSize.zero
    private var axis: Axis?
    private var fired = false
    private var active = false
    /// Where the fingers came down, in the hosting view (top-left origin).
    public private(set) var start: CGPoint?

    public init() {}

    public mutating func feed(dx: CGFloat, dy: CGFloat, phase: Phase, at point: CGPoint) -> Step? {
        switch phase {
        case .ignored:
            return nil
        case .began:
            self = SwipeTracker()
            active = true
            start = point
            return add(dx, dy)
        case .changed:
            // A gesture whose start was missed (the panel opened mid-swipe)
            // starts here.
            if !active {
                active = true
                start = point
            }
            return add(dx, dy)
        case .ended:
            self = SwipeTracker()
            return nil
        }
    }

    private mutating func add(_ dx: CGFloat, _ dy: CGFloat) -> Step? {
        guard !fired else { return nil }
        sum.width += dx
        sum.height += dy
        if axis == nil {
            let ax = abs(sum.width), ay = abs(sum.height)
            guard max(ax, ay) >= Self.lockAfter else { return nil }
            axis = ax >= ay ? .horizontal : .vertical
        }
        let along = axis == .horizontal ? sum.width : sum.height
        guard abs(along) >= Self.fireAfter, let axis else { return nil }
        fired = true
        // Content moving left or up (negative) brings the next page in.
        return Step(axis: axis, forward: along < 0)
    }

    public static func phase(of event: NSEvent) -> Phase {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return .ignored }
        let p = event.phase
        if p.contains(.began) || p.contains(.mayBegin) { return .began }
        if p.contains(.changed) { return .changed }
        if p.contains(.ended) || p.contains(.cancelled) { return .ended }
        return .ignored
    }
}

extension PanelState {
    /// Every tab in the bar's order, left to right.
    var swipeTabs: [Tab] {
        TabBar.left + TabBar.right(calendar: view?.settings.calendar.enabled ?? false)
    }

    /// A finished step from `SwipeTracker`: left/right anywhere in the open
    /// panel moves one tab, round from Settings to Home and back; up/down
    /// that began over Home's big card moves one card page and stops at the
    /// ends. Nothing while an approval or the welcome is showing or a text
    /// field has the keyboard.
    public func swiped(_ step: SwipeTracker.Step, from start: CGPoint?) {
        guard expanded, !keyboardRequested, !welcome, view?.agents.pending.isEmpty ?? true else { return }
        switch step.axis {
        case .horizontal:
            let tabs = swipeTabs
            guard let i = tabs.firstIndex(of: tab) else { return }
            let j = (i + (step.forward ? 1 : -1) + tabs.count) % tabs.count
            selectTab(tabs[j])
        case .vertical:
            guard tab == .home, let vm = view, let start, homeCardFrame.contains(start) else { return }
            let pages = HomeCardPick.pages(vm)
            let current = HomeCardPick.card(vm, nowMs: nowMs(Date(), offset: 0), held: homeCardHeld)
            guard let i = pages.firstIndex(of: current) else { return }
            let j = i + (step.forward ? 1 : -1)
            guard pages.indices.contains(j) else { return }
            showHomeCard(pages[j], from: current)
        }
    }

    /// Keeps Home's big card on `card` until the panel closes: a swipe, a
    /// dot, or a button on the card. With `from` (a swipe or a dot) the
    /// change slides: up to a later page, down to an earlier one.
    public func showHomeCard(_ card: HomeCardShown, from current: HomeCardShown? = nil) {
        guard homeCardHeld != card else { return }
        guard let current, let vm = view else {
            homeCardHeld = card
            return
        }
        let pages = HomeCardPick.pages(vm)
        let forward = (pages.firstIndex(of: card) ?? 0) > (pages.firstIndex(of: current) ?? 0)
        let slide = { withAnimation(.easeOut(duration: 0.22)) { self.homeCardHeld = card } }
        if forward == homeCardForward {
            slide()
        } else {
            // The outgoing card leaves with the transition it was last drawn
            // with, so the new direction must be drawn once before the change.
            homeCardForward = forward
            DispatchQueue.main.async(execute: slide)
        }
    }
}

/// Dots down the right edge of Home's big card, one per page; the shown
/// one is bright. A click shows that page.
struct CardPageDots: View {
    let pages: [HomeCardShown]
    let shown: HomeCardShown
    let select: (HomeCardShown) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(pages, id: \.self) { page in
                Button {
                    select(page)
                } label: {
                    Circle()
                        .fill(page == shown ? NT.text1 : NT.text3)
                        .frame(width: 4, height: 4)
                        .frame(width: 10, height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.name(page))
                .accessibilityAddTraits(page == shown ? .isSelected : [])
            }
        }
    }

    static func name(_ page: HomeCardShown) -> String {
        switch page {
        case .day: return "Day progress"
        case .body: return "Water and stretch"
        case .media: return "Now playing"
        }
    }
}
