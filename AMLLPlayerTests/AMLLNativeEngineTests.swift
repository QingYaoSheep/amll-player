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
}
