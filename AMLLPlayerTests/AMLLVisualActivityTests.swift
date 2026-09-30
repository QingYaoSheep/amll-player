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

    func testDelayedBackwardSeekClearsCompletionForEveryPreviouslySungVoice() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            for playing in [false, true] {
                var engine = makeEngine([(0, 4), (1, 3), (5, 8), (9, 12)], background: 1)
                _ = engine.render(.init(position: 0.2, playing: true), delta: 0)
                _ = engine.render(.init(position: 12.5, playing: true), delta: 12.3)
                engine.handle(.beginBrowsing)
                engine.handle(.browseBy(-120))
                // AppModel publishes the seek revision before Spotify returns its new position.
                _ = engine.render(.init(position: 12.5, playing: playing, seekRevision: 1), delta: step)
                let rewound = engine.render(.init(position: 1.5, playing: playing, seekRevision: 1), delta: step)
                XCTAssertFalse(rewound.browsing)
                for row in rewound.rows {
                    XCTAssertFalse(row.fillComplete, "A previous playthrough cannot fill the new timeline")
                    XCTAssertFalse(row.hdrHold)
                }
                XCTAssertTrue(rewound.rows[0].active)
                XCTAssertTrue(rewound.rows[1].active)
                XCTAssertEqual(rewound.rows[0].wordClock.time, 1.5, accuracy: 0.001)
                XCTAssertEqual(rewound.rows[1].wordClock.time, 0.5, accuracy: 0.001)
                let advancing = engine.render(.init(position: playing ? 1.5 + step : 1.5,
                                                    playing: playing, seekRevision: 1), delta: step)
                XCTAssertEqual(advancing.rows[0].wordClock.time, playing ? 1.5 + step : 1.5, accuracy: 0.001)
                XCTAssertFalse(advancing.rows[0].fillComplete)
                XCTAssertFalse(advancing.rows[2].fillComplete)
            }
        }
    }

    func testDelayedSeekWithinActiveSentenceReanchorsWordClock() {
        var engine = makeEngine([(0, 4), (5, 8)])
        _ = engine.render(.init(position: 3, playing: true), delta: 0)
        _ = engine.render(.init(position: 3, playing: true, seekRevision: 1), delta: 0)
        let rewound = engine.render(.init(position: 0.5, playing: true, seekRevision: 1), delta: 1 / 120)
        XCTAssertEqual(rewound.rows[0].wordClock.time, 0.5, accuracy: 0.001)
        XCTAssertFalse(rewound.rows[0].fillComplete)
        XCTAssertTrue(rewound.rows[0].active)
    }

    func testDelayedSeekIntoEarlierGapClearsFutureHoldAndKeepsPastFill() {
        var engine = makeEngine([(0, 1), (2, 3), (4, 5)])
        _ = engine.render(.init(position: 0.2, playing: true), delta: 0)
        _ = engine.render(.init(position: 5.2, playing: true), delta: 5)
        _ = engine.render(.init(position: 5.2, playing: true, seekRevision: 1), delta: 0)
        let rewound = engine.render(.init(position: 1.2, playing: true, seekRevision: 1), delta: 1 / 60)
        XCTAssertTrue(rewound.rows[0].fillComplete)
        for row in rewound.rows.dropFirst() {
            XCTAssertFalse(row.fillComplete)
            XCTAssertFalse(row.hdrHold)
            XCTAssertFalse(row.wordClock.enabled)
        }
        let singing = engine.render(.init(position: 2.2, playing: true, seekRevision: 1), delta: 1)
        XCTAssertFalse(singing.rows[1].fillComplete)
        XCTAssertTrue(singing.rows[1].active)
        XCTAssertEqual(singing.rows[1].wordClock.time, 0.2, accuracy: 0.001)
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

    func testIncomingBackgroundPreparesWithItsMainBeforeItsOwnSingingTime() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            var engine = makeEngine([(0, 1), (2, 4), (2.5, 3.5), (5, 6)], background: 2)
            _ = engine.render(.init(position: 0.1, playing: true), delta: 0)
            let waiting = engine.render(.init(position: 1.39, playing: true), delta: 1.29)
            let initialScale = waiting.rows[2].scale
            var prepared = engine.render(.init(position: 1.41, playing: true), delta: 0.02)
            for _ in 0 ..< 60 {
                if prepared.rows[1].visualFocus == .preparing {
                    break
                }
                prepared = engine.render(.init(position: 1.41, playing: true), delta: step)
            }
            XCTAssertEqual(prepared.rows[1].visualFocus, .preparing)
            XCTAssertEqual(prepared.rows[2].visualFocus, .preparing)
            XCTAssertGreaterThan(prepared.rows[2].scale, initialScale)
            XCTAssertGreaterThan(prepared.rows[2].opacity, 0)
            XCTAssertFalse(prepared.rows[2].hidden)
            XCTAssertFalse(prepared.rows[2].active)
            XCTAssertFalse(prepared.rows[2].wordClock.enabled)
            XCTAssertFalse(prepared.rows[2].hdrHold)
        }
    }

    func testBackwardClockCorrectionDoesNotRequeueRetirementOfASingingVoice() {
        for background in [false, true] {
            let spans: [(Double, Double)] = background ? [(0, 1), (0.1, 1), (2, 3)] : [(0, 1), (2, 3)]
            var engine = makeEngine(spans, advance: 0.3, background: background ? 1 : nil)
            _ = engine.render(.init(position: 0.1, playing: true), delta: 0)
            _ = engine.render(.init(position: 1.01, playing: true), delta: 0.91)
            _ = engine.render(.init(position: 1.11, playing: true), delta: 0.016)
            // Spotify can correct its clock across an end without an explicit seek.
            let corrected = engine.render(.init(position: 0.99, playing: true), delta: 0.016)
            for row in corrected.rows.prefix(background ? 2 : 1) {
                XCTAssertTrue(row.active)
                XCTAssertEqual(row.visualFocus, .current)
                XCTAssertTrue(row.wordClock.enabled)
            }
            XCTAssertEqual(corrected.lyricTime, 0.99, accuracy: 0.001)
        }
    }

    func testCompletedRowRetiresAtItsOwnUpwardStartBeforeIncomingSpringStarts() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            var engine = makeEngine([(0, 1), (2, 3)])
            _ = engine.render(.init(position: 0.1, playing: true), delta: 0)
            let held = engine.render(.init(position: 1.39, playing: true), delta: 1.29)
            XCTAssertEqual(held.rows[0].visualFocus, .holding)
            _ = engine.render(.init(position: 1.41, playing: true), delta: 0)
            let moved = engine.render(.init(position: 1.41, playing: true), delta: step)
            let outgoing = moved.rows[0]
            let incoming = moved.rows[1]
            XCTAssertLessThan(outgoing.y, held.rows[0].y)
            XCTAssertEqual(incoming.y, held.rows[1].y, accuracy: 0.001)
            XCTAssertNil(incoming.positionMotion?.startedAt)
            XCTAssertEqual(incoming.visualFocus, .waiting)
            XCTAssertEqual(outgoing.visualFocus, .passed)
            XCTAssertTrue(outgoing.fillComplete)
            XCTAssertFalse(outgoing.hdrHold)
            XCTAssertEqual(outgoing.brightAlpha, outgoing.darkAlpha, accuracy: 0.001)
            XCTAssertEqual(outgoing.darkAlpha, 0.2, accuracy: 0.001)
            XCTAssertGreaterThan(outgoing.blur, 0)
        }
    }

    func testCompletedHighlightReleasesWhileIncomingRowIsStillMoving() {
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            var engine = makeEngine([(0, 1), (2, 3)])
            _ = engine.render(.init(position: 0.1, playing: true), delta: 0)
            let held = engine.render(.init(position: 1.39, playing: true), delta: 1.29)
            XCTAssertEqual(held.rows[0].visualFocus, .holding)
            XCTAssertTrue(held.rows[0].hdrHold)
            var handoff = engine.render(.init(position: 1.41, playing: true), delta: 0.02)
            for _ in 0 ..< 60 {
                if handoff.rows[1].visualFocus == .preparing {
                    break
                }
                handoff = engine.render(.init(position: 1.41, playing: true), delta: step)
            }
            let incoming = handoff.rows[1]
            let outgoing = handoff.rows[0]
            XCTAssertEqual(incoming.visualFocus, .preparing)
            XCTAssertGreaterThan(abs(incoming.y - 700 * 0.28 - 32 * 0.4), 1)
            XCTAssertEqual(outgoing.visualFocus, .passed)
            XCTAssertTrue(outgoing.fillComplete)
            XCTAssertFalse(outgoing.hdrHold)
            XCTAssertEqual(outgoing.brightAlpha, outgoing.darkAlpha, accuracy: 0.001)
            XCTAssertEqual(outgoing.darkAlpha, 0.2, accuracy: 0.001)
            let settled = engine.render(.init(position: 1.41, playing: true), delta: 1)
            XCTAssertEqual(settled.rows[0].brightAlpha, settled.rows[0].darkAlpha, accuracy: 0.001)
        }
    }

    func testBackgroundSpacingHasNoSecondOuterGapAboveOrBelowMain() {
        for backgroundFirst in [false, true] {
            let lines = [
                LyricLine(id: "main", text: "Lead", start: backgroundFirst ? 1 : 0, end: 4,
                          words: [.init(text: "Lead", start: backgroundFirst ? 1 : 0, end: 4)], precision: .word),
                LyricLine(id: "echo", text: "Echo", start: 0, end: 4,
                          words: [.init(text: "Echo", start: 0, end: 4)], isBackground: true, precision: .word),
            ]
            var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                         environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32),
                                         heights: [60, 30])
            let frame = engine.render(.init(position: 2, playing: true), delta: 0)
            let gap = backgroundFirst ? frame.rows[0].y - frame.rows[1].y - 30
                : frame.rows[1].y - frame.rows[0].y - 60
            XCTAssertEqual(gap, 0, accuracy: 0.001)
        }
    }

    @MainActor
    func testBackgroundTextUsesCompactPaddingWithoutChangingMainLayout() throws {
        let line = LyricLine(id: "echo", text: "Echo", start: 0, end: 4,
                             words: [.init(text: "Echo", start: 0, end: 4)], isBackground: true, precision: .word)
        let font = UIFont.systemFont(ofSize: 22.4)
        let background = AMLLCoreTextLayout(line: line, width: 360, font: font, configuration: .init())
        var main = line
        main.isBackground = false
        let lead = AMLLCoreTextLayout(line: main, width: 360, font: font, configuration: .init())
        let backgroundWord = try XCTUnwrap(background.fragments.first)
        let mainWord = try XCTUnwrap(lead.fragments.first)
        XCTAssertEqual(backgroundWord.rect.minY - mainWord.rect.minY, font.pointSize * 0.4, accuracy: 0.001)
        XCTAssertEqual(background.size.height - lead.size.height, font.pointSize * 0.8, accuracy: 0.001)
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
