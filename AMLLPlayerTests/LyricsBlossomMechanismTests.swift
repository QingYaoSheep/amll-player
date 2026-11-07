@testable import AMLLPlayer
import XCTest

final class LyricsBlossomMechanismTests: XCTestCase {
    private func layout() -> LyricsBlossomRunLayout {
        .init(text: "ab", pieces: [
            .init(range: .init(location: 0, length: 1), width: 60, start: 0, end: 1),
            .init(range: .init(location: 1, length: 1), width: 40, start: 1, end: 2),
        ], pixelsPerPoint: 1)
    }
    func testCrossGroupTimeDistributionPreservesSourceInterval() {
        let layout = LyricsBlossomRunLayout(text: "abcd", pieces: [
            .init(range: .init(location: 0, length: 2), width: 30, start: 2, end: 6, group: 0, source: 9),
            .init(range: .init(location: 2, length: 2), width: 70, start: 2, end: 6, group: 1, source: 9),
        ], pixelsPerPoint: 1)
        XCTAssertEqual(layout.records.count, 2)
        XCTAssertEqual(layout.records[0][0].start, 2)
        XCTAssertEqual(layout.records[0][0].end, 3.2, accuracy: 0.00001)
        XCTAssertEqual(layout.records[1][0].start, 3.2, accuracy: 0.00001)
        XCTAssertEqual(layout.records[1][0].end, 6)
    }
    func testSegmentsMergeEqualTimesAndCountUTF8Bytes() {
        let layout = LyricsBlossomRunLayout(text: "你 a", pieces: [
            .init(range: .init(location: 0, length: 2), width: 30, start: 0, end: 1),
            .init(range: .init(location: 2, length: 1), width: 10, start: 0, end: 1),
        ], pixelsPerPoint: 1)
        XCTAssertEqual(layout.records[0].count, 1)
        XCTAssertEqual(layout.records[0][0].distance, 40)
        XCTAssertEqual(layout.records[0][0].nonSpaceByteCount, 4)
    }
    func testCatchUpIsContinuousAndRepeatedEventDoesNotRestart() {
        let segments = layout().records[0]
        var cursor = LyricsBlossomRunSweep.Cursor()
        cursor.reconstruct(now: 0.5, segments: segments)
        let initial = cursor.value
        cursor.catchUp(segments: segments)
        cursor.step(now: 0.6, delta: 0.1, segments: segments, force: false)
        XCTAssertEqual(cursor.value, initial + (130 - initial) * 0.4, accuracy: 0.0001)
        cursor.catchUp(segments: segments)
        XCTAssertEqual(cursor.elapsed, 0.1)
        XCTAssertTrue(cursor.suppressed)
        cursor.step(now: 0.75, delta: 0.15, segments: segments, force: false)
        XCTAssertEqual(cursor.value, 130, accuracy: 0.0001)
    }
    func testEngineStoreRetainsOffscreenCursorAndFreezesPause() {
        let store = LyricsBlossomRunStore(), layout = layout()
        store.beginFrame(.init(time: 0.5, delta: 0, playing: true, revision: 1, family: 0))
        let first = store.sample(key: "main:0", row: 0, layout: layout)
        store.beginFrame(.init(time: 0.6, delta: 0.1, playing: true, revision: 1, family: 0))
        let second = store.sample(key: "main:0", row: 0, layout: layout)
        store.beginFrame(.init(time: 0.7, delta: 0.1, playing: true, revision: 1, family: 0))
        // No row sample while offscreen; the engine still advances it.
        store.beginFrame(.init(time: 0.8, delta: 0.1, playing: true, revision: 1, family: 0))
        let third = store.sample(key: "main:0", row: 0, layout: layout)
        XCTAssertNotEqual(first, third)
        XCTAssertNotEqual(second, third)
        store.beginFrame(.init(time: 0.8, delta: 5, playing: false, revision: 1, family: 0))
        XCTAssertEqual(third, store.sample(key: "main:0", row: 0, layout: layout))
        store.beginFrame(.init(time: 0.2, delta: 0, playing: true, revision: 2, family: 0))
        XCTAssertEqual(layout.sample(time: 0.2), store.sample(key: "main:0", row: 0, layout: layout))
        XCTAssertEqual(store.count, 1)
    }
    func testProgressDraftUsesExponentialFollowWithoutChangingConfirmedTime() {
        let model = layout(), store = LyricsBlossomRunStore()
        store.beginFrame(.init(time: 0.2, delta: 0, playing: false, revision: 0, family: 0))
        let initial = store.sample(key: "m", row: 0, layout: model)
        store.beginFrame(.init(time: 0.2, delta: 1.0 / 12, playing: false, revision: 0, family: 0, draftTime: 1.8))
        let next = store.sample(key: "m", row: 0, layout: model)
        XCTAssertGreaterThan(next.starts[0], initial.starts[0])
        XCTAssertLessThan(next.starts[0], model.sample(time: 1.8).starts[0])
        store.beginFrame(.init(time: 0.2, delta: 0, playing: false, revision: 0, family: 0))
        XCTAssertEqual(initial, store.sample(key: "m", row: 0, layout: model))
    }
    func testOrdinaryLeadAndUnknownGuardsAndFamilyIsolation() {
        XCTAssertEqual(LyricsBlossomSelectionSchedule.lead(), 0.8947590697, accuracy: 1e-9)
        XCTAssertNotEqual(LyricsBlossomSelectionSchedule.lead(gap: 0.2, adaptive: true),
                          LyricsBlossomSelectionSchedule.lead(gap: 0.75, adaptive: true))
        let records: [LyricsBlossomSelectionSchedule.Record] = [
            .init(index: 0, start: 0, end: 2, lastWordEnd: 2),
            .init(index: 1, start: 2, end: 3, lastWordEnd: 3),
        ]
        let ordinary = LyricsBlossomSelectionSchedule().evaluate(now: 1.2, family: 0, records: records,
            fallback: [0], capacity: 2, playing: true, scrubbing: false)
        XCTAssertEqual(ordinary.selected, [0, 1]); XCTAssertFalse(ordinary.takeover); XCTAssertTrue(ordinary.catchUp.isEmpty)
        for family in [2, 3] {
            let result = LyricsBlossomSelectionSchedule().evaluate(now: 1.2, family: family, records: records,
                fallback: [0], capacity: 2, playing: true, scrubbing: false)
            XCTAssertEqual(result.selected, [0])
        }
    }
    func testCatchUpReturnTwoAndHoldGateAreDistinct() {
        let current = LyricsBlossomSelectionSchedule.Record(index: 0, start: 0, end: 2, lastWordEnd: 2,
            flag20: false, flag21: false, permitsTakeover: true, permitsCatchUp: true)
        let pending = LyricsBlossomSelectionSchedule.Record(index: 1, start: 2, end: 3, lastWordEnd: 3,
            flag20: false, flag21: false, permitsTakeover: true, permitsCatchUp: true)
        XCTAssertEqual(LyricsBlossomSelectionSchedule.catchUpCode(now: 1.4, current: current, pending: pending,
            count: 1, capacity: 2, holding: false), 1)
        XCTAssertEqual(LyricsBlossomSelectionSchedule.catchUpCode(now: 1.8, current: current, pending: pending,
            count: 1, capacity: 2, holding: false), 2)
        XCTAssertEqual(LyricsBlossomSelectionSchedule.catchUpCode(now: 1.8, current: current, pending: pending,
            count: 1, capacity: 2, holding: true), 0)
        XCTAssertNil(LyricsBlossomSelectionSchedule.catchUpCode(now: 1.8, current: current, pending: pending,
            count: 1, capacity: 2, holding: nil))
    }
    func testRecycledEquivalentLayoutAndPausedOffsetReanchor() {
        let store = LyricsBlossomRunStore(), first = layout()
        store.beginFrame(.init(time: 0.5, delta: 0, playing: true, revision: 0, family: 0))
        _ = store.sample(key: "m", row: 0, layout: first)
        store.beginFrame(.init(time: 0.6, delta: 0.1, playing: true, revision: 0, family: 0, catchUpRows: [0]))
        store.beginFrame(.init(time: 0.7, delta: 0.1, playing: true, revision: 0, family: 0))
        let expected = store.sample(key: "m", row: 0, layout: first)
        let count = store.reconstructionCount
        XCTAssertEqual(expected, store.sample(key: "m", row: 0, layout: layout()))
        XCTAssertEqual(count, store.reconstructionCount)
        store.beginFrame(.init(time: 0.2, delta: 0, playing: false, revision: 0, family: 0, offset: 0.5))
        XCTAssertEqual(first.sample(time: 0.2), store.sample(key: "m", row: 0, layout: first))
    }
    func testFrameSequencesKeepAllCursorFieldsAndTailDuration() {
        let segments = layout().records[0]
        for dt in [Float(1.0 / 60), Float(1.0 / 120), Float(0.037)] {
            var cursor = LyricsBlossomRunSweep.Cursor()
            cursor.step(now: 0, delta: 0, segments: segments, force: false)
            XCTAssertEqual(cursor.from, 0); XCTAssertEqual(cursor.to, 75)
            XCTAssertEqual(cursor.duration, 1); XCTAssertTrue(cursor.active)
            XCTAssertEqual(cursor.lastIndex, 0); XCTAssertFalse(cursor.suppressed)
            var time: Float = 0
            while time + dt < 0.8 {
                time += dt
                cursor.step(now: time, delta: dt, segments: segments, force: false)
                XCTAssertEqual(cursor.value, 75 * time, accuracy: 0.0001)
                XCTAssertEqual(cursor.elapsed, time, accuracy: 0.0001)
                XCTAssertEqual(cursor.from, 0); XCTAssertEqual(cursor.to, 75)
                XCTAssertEqual(cursor.duration, 1); XCTAssertEqual(cursor.lastIndex, 0)
                XCTAssertTrue(cursor.active); XCTAssertFalse(cursor.suppressed)
            }
            cursor.step(now: 1, delta: 1 - time, segments: segments, force: false)
            XCTAssertEqual(cursor.value, 75, accuracy: 0.0001)
            XCTAssertEqual(cursor.from, 75, accuracy: 0.0001); XCTAssertEqual(cursor.to, 130)
            XCTAssertEqual(cursor.duration, 2.2, accuracy: 0.0001)
            XCTAssertEqual(cursor.elapsed, 0); XCTAssertEqual(cursor.lastIndex, 1)
        }
    }

