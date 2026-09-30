@testable import AMLLPlayer
import UIKit
import XCTest

final class AMLLVisualActivityTests: XCTestCase {
    private func makeEngine(_ spans: [(Double, Double)], advance: Double = 0,
                            scale: Bool = true, background: Int? = nil) -> AMLLFrameEngine
    {
        let lines = spans.enumerated().map { index, span in
            LyricLine(id: String(index), text: "Line \(index)", start: span.0, end: span.1,
                      words: [.init(text: "Line \(index)", start: span.0, end: span.1)],
                      isBackground: index == background, precision: .word)
        }
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.alignPosition = 0.28
        environment.advance = advance
        environment.enableScale = scale
        return AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines), environment: environment,
                               heights: Array(repeating: 60, count: lines.count))
    }

    func testOverlappingRowsSingIndependentlyWithoutStealingScrollAnchor() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            var engine = makeEngine([(0, 4), (1, 3), (1.5, 5), (6, 7)])
            _ = engine.render(.init(position: 0.2, playing: true), delta: 0)
            var frame = engine.render(.init(position: 2, playing: true), delta: step)
            for _ in 0 ..< Int(1 / step) {
                frame = engine.render(.init(position: 2, playing: true), delta: step)
            }
            XCTAssertEqual(frame.focusGroup, 0)
            for row in frame.rows.prefix(3) {
                XCTAssertTrue(row.active)
                XCTAssertEqual(row.visualFocus, .current)
                XCTAssertGreaterThan(row.scale, 0.995)
                XCTAssertGreaterThan(row.brightAlpha - row.darkAlpha, 0.5)
                XCTAssertEqual(row.blur, 0)
                XCTAssertTrue(row.wordClock.enabled)
            }
            XCTAssertFalse(frame.rows[3].active)
        }
    }

    func testDraggingKeepsPositionDirectButDoesNotFreezeSingingAppearance() {
        var engine = makeEngine([(0, 1), (2, 4), (5, 6)])
        _ = engine.render(.init(position: 0.2, playing: true), delta: 0)
        engine.handle(.beginBrowsing)
        let before = engine.render(.init(position: 0.2, playing: true), delta: 0)
        engine.handle(.browseBy(40))
        let dragged = engine.render(.init(position: 0.2, playing: true), delta: 0)
        XCTAssertEqual(dragged.rows[0].y, before.rows[0].y - 40, accuracy: 0.1)
        let onset = engine.render(.init(position: 2.05, playing: true), delta: 1.0 / 120)
        XCTAssertTrue(onset.browsing)
        XCTAssertEqual(onset.rows[1].visualFocus, .current)
        XCTAssertLessThan(onset.rows[1].scale, 0.995, "Appearance must animate instead of snapping during drag")
        var moving = onset
        for _ in 0 ..< 90 {
            moving = engine.render(.init(position: 2.5, playing: true), delta: 1.0 / 120)
        }
        XCTAssertGreaterThan(moving.rows[1].scale, onset.rows[1].scale)
        XCTAssertGreaterThan(moving.rows[1].brightAlpha - moving.rows[1].darkAlpha, 0.4)
        XCTAssertEqual(moving.rows[0].visualFocus, .passed)
        XCTAssertTrue(moving.rows.allSatisfy { $0.blur == 0 })
        engine.handle(.endBrowsing(velocity: 0))
        XCTAssertTrue(engine.render(.init(position: 4.9, playing: true), delta: 0.1).browsing)
        XCTAssertFalse(engine.render(.init(position: 5, playing: true), delta: 0.1).browsing)
    }

    func testBackgroundUsesItsOwnSingingBoundaries() {
        var engine = makeEngine([(0, 4), (1, 2), (5, 6)], background: 1)
        let early = engine.render(.init(position: 0.2, playing: true), delta: 0)
        XCTAssertTrue(early.rows[0].active)
        XCTAssertFalse(early.rows[1].active)
        let singing = engine.render(.init(position: 1.2, playing: true), delta: 1)
        XCTAssertTrue(singing.rows[1].active)
        let ended = engine.render(.init(position: 2.2, playing: true), delta: 1)
        XCTAssertFalse(ended.rows[1].active)
        XCTAssertTrue(ended.rows[0].active)
        XCTAssertEqual(ended.rows[1].visualFocus, .holding)
        XCTAssertTrue(ended.rows[1].fillComplete)
        XCTAssertTrue(ended.rows[1].hdrHold)
        let next = engine.render(.init(position: 5.1, playing: true), delta: 2.9)
        XCTAssertFalse(next.rows[1].hdrHold)
    }

    func testDisablingScaleDoesNotHighlightEveryWaitingRow() {
        var engine = makeEngine([(0, 4), (1, 3), (6, 7)], scale: false)
        var frame = engine.render(.init(position: 2, playing: true), delta: 0)
        for _ in 0 ..< 120 {
            frame = engine.render(.init(position: 2, playing: true), delta: 1 / 120)
        }
        XCTAssertGreaterThan(frame.rows[0].brightAlpha - frame.rows[0].darkAlpha, 0.5)
        XCTAssertGreaterThan(frame.rows[1].brightAlpha - frame.rows[1].darkAlpha, 0.5)
        XCTAssertEqual(frame.rows[2].brightAlpha, frame.rows[2].darkAlpha, accuracy: 0.001)
        XCTAssertEqual(frame.rows[2].darkAlpha, 0.2, accuracy: 0.001)
    }

    func testAppearanceAdvancesOnlyAfterTheSharedPositionDeadline() throws {
        var engine = makeEngine([(0, 1), (2, 3)], advance: 0.3)
        _ = engine.render(.init(position: 0.1, playing: true), delta: 0)
        _ = engine.render(.init(position: 1.09, playing: true), delta: 0.99)
        let waiting = engine.render(.init(position: 1.1, playing: true), delta: 0)
        let deadline = try XCTUnwrap(waiting.rows[1].positionMotion?.scheduledAt)
        var fine = engine
        var time = waiting.animationTime
        let end = deadline + 0.04
        while time < end {
            let delta = min(1.0 / 120, end - time)
            _ = fine.render(.init(position: 1.1, playing: true), delta: delta)
            time += delta
        }
        let fineFrame = fine.render(.init(position: 1.1, playing: true), delta: 0)
        let coarse = engine.render(.init(position: 1.1, playing: true), delta: end - waiting.animationTime)
        XCTAssertEqual(coarse.rows[1].visualFocus, .preparing)
        XCTAssertFalse(coarse.rows[1].active)
        XCTAssertEqual(coarse.rows[1].scale, fineFrame.rows[1].scale, accuracy: 0.000_001)
        XCTAssertEqual(coarse.rows[1].y, fineFrame.rows[1].y, accuracy: 0.1)
        XCTAssertEqual(coarse.rows[1].positionMotion?.startedAt, deadline)
    }

    func testAppearanceUpdatesDoNotRescheduleBottomRows() throws {
        var engine = makeEngine([(0, 1), (2, 3), (4, 5), (6, 7), (8, 9), (10, 11)])
        _ = engine.render(.init(position: 0.2, playing: true), delta: 0)
        let scheduled = engine.render(.init(position: 1.41, playing: true), delta: 0)
        let deadline = try XCTUnwrap(scheduled.rows[5].positionMotion?.scheduledAt)
        for step in [0.01, 0.017, 0.041, 0.009, 0.04] {
            var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
            environment.alignPosition = 0.28
            environment.advance = 0
            environment.enableBlur = false
            engine.resize(environment: environment, heights: Array(repeating: 60, count: 6))
            let next = engine.render(.init(position: 1.41, playing: true), delta: step)
            XCTAssertEqual(next.rows[5].positionMotion?.scheduledAt, deadline)
        }
        let moved = engine.render(.init(position: 1.41, playing: true), delta: 0.5)
        XCTAssertEqual(moved.rows[5].positionMotion?.startedAt, deadline)
        XCTAssertLessThan(moved.rows[5].y, scheduled.rows[5].y)
    }

    @MainActor
    func testRealCanvasUpdatesBothOverlappingRowsAndExportsSubmissionTiming() throws {
        let lines = [
            LyricLine(id: "a", text: "First voice", start: 0, end: 5,
                      words: [.init(text: "First voice", start: 0, end: 5)], precision: .word),
            LyricLine(id: "b", text: "Second voice", start: 1, end: 4,
                      words: [.init(text: "Second voice", start: 1, end: 4)], precision: .word),
        ]
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "overlap-regression",
                                                       title: "Overlap", artists: ["Fixture"]),
                                      lines: lines, language: "en", selectionReason: "Regression fixture")
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.stop(); canvas.removeFromSuperview() }
        canvas.position = { 2 }
        canvas.configure(document: document, configuration: .init(), input: .init(position: 2, playing: true),
                         active: false, reduceMotion: false)
        for _ in 0 ..< 120 {
            canvas.advanceFrame(delta: 1 / 120)
        }
        let frame = try XCTUnwrap(canvas.frameState)
        XCTAssertEqual(frame.rows.filter(\.active).count, 2)
        XCTAssertTrue(frame.rows.allSatisfy { $0.brightAlpha > $0.darkAlpha })
        XCTAssertEqual(canvas.visibleRowCount, 2)
        let submissions = try XCTUnwrap(canvas.resourceCounts.submissions)
        XCTAssertEqual(submissions.count, 2)
        XCTAssertTrue(submissions.allSatisfy { $0.firstSubmittedAt != nil })
    }
}
