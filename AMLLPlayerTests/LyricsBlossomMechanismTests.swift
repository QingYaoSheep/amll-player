@testable import AMLLPlayer
import XCTest

final class LyricsBlossomMechanismTests: XCTestCase {
    func testDefaultSelectorCanDispatchCatchUpBeforeChangingSelection() {
        let records: [LyricsBlossomSelectionSchedule.Record] = [
            .init(index: 0, start: 0, end: 8, lastWordEnd: 8),
            .init(index: 1, start: 8, end: 9, lastWordEnd: 9),
        ]
        let result = LyricsBlossomSelectionSchedule.dispatch(family: 3, now: 7.253,
            records: records, selected: [0], pending: 1, capacity: 2,
            mainHold: false, ticketHold: false, deadline: -1)
        XCTAssertEqual(result.catchUp, [0])
        XCTAssertEqual(result.selected, [0])
        XCTAssertEqual(result.kind, .none)
    }

    func testDefaultRunKeepsFinishingCatchUpAfterRowLeaves() {
        let store = LyricsBlossomRunStore(), model = layout()
        store.beginFrame(.init(time: 0.5, delta: 0, playing: true, revision: 1,
                              family: 3, selectedRows: [0]))
        _ = store.sample(key: "main:0", row: 0, layout: model)
        store.applySelection(entered: [], left: [0], catchUp: [0])
        let initial = store.cursorStates(key: "main:0")[0]
        XCTAssertEqual(initial.elapsed, 0)
        store.beginFrame(.init(time: 0.5, delta: 0.1, playing: true, revision: 1,
                              family: 3, selectedRows: []))
        let middle = store.cursorStates(key: "main:0")[0]
        XCTAssertEqual(middle.value, initial.from + (130 - initial.from) * 0.4, accuracy: 0.0001)
        store.applySelection(entered: [], left: [], catchUp: [0])
        XCTAssertEqual(store.cursorStates(key: "main:0")[0], middle)
        store.beginFrame(.init(time: 0.5, delta: 0.15, playing: true, revision: 1,
                              family: 3, selectedRows: []))
        let end = store.cursorStates(key: "main:0")[0]
        XCTAssertEqual(end.value, 130, accuracy: 0.0001)
        XCTAssertFalse(end.active)
        XCTAssertTrue(end.suppressed)
    }

