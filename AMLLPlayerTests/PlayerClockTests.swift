import XCTest

@testable import AMLLPlayer

final class PlayerClockTests: XCTestCase {
    func testPlayingProgressUsesMonotonicElapsedTimeAndClampsToDuration() {
        let clock = PlayerClock(anchor: snapshot(position: 10, duration: 20, uptime: 100))

        XCTAssertEqual(clock.position(at: 104), 14, accuracy: 0.001)
        XCTAssertEqual(clock.position(at: 120), 20, accuracy: 0.001)
    }

    func testPausedProgressDoesNotAdvance() {
        let clock = PlayerClock(
            anchor: snapshot(position: 10, duration: 20, isPlaying: false, uptime: 100)
        )

        XCTAssertEqual(clock.position(at: 110), 10, accuracy: 0.001)
    }

    func testCalibrationRejectsNetworkRegressionForSameTrack() {
        var clock = PlayerClock(anchor: snapshot(position: 10, duration: 60, uptime: 100))
        let response = snapshot(position: 10.5, duration: 60, uptime: 102)

        let calibrated = clock.calibrate(with: response)

        XCTAssertEqual(calibrated.position, 12, accuracy: 0.001)
    }

    func testCalibrationAllowsExplicitBackwardSeek() {
        var clock = PlayerClock(anchor: snapshot(position: 40, duration: 60, uptime: 100))
        let response = snapshot(position: 10, duration: 60, uptime: 101)

        let calibrated = clock.calibrate(with: response, allowBackwardJump: true)

        XCTAssertEqual(calibrated.position, 10, accuracy: 0.001)
    }

    func testTrackChangeDoesNotInheritPreviousProgress() {
        var clock = PlayerClock(anchor: snapshot(position: 40, duration: 60, uptime: 100))
        let response = snapshot(
            uri: "spotify:track:new",
            position: 1,
            duration: 180,
            uptime: 101
        )

        let calibrated = clock.calibrate(with: response)

        XCTAssertEqual(calibrated.position, 1, accuracy: 0.001)
    }

    private func snapshot(
        uri: String = "spotify:track:test",
        position: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool = true,
        uptime: TimeInterval
    ) -> PlaybackSnapshot {
        let item = PlaybackItem(
            id: "test",
            uri: uri,
            title: "Track",
            artists: ["Artist"],
            albumTitle: "Album",
            artworkURL: nil,
            duration: duration,
            isEpisode: false,
            isAdvertisement: false
        )
        return PlaybackSnapshot(
            item: item,
            isPlaying: isPlaying,
            position: position,
            duration: duration,
            device: nil,
            restrictions: .unrestricted,
            source: .webAPI,
            sampledAtUptime: uptime
        )
    }
}
