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
}
