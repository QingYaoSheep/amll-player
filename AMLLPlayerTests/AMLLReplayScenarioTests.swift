@testable import AMLLPlayer
import UIKit
import XCTest

final class AMLLReplayScenarioTests: XCTestCase {
    func testSharedResourcePreservesEventTimesAtBothRefreshRates() throws {
        let slow = try AMLLReplayScenario.shared()
        let fast = try AMLLReplayScenario.shared(framesPerSecond: 120)
        XCTAssertEqual(slow.frameDeltas.count, 480)
        XCTAssertEqual(fast.frameDeltas.count, 960)
        for (a, b) in zip(slow.events, fast.events) {
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(a.value, b.value)
            XCTAssertEqual(slow.frameDeltas.prefix(a.frame).reduce(0, +),
                           fast.frameDeltas.prefix(b.frame).reduce(0, +), accuracy: 0.000001)
        }
        var cursor = try AMLLReplayCursor(slow)
        var positions: [Double] = []
        while let frame = cursor.next() {
            positions.append(frame.input.position)
        }
        XCTAssertEqual(positions[120], 5)
        XCTAssertEqual(positions[179], 5)
        XCTAssertGreaterThan(positions[180], 5)
    }

    @MainActor
    func testActualCanvasReplayIsRepeatableAtBothRatesAndIrregularFrames() throws {
        let reference = try AMLLSharedReference.load()
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        canvas.configure(document: reference.document, configuration: .init(), input: .init(position: 1, playing: true),
                         active: false, reduceMotion: false)
        canvas.onInteraction = { _ in XCTFail("Replay must not invoke production controls") }
        canvas.onBrowsing = { _ in XCTFail("Replay must not invoke production browsing callbacks") }
        for delta in [1.0 / 60, 1.0 / 120, 0.137] {
            let scenario = AMLLReplayScenario(id: "canvas", lyricResource: "amll-shared-lyrics.json", initialPosition: 1,
                                              initiallyPlaying: true, frameDeltas: [0, delta, delta * 2, delta, delta], events: [
                                                  .init(frame: 1, kind: .pause), .init(frame: 2, kind: .seek, value: 5),
                                                  .init(frame: 3, kind: .beginBrowsing), .init(frame: 3, kind: .browseBy, value: 50),
                                                  .init(frame: 4, kind: .resumeFollowing),
                                              ])
            let first = try canvas.replay(scenario, through: 4)
            XCTAssertEqual(first.count, 5)
            XCTAssertFalse(first[0].rows.isEmpty)
            _ = try canvas.replay(scenario, through: 1)
            let repeated = try canvas.replay(scenario, through: 4)
            XCTAssertEqual(first.map(\.rows), repeated.map(\.rows))
            XCTAssertEqual(first.map(\.animationTime), repeated.map(\.animationTime))
            XCTAssertEqual(first[2].lyricTime, 5, accuracy: 0.000001)
            XCTAssertTrue(first[3].browsing)
            XCTAssertFalse(first[4].browsing)
        }
    }

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
