@testable import AMLLPlayer
import XCTest

final class LyricsHDRStateTests: XCTestCase {
    private let lines = [
        LyricLine(id: "main", text: "One", start: 1, end: 5),
        LyricLine(id: "overlap", text: "Two", start: 3, end: 6),
        LyricLine(id: "next", text: "Three", start: 8, end: 10),
    ]

    private func frame(_ time: Double) -> LyricsHDRFrameState {
        .sample(lines: lines, lyricTime: time, configuration: .init(enabled: true),
                capabilities: .init(supportsEDR: true, headroom: 2))
    }

    func testActualTimeOverlapsPauseSeekAndInterlude() {
        XCTAssertEqual(frame(0.9).activeLineIndexes, [])
        XCTAssertEqual(frame(4).activeLineIndexes, [0, 1])
        XCTAssertEqual(frame(4), frame(4))
        XCTAssertEqual(frame(5).activeLineIndexes, [1])
        XCTAssertEqual(frame(7).activeLineIndexes, [])
        XCTAssertEqual(frame(8).activeLineIndexes, [2])
        XCTAssertEqual(frame(2).activeLineIndexes, [0])
        XCTAssertEqual(frame(.nan).activeLineIndexes, [])
    }

    func testFilledWordsPersistAndFutureWordsStayDark() {
        let state = frame(4)
        let words: [AMLLWordMask.Word] = [
            .init(start: 1, end: 2, width: 100),
            .init(start: 4, end: 5, width: 100),
        ]
        func coverage(_ index: Int, _ x: Double) -> Double {
            state.coverage(lineIndex: 0, time: 3, wordIndex: index, words: words,
                           x: x, fragmentAdvance: 0, feather: 10)
        }
        XCTAssertEqual(coverage(0, 50), 1)
        XCTAssertEqual(coverage(1, 50), 0)
        XCTAssertEqual(coverage(0, 100), 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.coverage(lineIndex: 2, time: 9, wordIndex: nil,
                                      words: [], x: 0, fragmentAdvance: 0, feather: 10), 0)
        XCTAssertEqual(state.coverage(lineIndex: 0, time: 4, wordIndex: nil,
                                      words: [], x: 0, fragmentAdvance: 0, feather: 10), 1)
    }

    func testHeadroomAndAccessibilityNeverForceBrightness() {
        let enabled = LyricsHDRConfiguration(enabled: true)
        for headroom in [Double.nan, .infinity, -1, 0, 1] {
            XCTAssertEqual(LyricsHDRCapabilities(supportsEDR: true, headroom: headroom)
                .outputBrightness(configuration: enabled, reduceTransparency: false), 1)
        }
        let supported = LyricsHDRCapabilities(supportsEDR: true, headroom: 1.2)
        XCTAssertEqual(supported.outputBrightness(configuration: enabled, reduceTransparency: false), 1.2)
        XCTAssertEqual(supported.outputBrightness(configuration: enabled, reduceTransparency: true), 1)
        XCTAssertEqual(supported.outputBrightness(configuration: .init(), reduceTransparency: false), 1)
        XCTAssertEqual(frame(4).outputBrightness, 1.5)
    }
}
