@testable import AMLLPlayer
import XCTest

final class AMLLFocusRetirementTests: XCTestCase {
    private func engine(advance: Double = 0, spring: Bool = true, scale: Bool = true) -> AMLLFrameEngine {
        let lines = [(0.0, 1.0), (2.0, 3.0), (4.0, 5.0)].enumerated().map { index, span in
            LyricLine(id: String(index), text: "Line \(index)", start: span.0, end: span.1,
                      words: [.init(text: "Line \(index)", start: span.0, end: span.1)], precision: .word)
        }
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.alignPosition = 0.28
        environment.advance = advance
        environment.enableSpring = spring
        environment.enableScale = scale
        return AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 60, 60])
    }

    func testFirstUpwardFrameStartsButDoesNotFinishRetirement() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            var player = engine()
            _ = player.render(.init(position: 0.1, playing: true), delta: 0)
            let held = player.render(.init(position: 1.39, playing: true), delta: 1.29).rows[0]
            let scheduled = player.render(.init(position: 1.41, playing: true), delta: 0).rows[0]
            XCTAssertEqual(scheduled.scale, held.scale, accuracy: 0.000001)
            XCTAssertEqual(scheduled.brightAlpha, held.brightAlpha, accuracy: 0.001)
            let moving = player.render(.init(position: 1.41, playing: true), delta: step).rows[0]
            XCTAssertLessThan(moving.y, held.y)
            XCTAssertLessThan(moving.scale, held.scale)
            XCTAssertGreaterThan(moving.scale, 0.97)
            XCTAssertLessThan(moving.brightAlpha * moving.opacity, held.brightAlpha * held.opacity)
            XCTAssertGreaterThan(moving.brightAlpha, 0.2)
            XCTAssertGreaterThan(moving.blur, held.blur)
            XCTAssertLessThan(moving.blur, 2.4)
            XCTAssertTrue(moving.fillComplete)
        }
    }

    func testHDRAndEffectiveAlphaShareOneEnvelopeWithoutRestartingOnResizeOrPause() throws {
        var player = engine()
        _ = player.render(.init(position: 0.1, playing: true), delta: 0)
        let held = player.render(.init(position: 1.39, playing: true), delta: 1.29).rows[0]
        _ = player.render(.init(position: 1.41, playing: true), delta: 0)
        var previous = held.brightAlpha * held.opacity * 2
        var start: Double?
        for frameIndex in 0 ..< 48 {
            if frameIndex == 12 {
                var environment = AMLLRenderEnvironment(width: 700, height: 400, screenWidth: 700, fontSize: 32)
                environment.alignPosition = 0.28
                environment.advance = 0
                player.resize(environment: environment, heights: [60, 60, 60])
            }
            let frame = player.render(.init(position: 1.41, playing: false), delta: 1.0 / 120)
            let row = frame.rows[0]
            let retirement = try XCTUnwrap(row.retirement)
            if let start { XCTAssertEqual(retirement.startedAt, start) } else { start = retirement.startedAt }
            let effective = row.brightAlpha * row.opacity
            let hdrExcess = effective * retirement.hdrWeight
            XCTAssertEqual(hdrExcess, held.brightAlpha * held.opacity * (1 - retirement.progress), accuracy: 0.001)
            XCTAssertLessThanOrEqual(effective + hdrExcess, previous + 0.000001)
            previous = effective + hdrExcess
        }
        let end = player.render(.init(position: 1.41, playing: false), delta: 2).rows[0]
        XCTAssertEqual(end.brightAlpha, 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(end.retirement).hdrWeight, 0)
        let rewound = player.render(.init(position: 0.5, playing: true, seekRevision: 1), delta: 0).rows[0]
        XCTAssertNil(rewound.retirement)
        XCTAssertFalse(rewound.fillComplete)
        XCTAssertTrue(rewound.wordClock.enabled)
    }

    func testAnEventCrossedByOneLongFrameConsumesTheSameRetirementTime() throws {
        var oneFrame = engine()
        var manyFrames = engine()
        for position in [0.1, 1.39] {
            let delta = position == 0.1 ? 0 : 1.29
            _ = oneFrame.render(.init(position: position, playing: true), delta: delta)
            _ = manyFrames.render(.init(position: position, playing: true), delta: delta)
        }
        let coarse = oneFrame.render(.init(position: 1.41, playing: true), delta: 0.2)
        _ = manyFrames.render(.init(position: 1.41, playing: true), delta: 0)
        var fine = manyFrames.render(.init(position: 1.41, playing: true), delta: 0)
        for _ in 0 ..< 24 {
            fine = manyFrames.render(.init(position: 1.41, playing: true), delta: 1.0 / 120)
        }
        XCTAssertEqual(coarse.rows[0].scale, fine.rows[0].scale, accuracy: 0.001)
        XCTAssertEqual(coarse.rows[0].brightAlpha, fine.rows[0].brightAlpha, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(coarse.rows[0].retirement).progress,
                       try XCTUnwrap(fine.rows[0].retirement).progress, accuracy: 0.001)
    }

    func testBrowsingClearsBlurWithoutRestartingRetirement() throws {
        var player = engine()
        _ = player.render(.init(position: 0.1, playing: true), delta: 0)
        _ = player.render(.init(position: 1.39, playing: true), delta: 1.29)
        let moving = player.render(.init(position: 1.41, playing: true), delta: 0.08).rows[0]
        XCTAssertGreaterThan(moving.blur, 0)
        player.handle(.beginBrowsing)
        player.handle(.browseBy(-100))
        let browsed = player.render(.init(position: 1.41, playing: true), delta: 1.0 / 120).rows[0]
        XCTAssertEqual(browsed.blur, 0)
        XCTAssertEqual(try XCTUnwrap(browsed.retirement).startedAt, try XCTUnwrap(moving.retirement).startedAt)
        XCTAssertGreaterThan(try XCTUnwrap(browsed.retirement).progress, try XCTUnwrap(moving.retirement).progress)
    }

    func testScrollAheadUsesTheOutgoingDeadlineAndNeverAdvancesWordTime() throws {
        for advance in [0.0, 0.3, 1.0] {
            for step in [1.0 / 60, 1.0 / 120, 0.037] {
                // Start before either visual boundary even with one second of scroll-ahead.
                let lines = [(2.0, 2.2), (4.0, 5.0)].enumerated().map { index, span in
                    LyricLine(id: String(index), text: "Line \(index)", start: span.0, end: span.1,
                              words: [.init(text: "Line \(index)", start: span.0, end: span.1)], precision: .word)
                }
                var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
                environment.alignPosition = 0.28
                environment.advance = advance
                var player = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 60])
                _ = player.render(.init(position: 0.1, playing: true), delta: 0)
                var time = 0.1
                var seen = false
                while time < 3.9 {
                    time += step
                    let frame = player.render(.init(position: time, playing: true), delta: step)
                    XCTAssertEqual(frame.lyricTime, time, accuracy: 0.001)
                    if let retirement = frame.rows[0].retirement {
                        XCTAssertEqual(retirement.startedAt, try XCTUnwrap(frame.rows[0].positionMotion?.startedAt), accuracy: 0.001)
                        XCTAssertTrue(frame.rows[0].fillComplete)
                        XCTAssertFalse(frame.rows[1].active)
                        XCTAssertFalse(frame.rows[1].fillComplete)
                        XCTAssertEqual(frame.rows[1].wordClock.time, 0)
                        seen = true
                        break
                    }
                }
                XCTAssertTrue(seen, "Retirement must start for advance \(advance), frame interval \(step)")
            }
        }
    }

    func testRetirementFinishesInFourTenthsAcrossFrameRatesAndFallbacks() throws {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            for spring in [true, false] {
                for scale in [true, false] {
                    var player = engine(spring: spring, scale: scale)
                    _ = player.render(.init(position: 0.1, playing: true), delta: 0)
                    _ = player.render(.init(position: 1.39, playing: true), delta: 1.29)
                    _ = player.render(.init(position: 1.41, playing: true), delta: 0)
                    var elapsed = 0.0
                    var frame = player.render(.init(position: 1.41, playing: true), delta: 0)
                    while elapsed < 0.4 {
                        let delta = min(step, 0.4 - elapsed)
                        frame = player.render(.init(position: 1.41, playing: true), delta: delta)
                        elapsed += delta
                    }
                    let row = frame.rows[0]
                    XCTAssertEqual(try XCTUnwrap(row.retirement).progress, 1, accuracy: 0.001)
                    XCTAssertEqual(row.brightAlpha, 0.2, accuracy: 0.001)
                    XCTAssertEqual(row.darkAlpha, 0.2, accuracy: 0.001)
                    XCTAssertTrue(row.fillComplete)
                    if !scale { XCTAssertEqual(row.scale, 1, accuracy: 0.001) }
                }
            }
        }
    }

    func testScrollAheadRetiresAStillSingingSequentialRowAtItsUpwardStart() throws {
        for advance in [0.3, 1.0] {
            for step in [1.0 / 60, 1.0 / 120, 0.037] {
                let lines = [(0.0, 3.0), (3.0, 5.0)].enumerated().map { index, span in
                    LyricLine(id: String(index), text: "Line \(index)", start: span.0, end: span.1,
                              words: [.init(text: "Line \(index)", start: span.0, end: span.1)], precision: .word)
                }
                var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
                environment.advance = advance
                environment.alignPosition = 0.28
                var player = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 60])
                let initial = player.render(.init(position: 0.1, playing: true), delta: 0).rows[0]
                var time = 0.1
                var moved = false
                while time < 3 - step {
                    time += step
                    let frame = player.render(.init(position: time, playing: true), delta: step)
                    let old = frame.rows[0]
                    guard old.y < initial.y else { continue }
                    let exit = try XCTUnwrap(old.retirement, "Scroll-ahead must retire before the actual word end")
                    XCTAssertEqual(exit.startedAt, try XCTUnwrap(old.positionMotion?.startedAt), accuracy: 0.001)
                    XCTAssertLessThan(old.scale, 1)
                    XCTAssertLessThan(old.brightAlpha * old.opacity, initial.brightAlpha * initial.opacity)
                    XCTAssertGreaterThan(old.blur, 0)
                    XCTAssertTrue(old.active, "Only appearance exits; real singing time stays unchanged")
                    XCTAssertFalse(old.fillComplete)
                    XCTAssertEqual(old.wordClock.time, time, accuracy: 0.001)
                    XCTAssertFalse(frame.rows[1].active)
                    let paused = player.render(.init(position: time, playing: false), delta: 0.5).rows[0]
                    XCTAssertEqual(try XCTUnwrap(paused.retirement).startedAt, exit.startedAt)
                    XCTAssertEqual(paused.brightAlpha, 0.2, accuracy: 0.001)
                    XCTAssertGreaterThan(paused.blur, 0)
                    let rewound = player.render(.init(position: 0.1, playing: true, seekRevision: 1), delta: 0).rows[0]
                    XCTAssertNil(rewound.retirement)
                    XCTAssertEqual(rewound.scale, 1, accuracy: 0.001)
                    XCTAssertEqual(rewound.blur, 0)
                    moved = true
                    break
                }
                XCTAssertTrue(moved)
            }
        }
    }

    func testScrollAheadKeepsGenuinelyOverlappingSingingRowsFocused() {
        let lines = [(0.0, 4.0), (3.0, 5.0)].enumerated().map { index, span in
            LyricLine(id: String(index), text: "Voice \(index)", start: span.0, end: span.1,
                      words: [.init(text: "Voice \(index)", start: span.0, end: span.1)], precision: .word)
        }
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.advance = 1
        var player = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 60])
        _ = player.render(.init(position: 0.1, playing: true), delta: 0)
        for index in 1 ... 390 {
            let frame = player.render(.init(position: 0.1 + Double(index) / 120, playing: true), delta: 1.0 / 120)
            XCTAssertTrue(frame.rows[0].active)
            XCTAssertNil(frame.rows[0].retirement)
            XCTAssertEqual(frame.rows[0].scale, 1, accuracy: 0.001)
            XCTAssertEqual(frame.rows[0].blur, 0)
        }
    }

    func testScrollAheadRetiresMainAndBackgroundIndependentlyOfTheirWordClocks() throws {
        // The source optimizer trims this short overlap for visual scheduling,
        // while the retained source clock still records the real overlap.
        for backgroundEnd in [3.0, 3.05] {
            let lines = [
                LyricLine(id: "main", text: "Main", start: 0, end: 3,
                          words: [.init(text: "Main", start: 0, end: 3)], precision: .word),
                LyricLine(id: "background", text: "Echo", start: 0.5, end: backgroundEnd,
                          words: [.init(text: "Echo", start: 0.5, end: backgroundEnd)], isBackground: true, precision: .word),
                LyricLine(id: "next", text: "Next", start: 3, end: 5,
                          words: [.init(text: "Next", start: 3, end: 5)], precision: .word),
            ]
            var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
            environment.advance = 1
            var player = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 30, 60])
            _ = player.render(.init(position: 0.1, playing: true), delta: 0)
            var frame = player.render(.init(position: 0.1, playing: true), delta: 0)
            var time = 0.1
            while frame.rows[0].retirement == nil, time < 2.9 {
                time += 1.0 / 120
                frame = player.render(.init(position: time, playing: true), delta: 1.0 / 120)
            }
            XCTAssertNotNil(frame.rows[0].retirement)
            let background = frame.rows[1]
            XCTAssertTrue(background.active)
            XCTAssertFalse(background.fillComplete)
            XCTAssertTrue(background.wordClock.enabled)
            if backgroundEnd == 3 {
                XCTAssertNotNil(background.retirement)
                XCTAssertGreaterThan(background.blur, 0)
            } else {
                XCTAssertNil(background.retirement, "Overlapping background voice keeps its own appearance")
                XCTAssertEqual(background.blur, 0)
            }
        }
    }

    func testScrollAheadStillDimsAndBlursWhenScaleAndPositionSpringAreDisabled() {
        let lines = [(0.0, 3.0), (3.0, 5.0)].enumerated().map { index, span in
            LyricLine(id: String(index), text: "Line \(index)", start: span.0, end: span.1,
                      words: [.init(text: "Line \(index)", start: span.0, end: span.1)], precision: .word)
        }
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.advance = 1
        environment.enableSpring = false
        environment.enableScale = false
        var player = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 60])
        _ = player.render(.init(position: 0.1, playing: true), delta: 0)
        var frame = player.render(.init(position: 0.1, playing: true), delta: 0)
        for index in 1 ... 312 {
            frame = player.render(.init(position: 0.1 + Double(index) / 120, playing: true), delta: 1.0 / 120)
        }
        XCTAssertNotNil(frame.rows[0].retirement)
        XCTAssertTrue(frame.rows[0].active)
        XCTAssertFalse(frame.rows[0].fillComplete)
        XCTAssertEqual(frame.rows[0].scale, 1)
        XCTAssertEqual(frame.rows[0].brightAlpha, 0.2, accuracy: 0.001)
        XCTAssertGreaterThan(frame.rows[0].blur, 0)
    }

    func testBackwardEndCorrectionDoesNotRetireTheRestoredVoiceAgain() {
        for spring in [false, true] {
            let lines = [(0.0, 1.0), (2.0, 3.0)].enumerated().map { index, span in
                LyricLine(id: String(index), text: "Line \(index)", start: span.0, end: span.1,
                          words: [.init(text: "Line \(index)", start: span.0, end: span.1)], precision: .word)
            }
            var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
            environment.advance = 0.3
            environment.enableSpring = spring
            environment.hidePassedLines = true
            var player = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 60])
            _ = player.render(.init(position: 0.1, playing: true), delta: 0)
            _ = player.render(.init(position: 1.01, playing: true), delta: 0.91)
            _ = player.render(.init(position: 1.11, playing: true), delta: 0.016)
            for index in 0 ..< 3 {
                // Cross the pending incoming row's staggered deadline too.
                let row = player.render(.init(position: 0.99 + Double(index) * 0.001, playing: true), delta: 0.04).rows[0]
                XCTAssertTrue(row.active)
                XCTAssertEqual(row.visualFocus, .current)
                XCTAssertNil(row.retirement)
                XCTAssertTrue(row.wordClock.enabled)
                XCTAssertGreaterThan(row.opacity, 0.1)
            }
        }
    }
}
