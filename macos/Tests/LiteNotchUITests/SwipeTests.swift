import XCTest

@testable import LiteNotchUI

final class SwipeTrackerTests: XCTestCase {
    private let p = CGPoint(x: 50, y: 60)

    private func run(_ moves: [(CGFloat, CGFloat)]) -> [SwipeTracker.Step] {
        var t = SwipeTracker()
        var steps: [SwipeTracker.Step] = []
        for (i, m) in moves.enumerated() {
            if let s = t.feed(dx: m.0, dy: m.1, phase: i == 0 ? .began : .changed, at: p) { steps.append(s) }
        }
        return steps
    }

    func testOneSwipeIsOneStepHoweverFarItGoes() {
        let steps = run(Array(repeating: (-10, 0), count: 30))
        XCTAssertEqual(steps, [.init(axis: .horizontal, forward: true)])
        XCTAssertEqual(run(Array(repeating: (10, 0), count: 5)), [.init(axis: .horizontal, forward: false)])
    }

    func testTheFirstMovementPicksTheAxis() {
        // Mostly down at first, then drifting sideways: stays vertical.
        let steps = run([(0, -6), (0, -6), (-20, -10), (-40, -20)])
        XCTAssertEqual(steps, [.init(axis: .vertical, forward: true)])
    }

    func testAListScrolledDownAskewDoesNotTurnATab() {
        // More across than down at first, but not twice as much.
        XCTAssertEqual(run([(-6, -4), (-20, -15), (-30, -25)]), [.init(axis: .vertical, forward: true)])
        XCTAssertEqual(run([(-8, -3), (-40, -5)]), [.init(axis: .horizontal, forward: true)])
    }

    func testASmallMoveDoesNothing() {
        XCTAssertEqual(run([(-5, 0), (-10, 0), (-10, 0)]), [])
    }

    func testLiftingStartsAnew() {
        var t = SwipeTracker()
        _ = t.feed(dx: -50, dy: 0, phase: .began, at: p)
        XCTAssertNil(t.feed(dx: -50, dy: 0, phase: .changed, at: p))
        _ = t.feed(dx: 0, dy: 0, phase: .ended, at: p)
        XCTAssertNotNil(t.feed(dx: -50, dy: 0, phase: .began, at: p))
    }

    func testMomentumAndTheWheelAreIgnored() {
        var t = SwipeTracker()
        XCTAssertNil(t.feed(dx: -100, dy: 0, phase: .ignored, at: p))
        XCTAssertNil(t.start)
    }
}

final class CardSwipeTests: XCTestCase {
    /// The panel holds its app weakly.
    private var models: [AppModel] = []

    private func panel(day: Bool = true, body: Bool = true) throws -> PanelState {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/body.json")
        var v = try ViewModel.decode(Data(contentsOf: url))
        v.settings.day.homeCard = .auto
        v.day = day ? DayView(startMs: 0, endMs: 1, line: "") : nil
        if !body { v.body = nil }
        let model = AppModel(bridge: MockBridge())
        models.append(model)
        model.apply(v)
        let p = model.primary
        p.open()
        p.selectTab(.home)
        p.homeCardFrame = CGRect(x: 0, y: 0, width: 236, height: 150)
        return p
    }

    private let down = SwipeTracker.Step(axis: .vertical, forward: true)
    private let up = SwipeTracker.Step(axis: .vertical, forward: false)
    private let onCard = CGPoint(x: 100, y: 80)

    func testPagesAreTheCardsWithSomethingToShow() throws {
        XCTAssertEqual(HomeCardPick.pages(try panel().view!), [.day, .body, .media])
        XCTAssertEqual(HomeCardPick.pages(try panel(day: false).view!), [.body, .media])
        XCTAssertEqual(HomeCardPick.pages(try panel(day: false, body: false).view!), [.media])
    }

    func testUpAndDownOverTheCardMoveOnePageAndStopAtTheEnds() throws {
        let p = try panel()
        p.homeCardHeld = .day
        p.swiped(down, from: onCard)
        XCTAssertEqual(p.homeCardHeld, .body)
        p.swiped(down, from: onCard)
        p.swiped(down, from: onCard)
        XCTAssertEqual(p.homeCardHeld, .media)
        p.swiped(up, from: CGPoint(x: 400, y: 80))
        XCTAssertEqual(p.homeCardHeld, .media, "up/down beside the card does nothing")
    }

    func testTheSlideFollowsTheDirection() throws {
        let p = try panel()
        p.showHomeCard(.body, from: .day)
        XCTAssertTrue(p.homeCardForward)
        XCTAssertEqual(p.homeCardHeld, .body)
        p.showHomeCard(.day, from: .body)
        XCTAssertFalse(p.homeCardForward, "set first, the change follows a moment later")
        let done = expectation(description: "changed")
        DispatchQueue.main.async {
            XCTAssertEqual(p.homeCardHeld, .day)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    func testTheChoiceHoldsUntilThePanelCloses() throws {
        let p = try panel()
        p.showHomeCard(.body)
        let vm = try XCTUnwrap(p.view)
        // Auto alone would show the day (the gauges are full).
        XCTAssertEqual(HomeCardPick.card(vm, nowMs: 0, held: nil), .day)
        XCTAssertEqual(HomeCardPick.card(vm, nowMs: 0, held: p.homeCardHeld), .body)
        p.close()
        XCTAssertNil(p.homeCardHeld)
    }

    func testAHeldCardWithNothingToShowGivesWay() throws {
        let vm = try XCTUnwrap(try panel(body: false).view)
        XCTAssertEqual(HomeCardPick.card(vm, nowMs: 0, held: .body), .day)
    }

    func testLeftAndRightMoveOneTabInTheBarsOrder() throws {
        let p = try panel()
        let left = SwipeTracker.Step(axis: .horizontal, forward: false)
        let right = SwipeTracker.Step(axis: .horizontal, forward: true)
        p.swiped(left, from: onCard)
        XCTAssertEqual(p.tab, .settings, "back from Home is Settings, the far right")
        p.swiped(right, from: nil)
        XCTAssertEqual(p.tab, .home)
        p.swiped(right, from: nil)
        XCTAssertEqual(p.tab, .music)
        p.selectTab(.agents)
        p.swiped(right, from: nil)
        XCTAssertEqual(p.tab, p.swipeTabs[TabBar.left.count], "past the notch to the right side")
        p.selectTab(.settings)
        p.swiped(right, from: nil)
        XCTAssertEqual(p.tab, .home, "and on from Settings is Home")
    }

    func testNothingTurnsWhileTypingOrClosed() throws {
        let p = try panel()
        p.requestKeyboard(true)
        p.swiped(.init(axis: .horizontal, forward: true), from: nil)
        XCTAssertEqual(p.tab, .home)
        p.requestKeyboard(false)
        p.close()
        p.swiped(.init(axis: .horizontal, forward: true), from: nil)
        XCTAssertEqual(p.tab, .home)
    }
}
