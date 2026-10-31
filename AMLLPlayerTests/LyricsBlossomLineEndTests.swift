@testable import AMLLPlayer
import XCTest

final class LyricsBlossomLineEndTests: XCTestCase {
    func testRowDelayFiltersSourceFlagsAndDoesNotCountWordsOrViewportRows() {
        let rows: [LyricsBlossomLineSchedule.Row] = [
            .init(start: 0), .init(start: 1, flag1B0: true), .init(start: 2),
            .init(start: 3, flag1B2: true), .init(start: 4, containsWordFlag28: true),
            .init(start: 5), .init(start: 6, flag1B3: true),
        ]
        let schedule = LyricsBlossomLineSchedule(rows: rows)
        XCTAssertEqual(schedule.delay(after: 0, through: 2), 0)
        XCTAssertEqual(schedule.delay(after: 0, through: 5), 0.05)
        // 1B3 blocks advance, but is not one of the delay-count filters.
        XCTAssertEqual(schedule.delay(after: 0, through: 6), 0.1)
        XCTAssertEqual(schedule.delay(after: 2, through: 6), 0.05)
        XCTAssertEqual(schedule.delay(after: -1, through: 6), 0)
        XCTAssertEqual(schedule.delay(after: 0, through: 99), 0)
        XCTAssertEqual(LyricsBlossomLineSchedule.multiLineDelay(rank: 3), 0.1)
    }

    func testAdvanceUsesSelectedRowStartAndAllSourceGuards() {
        typealias Row = LyricsBlossomLineSchedule.Row
        func predicate(_ row: Row? = .init(start: 10), now: Double = 9.11, family: Int = 0,
                       paused: Bool = false, hidden: Bool = false, scrubbing: Bool = false) -> Bool {
            LyricsBlossomAdvanceState(now: now, family: family, lastSelectedRow: row,
                                      paused: paused, hidden: hidden, scrubbing: scrubbing).satisfied
        }
        XCTAssertFalse(predicate(now: 9.09))
        XCTAssertTrue(predicate())
        XCTAssertFalse(predicate(nil))
        XCTAssertFalse(predicate(now: .nan))
        XCTAssertFalse(predicate(family: 2)); XCTAssertFalse(predicate(family: 3))
        XCTAssertFalse(predicate(paused: true)); XCTAssertFalse(predicate(hidden: true))
        XCTAssertFalse(predicate(scrubbing: true))
        for row in [Row(start: 10, flag1B0: true), Row(start: 10, flag1B2: true),
                    Row(start: 10, flag1B3: true), Row(start: 10, containsWordFlag28: true)] {
            XCTAssertFalse(predicate(row))
        }
        XCTAssertTrue(LyricsBlossomLineSchedule.clearsDelay(wordVersion: 1, paused: false, hidden: false, advanceSatisfied: false))
        XCTAssertFalse(LyricsBlossomLineSchedule.clearsDelay(wordVersion: 0, paused: false, hidden: false, advanceSatisfied: false))
    }

    func testRemovingPendingWaitPreservesMotionAndDoesNotRescheduleStartedRows() {
        for interval in [1.0 / 60, 1.0 / 120, 0.037] {
            var spring = AMLLScheduledSpring(40)
            spring.selectStyle(.appleMusic164)
            let p = LyricsAnimationMotion(style: .appleMusic164).initialVertical.sourceParameters
            spring.updateParameters(p)
            spring.setTarget(140, startTime: 0.5, at: 0, revision: 3)
            spring.advance(to: 0.1)
            let before = spring.position
            XCTAssertTrue(spring.clearPendingDelay(at: 0.1))
            XCTAssertEqual(spring.position, before)
            XCTAssertEqual(spring.velocity, 0)
            XCTAssertEqual(spring.schedule.startedAt, 0.1)
            XCTAssertEqual(spring.schedule.revision, 3)
            spring.advance(to: 0.1 + interval)
            let sample = LyricsBlossomSpring.sample(from: 40, to: 140, velocity: 0, time: interval,
                                                     parameters: .init(mass: 1, damping: 18, stiffness: 100))
            XCTAssertEqual(spring.position, sample.position, accuracy: 1e-8)
            XCTAssertFalse(spring.clearPendingDelay(at: 0.1 + interval))
            XCTAssertEqual(spring.schedule.startedAt, 0.1)
        }
    }

