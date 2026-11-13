@testable import AMLLPlayer
import XCTest

final class LyricsBlossomFamilyTwoTests: XCTestCase {
    private typealias Schedule = LyricsBlossomSelectionSchedule
    private typealias Cursor = LyricsBlossomRunSweep.Cursor
    private struct Point: Decodable {
        var now: Double
        var selected: [Int]
        var pending: Int
        var kind: Int
        var catchUp: [Int]
        var enter: Int
        var removed: Int
        var active: [Int]
        var display: [Int]
        var next: Int
        var lead: Double
    }
    private struct Transition: Decodable {
        var now: Double?
        var delta: Double?
        var eligible: Bool?
        var before: [[Double]]
        var after: [[Double]]
        var segments: [Int]
    }
    private struct Draw: Decodable {
        var cursor: Double
        var left: Double
        var right: Double
        var colors: [Double]
    }
    private struct Capture: Decodable {
        var preset: String
        var wordVersion: Int
        var frames: Int
        var records: [Schedule.Record]
        var points: [Point]
        var gates: [[Int]]
        var calls: [Transition]
        var steps: [Transition]
        var segments: [[[Double]]]
        var draws: [Draw]

        func timed(_ index: Int) -> [LyricsBlossomRunSweep.Segment] {
            segments[index].map {
                .init(start: Float($0[0]), end: Float($0[1]), distance: Float($0[2]),
                      nonSpaceByteCount: Int($0[3]), final: $0[4] != 0)
            }
        }
    }
    private func captures() throws -> [Capture] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "blossom-family2-trace", withExtension: "json"))
        return try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
    }
    private func cursor(_ values: [Double]) -> Cursor {
        .init(value: Float(values[0]), from: Float(values[1]), to: Float(values[2]),
              elapsed: Float(values[3]), duration: Float(values[4]), active: values[5] != 0,
              lastIndex: Int(values[6]), suppressed: values[7] != 0)
    }
    private func compare(_ actual: Cursor, _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        for (value, reference) in zip([actual.value, actual.from, actual.to, actual.elapsed, actual.duration], expected) {
            XCTAssertEqual(value, Float(reference), accuracy: 0.00015, file: file, line: line)
        }
        XCTAssertEqual(actual.active, expected[5] != 0, file: file, line: line)
        XCTAssertEqual(actual.lastIndex, Int(expected[6]), file: file, line: line)
        XCTAssertEqual(actual.suppressed, expected[7] != 0, file: file, line: line)
    }

    func testCapturedFamilyTwoSelectorsAndRunTrajectories() throws {
        XCTAssertTrue(Schedule.supported(2))
        var pointCount = 0, gateCount = 0, armCounts: [Int] = []
        for capture in try captures() {
            var options = LyricsBlossomAnimationOptions()
            options.apply(capture.preset == "26.4" ? .appleMusic264 : .appleMusic27)
            XCTAssertEqual(options.selectionFamily, 2)
            XCTAssertEqual(options.word, capture.wordVersion)
            for point in capture.points {
                let result = Schedule.dispatch(family: 2, now: point.now, records: capture.records,
                    selected: point.selected, pending: point.pending >= 0 ? point.pending : nil,
                    capacity: 2, mainHold: false, ticketHold: false, deadline: -1, adaptive: true)
                XCTAssertEqual(result.kind.rawValue, point.kind)
                XCTAssertEqual(result.catchUp, point.catchUp)
                XCTAssertEqual(result.selected, point.active)
                XCTAssertEqual(result.enterIndex ?? -1, point.enter)
                XCTAssertEqual(result.removed ?? -1, point.removed)
                XCTAssertEqual(result.pending ?? -1, point.next)
                XCTAssertEqual(capture.records.isEmpty ? 0 : Schedule.lead(family: 2,
                    gap: point.selected.last.flatMap { key in
                        capture.records.first(where: { $0.index == key }).flatMap { current in
                            capture.records.first(where: { $0.index == point.pending }).map { $0.start - current.end }
                        }
                    } ?? 0, adaptive: true), point.lead, accuracy: 1e-7)
                pointCount += 1
            }
            for gate in capture.gates {
                XCTAssertEqual(gate[0] == 0 && gate[1] > 0, gate[2] != 0)
                gateCount += 1
            }
            var arms = 0
            for call in capture.calls {
                for index in call.before.indices {
                    var state = cursor(call.before[index])
                    if call.eligible == true { state.catchUp(segments: capture.timed(call.segments[index])) }
                    compare(state, call.after[index])
                    if call.before[index][7] == 0 && call.after[index][7] != 0 { arms += 1 }
                }
            }
            armCounts.append(arms)
            for step in capture.steps {
                for index in step.before.indices {
                    var state = cursor(step.before[index])
                    state.stepRow(now: Float(try XCTUnwrap(step.now)), delta: Float(try XCTUnwrap(step.delta)),
                        segments: capture.timed(step.segments[index]), flag40: false, flag41: true, force: false)
                    compare(state, step.after[index])
                }
            }
            for draw in capture.draws {
                XCTAssertEqual(draw.right, max(0, draw.cursor) - 2, accuracy: 0.0001)
                XCTAssertEqual(draw.left, draw.right - 30, accuracy: 0.0001)
                XCTAssertEqual(draw.colors, [1, 1, 1, 0.85, 1, 1, 1, 0])
            }
        }
        XCTAssertEqual(pointCount, 1_006)
        XCTAssertEqual(gateCount, 1_428)
        XCTAssertEqual(armCounts, [9, 9])
    }

    func testFamilyTwoExitWithoutEntryUpdatesDisplayAndInstallsTickets() {
        let records: [Schedule.Record] = [
            .init(index: 0, start: 9.1, end: 10.1, lastWordEnd: 10.1),
            .init(index: 1, start: 9.5, end: 13, lastWordEnd: 13),
            .init(index: 2, start: 16, end: 22, lastWordEnd: 22)
        ]
        var scheduler = Schedule()
        scheduler.rebase(records: records, now: 9.8, capacity: 1, bypassClock: false, family: 2)
        XCTAssertEqual(scheduler.state.selected, [0, 1])
        let exit = scheduler.update(family: 2, now: 10.45, wall: 1, records: records, capacity: 1,
            running: true, rebased: false, browsing: false, adaptive: true, isPending: { _ in false })
        XCTAssertEqual(exit.kind, .none)
        XCTAssertEqual(exit.removed, 0)
        XCTAssertEqual(exit.left, [0])
        XCTAssertEqual(exit.active, [1])
        XCTAssertEqual(exit.selected, [1])
        XCTAssertTrue(exit.entered.isEmpty)
        XCTAssertTrue(exit.catchUp.isEmpty)
        let ticket = Schedule.Ticket(row: 1, channel: .position, generation: 7)
        scheduler.installed(ticket, family: 2, kind: exit.kind)
        let held = scheduler.update(family: 2, now: 12.3, wall: 2, records: records, capacity: 1,
            running: true, rebased: false, browsing: false, adaptive: true, isPending: { $0 == ticket })
        XCTAssertEqual(held.selected, [1])
        XCTAssertTrue(held.catchUp.isEmpty)
        let released = scheduler.update(family: 2, now: 15.4, wall: 3, records: records, capacity: 1,
            running: true, rebased: false, browsing: false, adaptive: true, isPending: { $0.generation == 8 })
        XCTAssertEqual(released.selected, [2])
        XCTAssertFalse(released.takeover)
    }

    func testSourceOverFillKeepsTransparentFrontAndUniformRest() {
        let fill = LyricsBlossomRunFill(bright: 1, dark: 0.3 / 0.85)
        XCTAssertEqual(fill.base, 0.3, accuracy: 0.000001)
        XCTAssertEqual(fill.overlay, 0.85, accuracy: 0.000001)
        XCTAssertEqual(fill.alpha(coverage: 0, glyph: 1), 0.3, accuracy: 0.000001)
        XCTAssertEqual(fill.alpha(coverage: 1, glyph: 1), 0.895, accuracy: 0.000001)
        XCTAssertEqual(fill.alpha(coverage: 1, glyph: 0.5), 0.51125, accuracy: 0.000001)
        let rest = LyricsBlossomRunFill(bright: 0.2, dark: 0.2)
        XCTAssertEqual(rest.overlay, 0)
        XCTAssertEqual(rest.alpha(coverage: 1, glyph: 1), 0.2, accuracy: 0.000001)
    }

    func testProductionFamilyTwoTailAndIndependentExitAcrossFrameRates() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "blossom-family2", withExtension: "ttml"))
        let lines = try TTMLLyricsParser.parse(String(contentsOf: url, encoding: .utf8), duration: 26)
        for preset in [LyricsBlossomAnimationOptions.Preset.appleMusic264, .appleMusic27] {
            for cadence in [[1.0 / 60], [1.0 / 120], [0.013, 0.041, 0.009]] {
                var options = LyricsBlossomAnimationOptions()
                options.apply(preset)
                var environment = AMLLRenderEnvironment(width: 402, height: 874, screenWidth: 402, fontSize: 32)
                environment.animationStyle = .appleMusic164
                environment.appleMusicAnimation = options
                var engine = AMLLFrameEngine(document: .init(lines: lines), environment: environment,
                                             heights: Array(repeating: 80, count: lines.count))
                _ = engine.render(.init(position: 0, playing: true), delta: 0)
                for row in [1, 5] {
                    let text = lines[row].words.map(\.text).joined()
                    var position = 0
                    let pieces: [LyricsBlossomRunLayout.Piece] = lines[row].words.enumerated().map { index, word in
                        defer { position += word.text.utf16.count }
                        return .init(range: .init(location: position, length: word.text.utf16.count),
                            width: Double(word.text.utf16.count) * 10, start: word.start, end: word.end,
                            group: row == 5 ? index / 5 : 0)
                    }
                    let layout = LyricsBlossomRunLayout(text: text, pieces: pieces, pixelsPerPoint: 1)
                    _ = engine.runStore.sample(key: "main:\(row)", row: row, layout: layout)
                }
                var now = 0.0, tick = 0
                var sawEarly = false, sawExit = false, sawTailStep = false, sawWrapped = false
                var armedFrom: Float?
                while now < 24 {
                    let dt = cadence[tick % cadence.count]
                    now += dt; tick += 1
                    _ = engine.render(.init(position: now, playing: true), delta: dt)
                    let schedule = try XCTUnwrap(engine.blossomSchedule)
                    if schedule.catchUp.contains(1), schedule.selected.contains(1) {
                        let state = try XCTUnwrap(engine.runStore.cursorStates(key: "main:1").first)
                        if armedFrom == nil {
                            armedFrom = state.from
                            XCTAssertEqual(state.elapsed, 0)
                            XCTAssertTrue(state.suppressed)
                        }
                        sawEarly = true
                    }
                    if let armedFrom, let state = engine.runStore.cursorStates(key: "main:1").first,
                       state.value > armedFrom, state.value < state.to, state.suppressed { sawTailStep = true }
                    if schedule.removed == 3, schedule.enterIndex == nil {
                        XCTAssertEqual(schedule.selected, [4])
                        XCTAssertEqual(schedule.left, [3])
                        XCTAssertTrue(schedule.catchUp.isEmpty)
                        sawExit = true
                    }
                    if schedule.catchUp.contains(5) {
                        let runs = engine.runStore.cursorStates(key: "main:5")
                        XCTAssertEqual(runs.count, 4)
                        XCTAssertTrue(runs.allSatisfy(\.suppressed))
                        sawWrapped = true
                    }
                }
                XCTAssertTrue(sawEarly, preset.title)
                XCTAssertTrue(sawTailStep, preset.title)
                XCTAssertTrue(sawExit, preset.title)
                XCTAssertTrue(sawWrapped, preset.title)
                XCTAssertEqual(engine.runStore.armCount, 5)
                let before = engine.runStore.cursorStates(key: "main:1")
                _ = engine.render(.init(position: now, playing: false), delta: 1)
                XCTAssertEqual(engine.runStore.cursorStates(key: "main:1"), before)
                _ = engine.render(.init(position: 3.4, playing: false, seekRevision: 1), delta: 0)
                let replay = try XCTUnwrap(engine.runStore.cursorStates(key: "main:1").first)
                XCTAssertFalse(replay.suppressed)
                XCTAssertLessThan(replay.value, before[0].value)
            }
        }
    }
}
