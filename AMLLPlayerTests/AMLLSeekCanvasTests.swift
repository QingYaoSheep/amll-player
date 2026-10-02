@testable import AMLLPlayer
import UIKit
import XCTest

@MainActor final class AMLLSeekCanvasTests: XCTestCase {
    func testActualCanvasMovesThroughIntermediateSeekFramesWithoutRebuildingLayout() throws {
        var lines: [LyricLine] = []
        for i in 0..<8 {
            let start = Double(i) * 4
            let word = LyricWord(text: "Line \(i)", start: start, end: start + 3)
            lines.append(.init(id: String(i), text: word.text, start: start, end: start + 3, words: [word], precision: .word))
        }
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "seek-motion", title: "Seek", artists: []),
                                      lines: lines, language: "en", selectionReason: "Seek regression")
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let destination = AMLLNativeCanvas(frame: canvas.frame)
        let window = UIWindow(frame: canvas.frame)
        window.addSubview(canvas); window.addSubview(destination)
        defer { canvas.stop(); destination.stop(); canvas.removeFromSuperview(); destination.removeFromSuperview() }
        var position = 1.0
        canvas.position = { position }
        canvas.configure(document: document, configuration: .init(), input: .init(position: position, playing: true), active: false, reduceMotion: false)
        canvas.advanceFrame(delta: 0)
        let initial = try XCTUnwrap(canvas.frameState).rows[4].y
        let layouts = canvas.resourceCounts.layouts
        position = 16
        destination.position = { 16 }
        destination.configure(document: document, configuration: .init(), input: .init(position: 16, playing: true), active: false, reduceMotion: false)
        destination.advanceFrame(delta: 0)
        let target = try XCTUnwrap(destination.frameState).rows[4].y
        canvas.configure(document: document, configuration: .init(), input: .init(position: 16, playing: true, seekRevision: 1, seekPosition: 16), active: false, reduceMotion: false)
        canvas.advanceFrame(delta: 1 / 120)
        let first = try XCTUnwrap(canvas.frameState).rows[4]
        XCTAssertTrue(first.active)
        XCTAssertFalse(first.fillComplete)
        XCTAssertGreaterThan(abs(first.y - target), 1)
        XCTAssertLessThan(abs(first.y - initial), abs(target - initial))
        XCTAssertEqual(canvas.resourceCounts.layouts, layouts)
        for _ in 0..<360 { canvas.advanceFrame(delta: 1 / 120) }
        XCTAssertEqual(try XCTUnwrap(canvas.frameState).rows[4].y, target, accuracy: 0.1)
    }

    func testCanvasReadsOneCompletePlaybackFrameDespiteStaleSwiftUIInput() throws {
        let lines = (0..<8).map { i in
            let start = Double(i * 4)
            let word = LyricWord(text: "Line", start: start, end: start + 3)
            return LyricLine(id: String(i), text: "Line", start: start, end: start + 3, words: [word], precision: .word)
        }
        let document = LyricsDocument(candidate: .init(source: .qq, sourceID: "atomic-seek", title: "Seek", artists: []),
                                      lines: lines, language: "en", selectionReason: "Frame regression")
        let displayStart = AMLLDisplayDocument(lines: lines).lines[1].start
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.frame); window.addSubview(canvas)
        defer { canvas.stop(); canvas.removeFromSuperview() }
        var sample = LyricsPlaybackFrame(position: 25, playing: false, seekRevision: 0)
        var samples = 0
        canvas.playbackFrame = { samples += 1; return sample }
        canvas.position = { XCTFail("Production must not read a second independent clock"); return -100 }
        canvas.configure(document: document, configuration: .init(), input: .init(position: 25, playing: true),
                         active: true, reduceMotion: false)
        canvas.advanceFrame(delta: 0)
        let layouts = canvas.resourceCounts.layouts
        for step in [1.0 / 60, 1.0 / 120, 0.037] {
            sample.position = 4.25; sample.playing = true; sample.seekRevision += 1
            // SwiftUI can still be delivering the previous snapshot at this instant.
            canvas.configure(document: document, configuration: .init(), input: .init(position: 25, playing: false),
                             active: true, reduceMotion: false)
            samples = 0
            canvas.advanceFrame(delta: step)
            let frame = try XCTUnwrap(canvas.frameState)
            XCTAssertEqual(samples, 1)
            XCTAssertEqual(frame.lyricTime, 4.25, accuracy: 0.001)
            XCTAssertEqual(frame.rows[1].wordClock.time + displayStart, 4.25, accuracy: 0.001)
            XCTAssertFalse(frame.rows[1].fillComplete)
            XCTAssertEqual(canvas.resourceCounts.layouts, layouts)
        }
    }
}
