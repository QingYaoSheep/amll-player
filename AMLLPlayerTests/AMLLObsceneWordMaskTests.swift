@testable import AMLLPlayer
import XCTest

final class AMLLObsceneWordMaskTests: XCTestCase {
    func testSourceModesPreserveWhitespaceAndUnmarkedWords() {
        let partial = AMLLObsceneWordMask(mode: .partial)
        XCTAssertEqual(partial.display("  words \t", marked: true), "  w***s \t")
        XCTAssertEqual(partial.display(" ab ", marked: true), " ** ")
        XCTAssertEqual(partial.display("word", marked: false), "word")
        XCTAssertEqual(AMLLObsceneWordMask().display("word", marked: true), "word")
        XCTAssertEqual(AMLLObsceneWordMask(mode: .full).display("a b\n", marked: true), "* *\n")
    }

    func testNativeMaskDoesNotSplitComposedCharacters() {
        let mask = AMLLObsceneWordMask(mode: .partial)
        XCTAssertEqual(mask.display("👩🏽‍🚀e\u{301}字", marked: true), "👩🏽‍🚀*字")
        XCTAssertEqual(AMLLObsceneWordMask(mode: .full).display("👩🏽‍🚀e\u{301}", marked: true), "**")
    }

    func testDisplayCopyPreservesSourceTimingAndMetadata() {
        let word = LyricWord(text: "word", start: 1, end: 3, romanWord: "roman", isObscene: true)
        let original = LyricLine(id: "marked", text: "word", start: 1, end: 3, words: [word], precision: .word)
        let result = AMLLObsceneWordMask(mode: .partial).apply(to: [original])[0]
        XCTAssertEqual(original.text, "word")
        XCTAssertEqual(result.text, "w**d")
        XCTAssertEqual(result.words[0].start, 1)
        XCTAssertEqual(result.words[0].end, 3)
        XCTAssertEqual(result.words[0].romanWord, "roman")
        XCTAssertTrue(result.words[0].isObscene)
    }
}
