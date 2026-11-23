import AppKit
import SwiftUI
import XCTest

@testable import LiteNotchUI

final class ProgressRingTests: XCTestCase {
    private func track(playing: Bool = true, position: Int = 60_000, duration: Int = 240_000, at: Int = 1_000_000) -> MediaView {
        MediaView(
            app: "Music", title: "t", artist: "a", album: "", playing: playing,
            durationMs: duration, positionMs: position, positionAtMs: at, controllable: true, artworkPath: nil)
    }

    func testTheRingIsOnUnlessSwitchedOffAndOldFilesKeepIt() throws {
        XCTAssertTrue(MediaConfig.default.progressRing)
        let old = try JSONDecoder().decode(MediaConfig.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(old.progressRing)
        let off = try JSONDecoder().decode(MediaConfig.self, from: Data(#"{"enabled":true,"progressRing":false}"#.utf8))
        XCTAssertFalse(off.progressRing)
    }

    func testFractionFollowsThePositionAndStaysInRange() {
        XCTAssertEqual(mediaFraction(track(), nowMs: 1_000_000), 0.25, accuracy: 1e-9)
        // Playing: a minute later it is half way. Paused: it does not move.
        XCTAssertEqual(mediaFraction(track(), nowMs: 1_060_000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(mediaFraction(track(playing: false), nowMs: 1_060_000), 0.25, accuracy: 1e-9)
        XCTAssertEqual(mediaFraction(track(), nowMs: 9_000_000), 1)
        XCTAssertEqual(mediaFraction(track(duration: 0), nowMs: 1_000_000), 0)
    }

    func testTheShapeStartsAtTheTopAndStaysInsideItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        for radius in [CGFloat(5), 10] {
            let p = RingShape(radius: radius).path(in: rect)
            XCTAssertEqual(p.currentPoint?.x ?? -1, 10, accuracy: 0.01, "closed back at the top middle")
            XCTAssertEqual(p.currentPoint?.y ?? -1, 0, accuracy: 0.01)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(p.boundingRect))
        }
    }

    @MainActor func testAPlayingSongAnimatesToItsEndOnceAndAPausedOneStandsStill() {
        let view = ProgressRingNSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let color = CGColor(gray: 1, alpha: 1)
        view.configure(media: track(), nowMs: 1_000_000, radius: 6, line: 1.5, fill: color, track: color)
        let a = view.fillLayer.animation(forKey: "progress") as? CABasicAnimation
        XCTAssertEqual(a?.fromValue as? Double ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(a?.duration ?? 0, 180, accuracy: 0.01, "three minutes left")
        // A redraw of the notch with the same facts leaves the animation alone.
        view.configure(media: track(), nowMs: 1_050_000, radius: 6, line: 1.5, fill: color, track: color)
        XCTAssertEqual(
            (view.fillLayer.animation(forKey: "progress") as? CABasicAnimation)?.fromValue as? Double ?? -1,
            0.25, accuracy: 1e-9)
        // Paused: no animation, the ring stays where the song is.
        view.configure(
            media: track(playing: false, position: 120_000), nowMs: 1_050_000,
            radius: 6, line: 1.5, fill: color, track: color)
        XCTAssertNil(view.fillLayer.animation(forKey: "progress"))
        XCTAssertEqual(Double(view.fillLayer.strokeEnd), 0.5, accuracy: 1e-6)
    }

    /// The ring takes its space from the artwork: the closed notch is laid
    /// out the same with or without it.
    @MainActor func testTheRingDoesNotChangeTheSizeOfTheIcon() {
        for round in [false, true] {
            let plain = NSHostingView(rootView: ClosedArtwork(path: nil, size: 20, round: round, media: nil))
            let ringed = NSHostingView(rootView: ClosedArtwork(path: nil, size: 20, round: round, media: track()))
            XCTAssertEqual(plain.fittingSize, ringed.fittingSize)
            XCTAssertEqual(ringed.fittingSize, CGSize(width: 20, height: 20))
        }
    }
}
