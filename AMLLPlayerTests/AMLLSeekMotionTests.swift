@testable import AMLLPlayer
import XCTest

final class AMLLSeekMotionTests: XCTestCase {
    private func engine(advance: Double = 0.3, spring: Bool = true, reduceMotion: Bool = false) -> AMLLFrameEngine {
        var lines: [LyricLine] = []
        for i in 0..<8 {
            let start = Double(i) * 4
            let words = [LyricWord(text: "Line", start: start, end: start + 3)]
            lines.append(.init(id: String(i), text: "Line", start: start, end: start + 3, words: words, precision: .word))
        }
        var env = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        env.alignPosition = 0.28; env.advance = advance; env.enableSpring = spring; env.reduceMotion = reduceMotion
        return AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines), environment: env, heights: Array(repeating: 60, count: lines.count))
    }
    func testConfirmedSeekAnimatesFromPresentedBrowsePositionAndSettlesAtRealTarget() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            for advance in [0.0, 0.3, 1.0] {
                var live = engine(advance: advance)
                _ = live.render(.init(position: 1, playing: true), delta: 0)
                live.handle(.beginBrowsing); live.handle(.browseBy(200))
                let before = live.render(.init(position: 1, playing: true), delta: 0)
                let input = AMLLPlayerInput(position: 16, playing: true, seekRevision: 1, seekPosition: 16)
                let first = live.render(input, delta: step)
                var fresh = engine(advance: advance)
                let target = fresh.render(.init(position: 16, playing: true), delta: 0)
                XCTAssertGreaterThan(abs(first.rows[4].y - target.rows[4].y), 1)
                XCTAssertLessThan(abs(first.rows[4].y - before.rows[4].y), abs(target.rows[4].y - before.rows[4].y))
                XCTAssertTrue(first.rows[4].active)
                XCTAssertEqual(live.document.lines[4].start + first.rows[4].wordClock.time, 16, accuracy: 0.001)
                XCTAssertFalse(first.rows[4].fillComplete)
                var final = first
                for _ in 0..<Int(3 / step) { final = live.render(input, delta: step) }
                XCTAssertEqual(final.rows[4].y, target.rows[4].y, accuracy: 0.1)
            }
        }
    }
    func testPendingSeekPreservesBrowsePositionUntilPlayerAcknowledgesIt() {
        var live = engine()
        _ = live.render(.init(position: 1, playing: true), delta: 0)
        live.handle(.beginBrowsing); live.handle(.browseBy(200))
        let before = live.render(.init(position: 1, playing: true), delta: 0)
        for _ in 0..<20 {
            let pending = live.render(.init(position: 1, playing: true, seekRevision: 1, seekPosition: 16), delta: 1 / 120)
            XCTAssertEqual(pending.rows[4].y, before.rows[4].y, accuracy: 0.001, "Do not return to the old song position before seeking")
        }
        let confirmed = live.render(.init(position: 16, playing: true, seekRevision: 2, seekPosition: 16), delta: 1 / 120)
        XCTAssertFalse(confirmed.browsing)
        XCTAssertTrue(confirmed.rows[4].active)
        XCTAssertGreaterThan(confirmed.rows[4].y, 300)
    }
    func testSeekAndReturnToCurrentUseTheSameSpatialSpring() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            var sought = engine(), returned = engine()
            _ = sought.render(.init(position: 1, playing: true), delta: 0)
            sought.handle(.beginBrowsing); sought.handle(.browseBy(200))
            let before = sought.render(.init(position: 1, playing: true), delta: 0)
            let origin = returned.render(.init(position: 16, playing: true), delta: 0)
            returned.handle(.beginBrowsing); returned.handle(.browseBy(origin.rows[4].y - before.rows[4].y))
            _ = returned.render(.init(position: 16, playing: true), delta: 0)
            returned.handle(.resumeFollowing)
            for _ in 0..<Int(1 / step) {
                let a = sought.render(.init(position: 16, playing: true, seekRevision: 1, seekPosition: 16), delta: step)
                let b = returned.render(.init(position: 16, playing: true), delta: step)
                XCTAssertEqual(a.rows[4].y, b.rows[4].y, accuracy: 0.001)
            }
        }
    }
    func testSeekPreservesOffsetAndBackwardsWordReplayWhileMoving() {
        var live = engine()
        _ = live.render(.init(position: 25, offset: 0.5, playing: true), delta: 0)
        let result = live.render(.init(position: 4.5, offset: 0.5, playing: true, seekRevision: 1, seekPosition: 4.5), delta: 1 / 120)
        XCTAssertEqual(result.lyricTime, 4, accuracy: 0.001)
        XCTAssertEqual(live.document.lines[1].start + result.rows[1].wordClock.time, 4, accuracy: 0.001)
        XCTAssertFalse(result.rows[1].fillComplete)
        XCTAssertFalse(result.rows[1].hdrHold)
        XCTAssertFalse(result.rows[4].active)
    }
    func testReduceMotionStillPositionsSeekImmediately() {
        var live = engine(reduceMotion: true), fresh = engine(reduceMotion: true)
        _ = live.render(.init(position: 1, playing: true), delta: 0)
        live.handle(.beginBrowsing); live.handle(.browseBy(200))
        _ = live.render(.init(position: 1, playing: true), delta: 0)
        let result = live.render(.init(position: 16, playing: true, seekRevision: 1, seekPosition: 16), delta: 1 / 120)
        let target = fresh.render(.init(position: 16, playing: true), delta: 0)
        XCTAssertEqual(result.rows[4].y, target.rows[4].y, accuracy: 0.001)
    }
    func testDisabledSpringKeepsExistingEaseOutInsteadOfSnapping() {
        var live = engine(spring: false), fresh = engine(spring: false)
        _ = live.render(.init(position: 1, playing: true), delta: 0)
        live.handle(.beginBrowsing); live.handle(.browseBy(200))
        let before = live.render(.init(position: 1, playing: true), delta: 0)
        let result = live.render(.init(position: 16, playing: true, seekRevision: 1, seekPosition: 16), delta: 1 / 120)
        let target = fresh.render(.init(position: 16, playing: true), delta: 0)
        XCTAssertGreaterThan(abs(result.rows[4].y - target.rows[4].y), 1)
        XCTAssertLessThan(abs(result.rows[4].y - before.rows[4].y), abs(target.rows[4].y - before.rows[4].y))
    }
}
