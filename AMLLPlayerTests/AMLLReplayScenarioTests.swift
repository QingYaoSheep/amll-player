@testable import AMLLPlayer
import XCTest

final class AMLLReplayScenarioTests: XCTestCase {
    func testPauseAndSeekSeparateSongTimeFromFrameTime() throws {
        let scenario = AMLLReplayScenario(id: "clock", lyricResource: "shared", initialPosition: 1, initiallyPlaying: true,
                                          frameDeltas: [0.1, 0.2, 0.3, 0.4], events: [
                                              .init(frame: 1, kind: .pause), .init(frame: 2, kind: .seek, value: 5),
                                              .init(frame: 3, kind: .play),
                                          ])
        var first = try AMLLReplayCursor(scenario)
        XCTAssertEqual(first.next()?.input.position ?? 0, 1.1, accuracy: 0.00001)
        XCTAssertEqual(first.next()?.input.position ?? 0, 1.1, accuracy: 0.00001)
        let seek = try XCTUnwrap(first.next())
        XCTAssertEqual(seek.input.position, 5)
        XCTAssertEqual(seek.input.seekRevision, 1)
        XCTAssertEqual(seek.delta, 0.3)
        XCTAssertEqual(first.next()?.input.position ?? 0, 5.4, accuracy: 0.00001)
        XCTAssertNil(first.next())
        var restarted = try AMLLReplayCursor(scenario)
        XCTAssertEqual(restarted.next()?.input.position ?? 0, 1.1, accuracy: 0.00001)
    }

    func testRejectsUnorderedEventsAndMissingSeekValue() {
        var scenario = AMLLReplayScenario(id: "bad", lyricResource: "shared", initialPosition: 0, initiallyPlaying: false,
                                          frameDeltas: [0, 0.1], events: [.init(frame: 0, kind: .seek)])
        XCTAssertThrowsError(try AMLLReplayCursor(scenario))
        scenario.events = [.init(frame: 1, kind: .play), .init(frame: 0, kind: .pause)]
        XCTAssertThrowsError(try AMLLReplayCursor(scenario))
    }
}
