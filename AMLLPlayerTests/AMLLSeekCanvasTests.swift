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
}
