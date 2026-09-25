@testable import AMLLPlayer
import XCTest

final class LyricsRomanizationAlignmentTests: XCTestCase {
    func testOverlappingUnidentifiedVoicesDoNotStealAnnotation() {
        var lines = [LyricLine(id: "a", text: "A", start: 0, end: 2),
                     LyricLine(id: "b", text: "B", start: 0, end: 2)]
        LyricsRomanizationAlignment.mergeLines([.init(id: "r", text: "roman", start: 0, end: 2)], into: &lines)
        XCTAssertTrue(lines.allSatisfy(\.romanization.isEmpty))
    }

    func testBackgroundPronunciationMatchesItsVoice() {
        var lines = [LyricLine(id: "main", text: "A", start: 0, end: 2),
                     LyricLine(id: "bg", text: "B", start: 0, end: 2, isBackground: true)]
        LyricsRomanizationAlignment.mergeLines([.init(id: "r", text: "roman", start: 0, end: 2, isBackground: true)], into: &lines)
        XCTAssertTrue(lines[0].romanization.isEmpty)
        XCTAssertEqual(lines[1].romanization, "roman")
    }

    func testAdjacentAnnotatedSyllablesKeepOneEmphasisChunk() {
        let chunks = AMLLWordSegmentation.chunks([
            .init(text: "hel", start: 0, end: 0.6, romanWord: "he"),
            .init(text: "lo", start: 0.6, end: 1.2, romanWord: "lo"),
        ])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].map(\.text), ["hel", "lo"])
    }

    func testAnnotatedLeadingSpaceBreaksChunkAndPreservesSourceRange() {
        let chunks = AMLLWordSegmentation.mappedChunks([
            .init(text: "hello", start: 0, end: 1, romanWord: "he"),
            .init(text: " world", start: 1, end: 2, romanWord: "world"),
        ])
        XCTAssertEqual(chunks.map { $0.map(\.word.text).joined() }, ["hello", " ", "world"])
        XCTAssertEqual(chunks[2][0].sourceRange, NSRange(location: 1, length: 5))
        XCTAssertEqual(chunks[2][0].word.romanWord, "world")
    }

    func testAmbiguousCandidatesRemainLineLevel() {
        var words = [LyricWord(text: "字", start: 1, end: 2)]
        LyricsRomanizationAlignment.merge([
            .init(text: "a", start: 1, end: 2),
            .init(text: "b", start: 1, end: 2),
        ], into: &words)
        XCTAssertNil(words[0].romanWord)
    }

    func testWholeLineIsNotAssignedToFirstOfEqualWords() {
        var words = [LyricWord(text: "一", start: 0, end: 1),
                     LyricWord(text: "二", start: 1, end: 2)]
        LyricsRomanizationAlignment.merge([.init(text: "yi er", start: 0, end: 2)], into: &words)
        XCTAssertTrue(words.allSatisfy { $0.romanWord == nil })
    }

    func testSourceTimingSurvivesCodableAndSegmentation() throws {
        var words = [LyricWord(text: "hello world", start: 1, end: 3)]
        LyricsRomanizationAlignment.merge([.init(text: "pronunciation", start: 1.1, end: 2.9)], into: &words)
        let decoded = try JSONDecoder().decode([LyricWord].self, from: JSONEncoder().encode(words))
        let atoms = AMLLWordSegmentation.mappedChunks(decoded).flatMap(\.self)
        XCTAssertEqual(atoms.count, 1)
        XCTAssertEqual(atoms.first?.word.romanStart, 1.1)
        XCTAssertEqual(atoms.first?.word.romanEnd, 2.9)
        XCTAssertEqual(decoded[0].text, "hello world")
        XCTAssertEqual(decoded[0].start, 1)
    }

    func testUnequalWordLengthsDoNotClaimWholeLineAnnotation() {
        var words = [LyricWord(text: "long", start: 0, end: 3),
                     LyricWord(text: "short", start: 3, end: 4)]
        LyricsRomanizationAlignment.merge([.init(text: "whole phrase", start: 0, end: 4)], into: &words)
        XCTAssertTrue(words.allSatisfy { $0.romanWord == nil })
    }

    func testExistingProviderMappingWins() {
        var words = [LyricWord(text: "字", start: 1, end: 2, romanWord: "original")]
        LyricsRomanizationAlignment.merge([.init(text: "replacement", start: 1, end: 2)], into: &words)
        XCTAssertEqual(words[0].romanWord, "original")
    }

    func testLegacyWordDecodesWithoutAnnotationTiming() throws {
        let word = try JSONDecoder().decode(LyricWord.self, from: Data(#"{"text":"字","start":0,"end":1,"romanWord":"zi"}"#.utf8))
        XCTAssertNil(word.romanStart)
        XCTAssertNil(word.romanEnd)
    }
}
