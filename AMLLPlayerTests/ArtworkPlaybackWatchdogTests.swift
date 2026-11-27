@testable import AMLLPlayer
import XCTest

final class ArtworkPlaybackWatchdogTests: XCTestCase {
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