    func testRunRecordsMergeEqualTimingAndRetainSourceTimeNodes() {
        let records = LyricsBlossomRunSweep.segments([
            .init(start: 1, end: 2, width: 20, text: "a "),
            .init(start: 1, end: 2, width: 40, text: "字"),
            .init(start: 3, end: 5, width: 50, text: "tail"),
        ])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].distance, 60)
        XCTAssertEqual(records[0].nonSpaceByteCount, 4) // UTF-8 byte count, not Swift Character count.
        XCTAssertEqual(records[0].start, 1); XCTAssertEqual(records[0].end, 2)
        XCTAssertEqual(records[1].start, 3); XCTAssertEqual(records[1].end, 5)
        XCTAssertTrue(records[1].final)
        XCTAssertEqual(records[1].distance, 110)
    }

    @MainActor
    func testProductionApplePauseClearsQueuedRowWaitWhileAMLLKeepsItsSchedule() throws {
        let lines: [LyricLine] = (0 ..< 5).map { index in
            let start = Double(index) * 2
            let end = start + 1.8
            let word = LyricWord(text: "Row", start: start, end: end)
            return LyricLine(id: "row-\(index)", text: "Row", start: start, end: end,
                             words: [word], precision: .word)
        }
        let document = AMLLDisplayDocument(lines: lines)
        for style in [LyricsAnimationStyle.amll, .appleMusic164] {
            var environment = AMLLRenderEnvironment(width: 400, height: 900, screenWidth: 400, fontSize: 32)
            environment.animationStyle = style
            var engine = AMLLFrameEngine(document: document, environment: environment, heights: Array(repeating: 50, count: 5))
            _ = engine.render(.init(position: 0, playing: true), delta: 0)
            let queued = engine.render(.init(position: 1.71, playing: true), delta: 0.01)
            let before = try XCTUnwrap(queued.rows.first { $0.groupIndex == 3 })
            XCTAssertNil(before.positionMotion?.startedAt)
            XCTAssertGreaterThan(try XCTUnwrap(before.positionMotion?.scheduledAt), 0.01)
            let paused = engine.render(.init(position: 1.71, playing: false), delta: 1.0 / 120)
            let after = try XCTUnwrap(paused.rows.first { $0.groupIndex == 3 })
            if style == .appleMusic164 {
                XCTAssertEqual(try XCTUnwrap(after.positionMotion?.startedAt), 0.01, accuracy: 1e-10)
                XCTAssertNotEqual(after.y, after.positionMotion?.target)
                XCTAssertEqual(after.positionMotion?.target, before.positionMotion?.target)
            } else {
                XCTAssertNil(after.positionMotion?.startedAt)
                XCTAssertEqual(after.positionMotion?.scheduledAt, before.positionMotion?.scheduledAt)
            }
        }
    }

    func testRunTargetKeepsLongFinalWordUntilItsRealEnd() {
        let records = LyricsBlossomRunSweep.segments([
            .init(start: 1, end: 2, width: 60, text: "a"),
            .init(start: 3, end: 5, width: 40, text: "tail"),
        ])
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 0, segments: records), 0)
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 1.5, segments: records), 37.5)
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 3, segments: records), 60)
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 4, segments: records), 95)
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 5, segments: records), 130)
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 1.5, segments: records), 37.5) // Reverse seek: no retained full-fill flag.
    }

    func testPauseStartsQueuedHandoffAndRetirementAtTheMovementBoundaryOnce() throws {
        let lines: [LyricLine] = (0 ..< 5).map { index in
            let start = Double(index) * 2
            let end = start + 1.8
            return LyricLine(id: String(index), text: "Row", start: start, end: end,
                             words: [LyricWord(text: "Row", start: start, end: end)], precision: .word)
        }
        for interval in [1.0 / 60, 1.0 / 120, 0.037] {
            var environment = AMLLRenderEnvironment(width: 400, height: 900, screenWidth: 400, fontSize: 32)
            environment.alignPosition = 0.5 // Both the outgoing and incoming row have queued waits.
            environment.animationStyle = .appleMusic164
            var engine = AMLLFrameEngine(document: .init(lines: lines), environment: environment,
                                         heights: Array(repeating: 50, count: lines.count))
            _ = engine.render(.init(position: 2.1, playing: true), delta: 0)
            let queued = engine.render(.init(position: 3.71, playing: true), delta: 0.01)
            let outgoingBefore = try XCTUnwrap(queued.rows.first { $0.lineIndex == 1 })
            let incomingBefore = try XCTUnwrap(queued.rows.first { $0.lineIndex == 2 })
            XCTAssertNil(outgoingBefore.retirement)
            XCTAssertNil(outgoingBefore.positionMotion?.startedAt)
            XCTAssertNil(incomingBefore.positionMotion?.startedAt)
            XCTAssertEqual(incomingBefore.visualFocus, .waiting)

            let paused = engine.render(.init(position: 3.71, playing: false), delta: interval)
            let outgoing = try XCTUnwrap(paused.rows.first { $0.lineIndex == 1 })
            let incoming = try XCTUnwrap(paused.rows.first { $0.lineIndex == 2 })
            let exit = try XCTUnwrap(outgoing.retirement)
            XCTAssertEqual(exit.startedAt, 0.01, accuracy: 1e-10)
            XCTAssertEqual(exit.startedAt, try XCTUnwrap(outgoing.positionMotion?.startedAt))
            XCTAssertEqual(incoming.positionMotion?.startedAt, exit.startedAt)
            XCTAssertEqual(outgoing.visualFocus, .passed)
            XCTAssertEqual(incoming.visualFocus, .preparing)
            XCTAssertGreaterThan(exit.progress, 0)
            XCTAssertLessThan(exit.progress, 1)
            XCTAssertGreaterThan(outgoing.scale, 0.98)
            XCTAssertLessThan(outgoing.scale, outgoingBefore.scale)
            XCTAssertLessThan(outgoing.brightAlpha, outgoingBefore.brightAlpha)
            XCTAssertGreaterThan(outgoing.blur, 0)
            XCTAssertLessThan(exit.hdrWeight, 1)

            let next = engine.render(.init(position: 3.71, playing: false), delta: interval)
            let continued = try XCTUnwrap(next.rows.first { $0.lineIndex == 1 }?.retirement)
            XCTAssertEqual(continued.startedAt, exit.startedAt) // No second activation on the next layout/frame.
            XCTAssertGreaterThan(continued.progress, exit.progress)
            XCTAssertEqual(next.lyricTime, paused.lyricTime) // Appearance finishes without advancing song time.
        }
    }

    func testRunWindowUsesSpatialCursorAndSearchSentinelWithoutTripleAlpha() throws {
        let window = try XCTUnwrap(LyricsBlossomRunSweep.window(cursor: 95, wordPositions: [20, 80], alpha: 0.4))
        XCTAssertEqual(window.start, 83)
        XCTAssertEqual(window.end, 113)
        XCTAssertEqual(window.alpha, 0.4)
        let clamped = try XCTUnwrap(LyricsBlossomRunSweep.window(cursor: -10, wordPositions: [20], alpha: 2))
        XCTAssertEqual(clamped.start, -12); XCTAssertEqual(clamped.end, 18)
        XCTAssertEqual(clamped.alpha, 1)
        let sentinel = try XCTUnwrap(LyricsBlossomRunSweep.window(cursor: 0, wordPositions: [12_000], alpha: 1))
        XCTAssertEqual(sentinel.end, 9_998)
        XCTAssertNil(LyricsBlossomRunSweep.window(cursor: 0, wordPositions: [], alpha: 1))
        XCTAssertNil(LyricsBlossomRunSweep.window(cursor: .nan, wordPositions: [0], alpha: 1))
    }

    func testThreeRecordRunUsesDecodedShortAndLongWordCoefficients() {
        let records = LyricsBlossomRunSweep.segments([
            .init(start: 0, end: 1, width: 60, text: "abc"),
            .init(start: 1, end: 2, width: 40, text: "a"),
            .init(start: 2, end: 7, width: 100, text: "long"),
        ])
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 0.5, segments: records), 31.8, accuracy: 0.00001)
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 1.5, segments: records), 83.75)
        XCTAssertEqual(LyricsBlossomRunSweep.target(now: 4.5, segments: records), 165)
    }
}