    func testBodyCatchUpCannotAccelerateIndependentRomanization() {
        let store = LyricsBlossomRunStore(), model = layout()
        store.beginFrame(.init(time: 0.5, delta: 0, playing: true, revision: 0, family: 0))
        _ = store.sample(key: "main:0", row: 0, layout: model)
        _ = store.sample(key: "roman:0", row: 0, layout: model, allowsCatchUp: false)
        store.beginFrame(.init(time: 0.6, delta: 0.1, playing: true, revision: 0, family: 0, catchUpRows: [0]))
        store.beginFrame(.init(time: 0.85, delta: 0.25, playing: true, revision: 0, family: 0))
        let body = store.sample(key: "main:0", row: 0, layout: model)
        let roman = store.sample(key: "roman:0", row: 0, layout: model, allowsCatchUp: false)
        XCTAssertGreaterThan(body.starts[0], roman.starts[0])
    }

    func testOrdinaryEarlyAnchorDoesNotRevertAtOverlappingStart() {
        let records: [LyricsBlossomSelectionSchedule.Record] = [
            .init(index: 0, start: 0, end: 3, lastWordEnd: 3),
            .init(index: 1, start: 2, end: 4, lastWordEnd: 4),
        ]
        let scheduler = LyricsBlossomSelectionSchedule()
        XCTAssertEqual(scheduler.evaluate(now: 1.5, family: 0, records: records, fallback: [0],
            capacity: 2, playing: true, scrubbing: false).focusOverride, 1)
        XCTAssertEqual(scheduler.evaluate(now: 2.1, family: 0, records: records, fallback: [0, 1],
            capacity: 2, playing: true, scrubbing: false).focusOverride, 1)
        XCTAssertNil(scheduler.evaluate(now: 2.1, family: 3, records: records, fallback: [0, 1],
            capacity: 2, playing: true, scrubbing: false).focusOverride)
    }

}
