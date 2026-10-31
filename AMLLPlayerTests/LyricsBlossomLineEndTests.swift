@testable import AMLLPlayer
import XCTest

final class LyricsBlossomLineEndTests: XCTestCase {
    func testRowDelayFiltersSourceFlagsAndDoesNotCountWordsOrViewportRows() {
        let rows: [LyricsBlossomLineSchedule.Row] = [
            .init(time18: 0), .init(time18: 1, flag1B0: true), .init(time18: 2),
            .init(time18: 3, flag1B2: true), .init(time18: 4, containsWordFlag28: true),
            .init(time18: 5), .init(time18: 6, flag1B3: true),
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

    func testAdvanceUsesSelectedRowTimeFieldAndAllSourceGuards() {
        typealias Row = LyricsBlossomLineSchedule.Row
        func predicate(_ row: Row? = .init(time18: 10), now: Double = 9.11, family: Int = 0,
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
        for row in [Row(time18: 10, flag1B0: true), Row(time18: 10, flag1B2: true),
                    Row(time18: 10, flag1B3: true), Row(time18: 10, containsWordFlag28: true)] {
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
            XCTAssertEqual(continued.startedAt, exit.startedAt) // No second activation on the next frame.
            XCTAssertGreaterThan(continued.progress, exit.progress)
            XCTAssertEqual(next.lyricTime, paused.lyricTime) // Appearance finishes without advancing song time.

            // A refresh-rate update invalidates layout without changing its geometry.
            environment.maximumFPS = 120
            engine.resize(environment: environment, heights: Array(repeating: 50, count: lines.count))
            let relaid = engine.render(.init(position: 3.71, playing: false), delta: interval)
            let afterLayout = try XCTUnwrap(relaid.rows.first { $0.lineIndex == 1 })
            XCTAssertEqual(afterLayout.retirement?.startedAt, exit.startedAt)
            XCTAssertEqual(afterLayout.positionMotion?.startedAt, outgoing.positionMotion?.startedAt)
            XCTAssertGreaterThan(try XCTUnwrap(afterLayout.retirement?.progress), continued.progress)
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

    private var cursorSegments: [LyricsBlossomRunSweep.Segment] {
        LyricsBlossomRunSweep.segments([
            .init(start: 1, end: 2, width: 60, text: "a"),
            .init(start: 3, end: 5, width: 40, text: "tail"),
        ])
    }

    func testCursorFirstEntryUsesPreviousDistanceAndFinalDurationGuard() {
        var cursor = LyricsBlossomRunSweep.Cursor()
        cursor.step(now: 3.25, delta: 0, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.value, 60)
        XCTAssertEqual(cursor.from, 60)
        XCTAssertEqual(cursor.to, 130)
        XCTAssertEqual(cursor.duration, 3.5)
        XCTAssertEqual(cursor.lastIndex, 1)
        XCTAssertTrue(cursor.active)
    }

    func testCursorFinishedTweenDoesNotRestartInsideTheSameSegment() {
        var cursor = LyricsBlossomRunSweep.Cursor(value: 67.5, from: 0, to: 75,
            elapsed: 0.09, duration: 0.1, active: true, lastIndex: 0)
        cursor.step(now: 1.5, delta: 0.02, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.value, 75)
        XCTAssertFalse(cursor.active)
        XCTAssertEqual(cursor.lastIndex, 0)
        let finished = cursor
        cursor.step(now: 1.6, delta: 0.1, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor, finished)
    }

    func testCursorAfterEndKeepsExistingTweenThenSnapsOnTheFollowingCall() {
        var cursor = LyricsBlossomRunSweep.Cursor(value: 40, from: 0, to: 80,
            elapsed: 0.5, duration: 1, active: true, lastIndex: 1)
        cursor.step(now: 6, delta: 0.1, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.value, 48, accuracy: 0.00001)
        XCTAssertEqual(cursor.to, 80)
        XCTAssertEqual(cursor.lastIndex, -1)
        cursor.step(now: 6, delta: 1, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.value, 80)
        XCTAssertFalse(cursor.active)
        cursor.step(now: 6, delta: 0, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.value, 130)
    }

    func testForcedCursorFollowsTheDecodedTimeConstantAcrossFrameIntervals() {
        for interval in [Float(1) / 60, Float(1) / 120, Float(0.037)] {
            var cursor = LyricsBlossomRunSweep.Cursor(suppressed: true)
            var elapsed: Float = 0
            while elapsed < 0.2 {
                let delta = min(interval, 0.2 - elapsed)
                cursor.step(now: 1.5, delta: delta, segments: cursorSegments, force: true)
                elapsed += delta
            }
            let expected: Float = 37.5 * (1 - exp(-0.2 / 0.0833333358))
            XCTAssertEqual(cursor.value, expected, accuracy: 0.0001)
            XCTAssertEqual(cursor.from, cursor.value)
            XCTAssertEqual(cursor.to, cursor.value)
            XCTAssertEqual(cursor.elapsed, 0)
            XCTAssertEqual(cursor.duration, 1)
            XCTAssertEqual(cursor.lastIndex, -2)
            XCTAssertFalse(cursor.active)
            XCTAssertFalse(cursor.suppressed)
        }
    }

    func testReturningFromForceBeforeStartClearsElapsedAndUsesQuarterSecond() {
        var cursor = LyricsBlossomRunSweep.Cursor(value: 100, from: 100, to: 100,
            elapsed: 0.7, duration: 1, lastIndex: -2)
        cursor.step(now: 0, delta: 0.05, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.value, 80)
        XCTAssertEqual(cursor.elapsed, 0.05)
        XCTAssertEqual(cursor.duration, 0.25)
        XCTAssertEqual(cursor.lastIndex, -1)
        cursor = .init(value: 20, lastIndex: -2)
        cursor.step(now: 3.25, delta: 0, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.from, 20)
        XCTAssertEqual(cursor.duration, 0.25) // This path skips final-duration scaling.
    }

    func testCursorResyncIsConditionalAndUsesStrictSegmentStart() {
        var cursor = LyricsBlossomRunSweep.Cursor(value: 12, from: 4, to: 30,
            elapsed: 0.2, duration: 1, active: true, lastIndex: 0, suppressed: true)
        let before = cursor
        cursor.resync(effectiveTime: 3, resetRuns: false, segments: cursorSegments)
        XCTAssertEqual(cursor, before)
        cursor.resync(effectiveTime: 3, resetRuns: true, segments: cursorSegments)
        XCTAssertEqual(cursor.value, 90)
        XCTAssertEqual(cursor.lastIndex, 0)
        XCTAssertFalse(cursor.suppressed)
        cursor.resync(effectiveTime: 3.1, resetRuns: true, segments: cursorSegments)
        XCTAssertEqual(cursor.value, 130)
        XCTAssertEqual(cursor.lastIndex, 1)
        cursor.resync(effectiveTime: 1, resetRuns: true, segments: cursorSegments)
        XCTAssertEqual(cursor, .init())
    }

    func testRawRowGateDoesNotInvertTheMainAndAdvanceOnlyPaths() {
        var cursor = LyricsBlossomRunSweep.Cursor()
        cursor.stepRow(now: 1.5, delta: 0, segments: cursorSegments, flag40: false, flag41: false, force: false)
        XCTAssertTrue(cursor.active)
        XCTAssertEqual(cursor.to, 75)
        cursor = .init()
        cursor.stepRow(now: 0.95, delta: 0, segments: cursorSegments, flag40: true, flag41: false, force: false)
        XCTAssertEqual(cursor, .init())
        cursor.stepRow(now: 0.95, delta: 0, segments: cursorSegments, flag40: true, flag41: true, force: false)
        XCTAssertTrue(cursor.active) // +0.1 applies only with raw flag40.
        XCTAssertEqual(cursor.lastIndex, 0)
    }

    func testMergedSegmentsKeepCumulativeWidthsAndNonSpaceUTF8Bytes() {
        let segments = LyricsBlossomRunSweep.segments([
            .init(start: 1, end: 2, width: 20, text: "가 "),
            .init(start: 1, end: 2, width: 40, text: "e\u{301}"),
            .init(start: 3, end: 4, width: 10, text: "字"),
            .init(start: 4, end: 5, width: 5, text: "tail"),
        ])
        XCTAssertEqual(segments.map(\.distance), [60, 70, 75])
        XCTAssertEqual(segments.map(\.nonSpaceByteCount), [6, 3, 4])
        XCTAssertEqual(LyricsBlossomRunSweep.overshoot(segments[0], count: segments.count), 0.12)
    }

    func testSuppressedCursorAdvancesExistingMotionWithoutRetargeting() {
        var cursor = LyricsBlossomRunSweep.Cursor(value: 30, from: 0, to: 60,
            elapsed: 0.5, duration: 1, active: true, lastIndex: 0, suppressed: true)
        cursor.step(now: 3.5, delta: 0.1, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.value, 36, accuracy: 0.00001)
        XCTAssertEqual(cursor.to, 60)
        XCTAssertEqual(cursor.lastIndex, 0)
        XCTAssertTrue(cursor.suppressed)
    }

    func testNonPositiveDurationFallsBackToOneAndOvershotFinalKeepsItsDuration() {
        var segments = cursorSegments
        segments[0].end = segments[0].start
        var cursor = LyricsBlossomRunSweep.Cursor()
        cursor.step(now: 1, delta: 0, segments: segments, force: false)
        XCTAssertEqual(cursor.duration, 1)
        cursor = .init(value: 140, from: 140, to: 140, lastIndex: 0)
        cursor.step(now: 3.5, delta: 0, segments: cursorSegments, force: false)
        XCTAssertEqual(cursor.from, 140)
        XCTAssertEqual(cursor.to, 130)
        XCTAssertEqual(cursor.duration, 2)
    }
}
