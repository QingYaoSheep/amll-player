@testable import AMLLPlayer
import UIKit
import XCTest

final class AMLLNativeEngineTests: XCTestCase {
    func testClockDiscontinuityDoesNotPretendToBeASeek() {
        let lines = (0 ..< 4).map { index in
            LyricLine(id: String(index), text: "Line \(index)", start: Double(index * 5), end: Double(index * 5 + 3))
        }
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60, 60, 60, 60])
        _ = engine.render(.init(position: 1, playing: true), delta: 0)
        engine.handle(.beginBrowsing)
        engine.handle(.browseBy(40))
        engine.handle(.endBrowsing(velocity: 0))
        let discontinuity = engine.render(.init(position: 12, playing: true), delta: 0.18)
        XCTAssertTrue(discontinuity.browsing)
        let seek = engine.render(.init(position: 2, playing: false, seekRevision: 1), delta: 0)
        XCTAssertFalse(seek.browsing)
        XCTAssertEqual(seek.focusGroup, 0)
    }

    func testDifferentRowsRetainIndependentSpringDelays() {
        let lines = (0 ..< 5).map { index in
            LyricLine(id: String(index), text: "Line \(index)", start: Double(index * 2), end: Double(index * 2 + 2))
        }
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60, 60, 60, 60, 60])
        for _ in 0 ..< 180 {
            _ = engine.render(.init(position: 0.5, playing: true), delta: 1.0 / 60)
        }
        let before = engine.render(.init(position: 0.5, playing: true), delta: 0)
        let after = engine.render(.init(position: 2.1, playing: true), delta: 1.0 / 60)
        let movement = zip(before.rows, after.rows).map { $1.y - $0.y }
        XCTAssertGreaterThan(abs(movement[0] - movement[3]), 0.01)
    }

    @MainActor
    func testCoreTextPreservesEmojiCombiningMarksAndBidirectionalText() {
        let text = "مرحبا 👩‍👩‍👦 é 世界"
        let line = LyricLine(id: "unicode", text: text, start: 0, end: 4,
                             words: [.init(text: text, start: 0, end: 4)], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 160, font: .systemFont(ofSize: 32, weight: .semibold), configuration: .init())
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertFalse(layout.fragments.isEmpty)
        let combined = AMLLWordSegmentation.chunks(line.words).flatMap { $0 }.map(\.text).joined()
        XCTAssertEqual(combined, text)
        for offset in layout.breakOffsets {
            XCTAssertNotNil(Range(NSRange(location: offset, length: 0), in: text))
        }
        XCTAssertNotNil(layout.raster(scale: 3).cgImage)
    }

    func testPausedBackgroundOccupiesFlowAndKeepsItsOwnMaskScale() throws {
        let lines = [
            LyricLine(id: "main", text: "Lead", start: 1, end: 3),
            LyricLine(id: "background", text: "Echo", start: 1, end: 3, isBackground: true),
            LyricLine(id: "next", text: "Next", start: 8, end: 10),
        ]
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.enableSpring = false
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines), environment: environment, heights: [60, 30, 60])
        let playing = engine.render(.init(position: 0, playing: true), delta: 0)
        let paused = engine.render(.init(position: 0, playing: false), delta: 0)
        let background = try XCTUnwrap(paused.rows.first { $0.lineIndex == 1 })
        XCTAssertFalse(background.hidden)
        XCTAssertGreaterThan(background.opacity, 0)
        XCTAssertEqual(background.scale, 1, accuracy: 0.000_001)
        XCTAssertEqual(background.darkAlpha, 0.4, accuracy: 0.000_001)
        // CSS :not(.playing) puts inactive background wrappers back into normal flow.
        let before = try XCTUnwrap(playing.rows.first { $0.lineIndex == 2 })
        let after = try XCTUnwrap(paused.rows.first { $0.lineIndex == 2 })
        XCTAssertEqual(after.y - before.y, 30 + 32 * 0.3, accuracy: 0.000_001)
    }

    @MainActor
    func testNativeCanvasExportsActualFramesWithoutAdvancingLiveState() throws {
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        canvas.backgroundColor = .black
        canvas.position = { 6 }
        canvas.configure(document: LyricsRenderFixture.document, configuration: .init(),
                         input: .init(position: 6, playing: true), active: false, reduceMotion: false)
        for _ in 0 ..< 120 {
            canvas.advanceFrame(delta: 1.0 / 60)
        }
        let before = try XCTUnwrap(canvas.frameState)
        let bytes = try XCTUnwrap(canvas.exportMotionTrace(fps: 60))
        struct Trace: Decodable {
            var environment: AMLLRenderEnvironment
            var fps: Int
            var lineIDs: [String]
            var breaks: [[Int]]
            var frames: [AMLLFrameState]
        }
        let trace = try JSONDecoder().decode(Trace.self, from: bytes)
        XCTAssertEqual(trace.frames.count, 300)
        XCTAssertEqual(trace.environment.width, 402)
        XCTAssertEqual(trace.lineIDs.count, trace.breaks.count)
        XCTAssertEqual(trace.frames.first?.rows.count, before.rows.count)
        XCTAssertEqual(canvas.frameState?.animationTime, before.animationTime)
        XCTAssertEqual(canvas.frameState?.rows.map(\.y), before.rows.map(\.y))
        XCTAssertGreaterThan(canvas.visibleRowCount, 0)
        XCTAssertLessThan(canvas.cachedLayoutCount, trace.lineIDs.count)
        XCTAssertTrue(trace.frames.flatMap(\.rows).allSatisfy { $0.y.isFinite && $0.scale.isFinite })
        let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { canvas.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "AMLL-source-port-402pt-unapproved"
        attachment.lifetime = .keepAlways
        add(attachment)
        canvas.removeFromSuperview()
    }

    func testWordFloatClockPausesSeeksAndReversesFromEachWordsOwnEnd() {
        var clock = AMLLWordAnimationClock()
        clock.enable(at: 2)
        clock.advance(0.18, playing: true)
        XCTAssertEqual(clock.time, 2.18, accuracy: 0.000_001)
        clock.advance(4, playing: false)
        XCTAssertEqual(clock.time, 2.18, accuracy: 0.000_001)
        clock.disable()
        clock.advance(0.2, playing: false)
        XCTAssertEqual(clock.floatElapsed(wordStart: 0, duration: 1), 0.8, accuracy: 0.000_001)
        XCTAssertEqual(clock.floatElapsed(wordStart: 1, duration: 2), 0.98, accuracy: 0.000_001)
        clock.enable(at: 0.4)
        XCTAssertEqual(clock.time, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(clock.reverseElapsed, 0)
        XCTAssertTrue(clock.enabled)
    }
}
