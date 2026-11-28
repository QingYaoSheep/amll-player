@testable import AMLLPlayer
import XCTest

@MainActor
final class SleepTimerControllerTests: XCTestCase {
    func testCountdownExpiresTriggersPauseOnceAndResetsToOff() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var recordedDelay: TimeInterval?
        var pauseCount = 0
        var resumeTimer: CheckedContinuation<Void, Error>?

        let controller = SleepTimerController(
            now: { now },
            sleep: { seconds in
                recordedDelay = seconds
                try await withCheckedThrowingContinuation { continuation in
                    resumeTimer = continuation
                }
            },
            onTriggerPause: {
                pauseCount += 1
            }
        )

        controller.start(minutes: 15)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.remainingSeconds(at: now), 900)

        for _ in 0 ..< 20 where resumeTimer == nil {
            await Task.yield()
        }
        XCTAssertEqual(recordedDelay, 900)
        resumeTimer?.resume()
        for _ in 0 ..< 20 where pauseCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.remainingSeconds(at: now))
    }

    func testExtendMovesDeadlineAndCancelPreventsPause() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        var pauseCount = 0
        var delays: [TimeInterval] = []

        let controller = SleepTimerController(
            now: { now },
            sleep: { seconds in
                delays.append(seconds)
                try await Task.sleep(for: .seconds(60))
            },
            onTriggerPause: { pauseCount += 1 }
        )

        controller.start(minutes: 15)
        await Task.yield()
        XCTAssertEqual(controller.remainingSeconds(at: now), 900)

        controller.extend(minutes: 5)
        await Task.yield()
        XCTAssertEqual(controller.remainingSeconds(at: now), 1_200)
        XCTAssertEqual(delays, [900, 1_200])

        controller.cancel()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(pauseCount, 0)
    }

    func testEndOfTrackOnlyPausesWhenTrackChangesWhilePlaying() async throws {
        var pauseCount = 0
        let controller = SleepTimerController(onTriggerPause: { pauseCount += 1 })

        controller.startEndOfTrack(currentTrackURI: "track-1")
        XCTAssertEqual(controller.mode, .endOfTrack(trackURI: "track-1"))

        controller.handleTrackChange(previousURI: "track-1", currentURI: "track-1", isPlaying: true)
        await Task.yield()
        XCTAssertEqual(pauseCount, 0)
        XCTAssertEqual(controller.mode, .endOfTrack(trackURI: "track-1"))

        controller.handleTrackChange(previousURI: "track-1", currentURI: "track-2", isPlaying: true)
        for _ in 0 ..< 20 where pauseCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(controller.mode, .off)

        controller.startEndOfTrack(currentTrackURI: "track-2")
        controller.handleTrackChange(previousURI: "track-2", currentURI: "track-3", isPlaying: false)
        await Task.yield()
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(controller.mode, .off)
    }

    func testReconcileOnForegroundClearsExpiredDeadlineSilently() async throws {
        var now = Date(timeIntervalSince1970: 5_000)
        var pauseCount = 0
        let controller = SleepTimerController(
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            onTriggerPause: { pauseCount += 1 }
        )

        controller.start(minutes: 15)
        now = Date(timeIntervalSince1970: 6_500)
        controller.reconcileOnForeground()
        await Task.yield()

        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(pauseCount, 0)
    }

    func testFormattedDurationCoversMinutesAndHours() {
        XCTAssertEqual(SleepTimerController.formattedDuration(-5), "0:00")
        XCTAssertEqual(SleepTimerController.formattedDuration(59), "0:59")
        XCTAssertEqual(SleepTimerController.formattedDuration(60), "1:00")
        XCTAssertEqual(SleepTimerController.formattedDuration(899), "14:59")
        XCTAssertEqual(SleepTimerController.formattedDuration(3_600), "1:00:00")
        XCTAssertEqual(SleepTimerController.formattedDuration(3_661), "1:01:01")
    }
}
