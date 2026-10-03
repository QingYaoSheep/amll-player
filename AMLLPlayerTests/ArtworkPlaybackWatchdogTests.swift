@testable import AMLLPlayer
import XCTest

final class ArtworkPlaybackWatchdogTests: XCTestCase {
    func testMissingDecodedFramesAccumulateAcrossBufferingAndLoopBoundaries() {
        var clock = ArtworkFrameOutputWatchdog()
        // Eligibility means an actually displayed foreground cover. Changing
        // item/timeControlStatus is deliberately not a reset of output absence.
        XCTAssertFalse(clock.sample(now: 0, eligible: true))
        for time in [0.2, 0.4, 0.6, 0.8] { XCTAssertFalse(clock.sample(now: time, eligible: true)) }
        XCTAssertTrue(clock.sample(now: 1.01, eligible: true))
        XCTAssertGreaterThanOrEqual(clock.waiting, 1)
    }

    func testFrameArrivalAndInactiveTimeResetOnlyTheAppropriateClock() {
        var clock = ArtworkFrameOutputWatchdog()
        _ = clock.sample(now: 0, eligible: true)
        _ = clock.sample(now: 0.4, eligible: true)
        clock.suspend()
        XCTAssertFalse(clock.sample(now: 100, eligible: true))
        XCTAssertFalse(clock.sample(now: 100.4, eligible: true))
        clock.receivedFrame(now: 100.4)
        XCTAssertEqual(clock.waiting, 0)
        XCTAssertFalse(clock.sample(now: 101, eligible: true))
        XCTAssertTrue(clock.sample(now: 101.5, eligible: true))
    }

    func testFirstFrameDeadlineExcludesInactiveTime() {
        var clock = ArtworkPlaybackWatchdog()
        XCTAssertNil(clock.advance(elapsed: 29, eligible: true, displayed: false, position: 0))
        XCTAssertNil(clock.advance(elapsed: 300, eligible: false, displayed: false, position: 0))
        XCTAssertEqual(clock.advance(elapsed: 1, eligible: true, displayed: false, position: 0), .firstFrameTimeout)
    }

    func testFirstFrameResetsDeadlineAndStallFails() {
        var clock = ArtworkPlaybackWatchdog()
        _ = clock.advance(elapsed: 29, eligible: true, displayed: false, position: 0)
        XCTAssertNil(clock.advance(elapsed: 1, eligible: true, displayed: true, position: 0))
        XCTAssertNil(clock.advance(elapsed: 29, eligible: true, displayed: true, position: 0))
        XCTAssertEqual(clock.advance(elapsed: 1, eligible: true, displayed: true, position: 0), .stalledPlayback)
    }

    func testProgressAndLoopResetStallAndFailureIsTerminal() {
        var clock = ArtworkPlaybackWatchdog()
        _ = clock.advance(elapsed: 0, eligible: true, displayed: true, position: 10)
        _ = clock.advance(elapsed: 29, eligible: true, displayed: true, position: 10)
        XCTAssertNil(clock.advance(elapsed: 1, eligible: true, displayed: true, position: 0))
        XCTAssertNil(clock.advance(elapsed: 29, eligible: true, displayed: true, position: 0))
        XCTAssertEqual(clock.advance(elapsed: 1, eligible: true, displayed: true, position: 0), .stalledPlayback)
        XCTAssertEqual(clock.advance(elapsed: 1, eligible: true, displayed: true, position: 1), .stalledPlayback)
    }
}