    func testProductionTTMLTailStartsBeforeSelectionExitAndSurvivesPauseAndSeek() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "blossom-catchup", withExtension: "ttml"))
        let lines = try TTMLLyricsParser.parse(String(contentsOf: url, encoding: .utf8), duration: 26)
        XCTAssertEqual(lines.count, 8)
        let tail = lines[1]
        let words = tail.words
        XCTAssertEqual(words.count, 2)
        let firstLength = words[0].text.utf16.count
        let layout = LyricsBlossomRunLayout(text: words.map(\.text).joined(), pieces: [
            .init(range: .init(location: 0, length: firstLength), width: 50, start: words[0].start, end: words[0].end),
            .init(range: .init(location: firstLength, length: words[1].text.utf16.count), width: 80,
                  start: words[1].start, end: words[1].end)
        ], pixelsPerPoint: 1)
        for family in [3, 0] {
            for cadence in [[1.0 / 60], [1.0 / 120], [0.013, 0.041, 0.009]] {
                var environment = AMLLRenderEnvironment(width: 400, height: 900, screenWidth: 400, fontSize: 32)
                environment.animationStyle = .appleMusic164
                var options = LyricsBlossomAnimationOptions()
                options.selection = family
                environment.appleMusicAnimation = options
                var engine = AMLLFrameEngine(document: .init(lines: lines), environment: environment,
                                             heights: Array(repeating: 50, count: lines.count))
                var time = 2.8
                _ = engine.render(.init(position: time, playing: true), delta: 0)
                _ = engine.runStore.sample(key: "main:1", row: 1, layout: layout)
                var armedAt: Double?, leftAt: Double?, armedCursor: Float?
                var sawIntermediateCursor = false
                var tick = 0
                while time < 7.9 {
                    let dt = cadence[tick % cadence.count]
                    tick += 1
                    time += dt
                    _ = engine.render(.init(position: time, playing: true), delta: dt)
                    if armedAt == nil, engine.runStore.armCount == 1 {
                        armedAt = time
                        let state = engine.runStore.cursorStates(key: "main:1")[0]
                        XCTAssertEqual(state.elapsed, 0)
                        XCTAssertGreaterThan(state.to - state.from, 1)
                        armedCursor = state.from
                        XCTAssertTrue(engine.blossomSchedule?.selected.contains(1) == true)
                        _ = engine.render(.init(position: time, playing: false), delta: dt)
                        XCTAssertEqual(engine.runStore.cursorStates(key: "main:1")[0], state)
                    }
                    if let armedCursor, let cursor = engine.runStore.cursorStates(key: "main:1").first,
                       cursor.value > armedCursor, cursor.value < cursor.to {
                        sawIntermediateCursor = true
                    }
                    if leftAt == nil, engine.blossomSchedule?.left.contains(1) == true { leftAt = time }
                }
                XCTAssertLessThan(try XCTUnwrap(armedAt), try XCTUnwrap(leftAt))
                XCTAssertEqual(engine.runStore.armCount, 1)
                XCTAssertTrue(sawIntermediateCursor)
                let completed = engine.runStore.cursorStates(key: "main:1")[0]
                XCTAssertEqual(completed.value, 160, accuracy: 0.001)
                XCTAssertTrue(completed.suppressed)
                _ = engine.render(.init(position: 3.4, playing: false, seekRevision: 1), delta: 0)
                let replayed = engine.runStore.cursorStates(key: "main:1")[0]
                XCTAssertFalse(replayed.suppressed)
                XCTAssertLessThan(replayed.value, completed.value)
            }
        }
    }

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
    func testFixedLeadAndFamilyTwoStaticCompatibilityBoundary() {
        typealias Schedule = LyricsBlossomSelectionSchedule
        XCTAssertEqual(Schedule.lead(), 0.8947590697, accuracy: 1e-9)
        XCTAssertEqual(Schedule.lead(family: 3), 0.891968727, accuracy: 1e-7)
        XCTAssertNotEqual(Schedule.lead(gap: 0.2, adaptive: true), Schedule.lead(gap: 0.75, adaptive: true))
        XCTAssertFalse(Schedule.supported(2))
        let records: [Schedule.Record] = [
            .init(index: 0, start: 0, end: 3, lastWordEnd: 3),
            .init(index: 1, start: 1, end: 2, lastWordEnd: 2),
            .init(index: 2, start: 3, end: 4, lastWordEnd: 4),
        ]
        let result = Schedule.dispatch(family: 2, now: 2.31, records: records, selected: [0, 1],
            pending: 2, capacity: 2, mainHold: false, ticketHold: false, deadline: -1)
        XCTAssertEqual(result.catchUp, [0, 1])
        XCTAssertEqual(result.kind, .none)
    }

    func testOrdinaryPreviewReturnTwoAndHoldGateAreDistinct() {
        typealias Schedule = LyricsBlossomSelectionSchedule
        let records: [Schedule.Record] = [
            .init(index: 0, start: 0, end: 2, lastWordEnd: 2),
            .init(index: 1, start: 2, end: 3, lastWordEnd: 3),
        ]
        let preview = Schedule.dispatch(family: 0, now: 1.4, records: records, selected: [0], pending: 1,
            capacity: 2, mainHold: false, ticketHold: false, deadline: -1)
        XCTAssertEqual(preview.previewCode, 1)
        XCTAssertEqual(preview.catchUp, [0])
        let append = Schedule.dispatch(family: 0, now: 1.8, records: records, selected: [0], pending: 1,
            capacity: 2, mainHold: false, ticketHold: false, deadline: -1)
        XCTAssertEqual(append.previewCode, 2)
        XCTAssertTrue(append.catchUp.isEmpty)
        let held = Schedule.dispatch(family: 0, now: 1.8, records: records, selected: [0], pending: 1,
            capacity: 2, mainHold: true, ticketHold: true, deadline: -1)
        XCTAssertEqual(held.previewCode, 0)
        XCTAssertEqual(held.selected, [0])
    }

    func testPositionTicketExpiresByGenerationAndClockStillGuardsReplacement() {
        typealias Schedule = LyricsBlossomSelectionSchedule
        let records: [Schedule.Record] = [
            .init(index: 0, start: 0, end: 2, lastWordEnd: 2),
            .init(index: 1, start: 1.8, end: 2.4, lastWordEnd: 2.4),
            .init(index: 2, start: 2.5, end: 3, lastWordEnd: 3),
        ]
        var scheduler = Schedule()
        scheduler.rebase(records: records, now: -1, capacity: 2, bypassClock: true)
        let entering = scheduler.update(family: 3, now: -0.8, wall: 0, records: records, capacity: 2,
            running: true, rebased: false, browsing: false, isPending: { _ in false })
        XCTAssertEqual(entering.entered, [0])
        let ticket = Schedule.Ticket(row: 0, channel: .position, generation: 1)
        scheduler.installed(ticket, family: 3, kind: .initial)
        let held = scheduler.update(family: 3, now: 1.8, wall: 1, records: records, capacity: 2,
            running: true, rebased: false, browsing: false, isPending: { $0 == ticket })
        XCTAssertEqual(held.selected, [0])
        let afterReplacement = scheduler.update(family: 3, now: 1.81, wall: 1.04, records: records, capacity: 2,
            running: true, rebased: false, browsing: false, isPending: { $0.generation == 2 })
        XCTAssertEqual(afterReplacement.selected, [0, 1])
        XCTAssertEqual(afterReplacement.deadline, -1)
        scheduler.rebase(records: records, now: 2.7, capacity: 2, bypassClock: true)
        XCTAssertEqual(scheduler.state.selected, [2])
        XCTAssertEqual(scheduler.state.deadline, -1)
    }

    func testCapturedSelectorAndRunArmingTrace() throws {
        typealias Schedule = LyricsBlossomSelectionSchedule
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "blossom-catchup-trace", withExtension: "json"))
        let captures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var selectorCount = 0, dispatchCount = 0, armCount = 0, suppressedCount = 0
        for capture in captures {
            let family = try XCTUnwrap(capture["family"] as? Int)
            let records = try JSONDecoder().decode([Schedule.Record].self,
                from: JSONSerialization.data(withJSONObject: try XCTUnwrap(capture["records"])))
            let points = try XCTUnwrap(capture["points"] as? [[Any]])
            for (index, point) in points.enumerated() {
                let now = try XCTUnwrap(point[0] as? Double)
                let output = Schedule.dispatch(family: family, now: now, records: records,
                    selected: try XCTUnwrap(point[1] as? [Int]), pending: (point[2] as? Int).flatMap { $0 >= 0 ? $0 : nil },
                    capacity: try XCTUnwrap(point[3] as? Int), mainHold: try XCTUnwrap(point[4] as? Bool),
                    ticketHold: try XCTUnwrap(point[5] as? Bool), deadline: try XCTUnwrap(point[6] as? Double),
                    bypassClock: try XCTUnwrap(point[7] as? Bool), adaptive: try XCTUnwrap(point[8] as? Bool))
                XCTAssertEqual(output.catchUp, point[9] as? [Int], "family \(family), point \(index)")
                XCTAssertEqual(output.selected, point[10] as? [Int], "family \(family), point \(index)")
                XCTAssertEqual(output.pending ?? -1, point[11] as? Int, "family \(family), point \(index)")
                selectorCount += 1
                dispatchCount += output.catchUp.count
            }
            for call in try XCTUnwrap(capture["calls"] as? [[Any]]) {
                let eligible = (call[0] as? Int) == 1, nonempty = (call[2] as? Int) == 1
                let value = try XCTUnwrap(call[3] as? Double)
                let index = try XCTUnwrap(call[4] as? Int)
                var cursor = LyricsBlossomRunSweep.Cursor(value: Float(value), lastIndex: index,
                    suppressed: (call[1] as? Int) == 1)
                let before = cursor
                if eligible {
                    cursor.catchUp(segments: nonempty ? layout().records[0] : [])
                }
                if let expectedFrom = call[5] as? Double {
                    XCTAssertEqual(cursor.from, Float(expectedFrom), accuracy: 0.00001)
                    XCTAssertEqual(cursor.elapsed, 0)
                    XCTAssertEqual(cursor.duration, 0.25)
                    XCTAssertTrue(cursor.active)
                    XCTAssertTrue(cursor.suppressed)
                    XCTAssertEqual(cursor.lastIndex, index)
                    armCount += 1
                } else {
                    XCTAssertEqual(cursor, before)
                    suppressedCount += 1
                }
            }
        }
        XCTAssertEqual(selectorCount, 6_437)
        XCTAssertEqual(dispatchCount, 256)
        XCTAssertEqual(armCount, 15)
        XCTAssertEqual(suppressedCount, 241)
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

}
