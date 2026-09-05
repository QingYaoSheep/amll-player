@testable import AMLLPlayer
import XCTest

final class LyricsParserTests: XCTestCase {
    func testAppleSemanticGoldenMatchesMITPlugin02921() throws {
        struct Golden: Decodable {
            let text: String; let start: Double; let end: Double
            let translation: String; let romanization: String; let isBackground: Bool; let isDuet: Bool
            let words: [LyricWord]
        }
        let bundle = Bundle(for: Self.self)
        let xmlURL = try XCTUnwrap(bundle.url(forResource: "apple-semantic", withExtension: "ttml"))
        let goldenURL = try XCTUnwrap(bundle.url(forResource: "apple-semantic.golden", withExtension: "json"))
        let lines = try TTMLLyricsParser.parse(String(contentsOf: xmlURL, encoding: .utf8), duration: 12)
        let golden = try JSONDecoder().decode([Golden].self, from: Data(contentsOf: goldenURL))
        XCTAssertEqual(lines.count, golden.count)
        for (line, expected) in zip(lines, golden) {
            XCTAssertEqual(line.text, expected.text); XCTAssertEqual(line.start, expected.start, accuracy: 0.0001)
            XCTAssertEqual(line.end, expected.end, accuracy: 0.0001)
            XCTAssertEqual(line.translation, expected.translation); XCTAssertEqual(line.romanization, expected.romanization)
            XCTAssertEqual(line.isBackground, expected.isBackground); XCTAssertEqual(line.isDuet, expected.isDuet)
            XCTAssertEqual(line.words, expected.words)
        }
    }

    func testNamespacePrefixAndInheritedNestedTiming() throws {
        let xml = #"<x:tt xmlns:x="http://www.w3.org/ns/ttml"><x:body><x:div><x:p begin="1s" end="5s"><x:span begin="2s" end="4s"><x:span>One</x:span></x:span>!</x:p></x:div></x:body></x:tt>"#
        let line = try XCTUnwrap(TTMLLyricsParser.parse(xml).first)
        XCTAssertEqual(line.text, "One!"); XCTAssertEqual(line.words.map(\.text), ["One!"])
        XCTAssertEqual(line.words.first?.start, 2); XCTAssertEqual(line.words.first?.end, 4)
    }

    func testRelativeTimingUsesParentAndDuration() throws {
        let xml = #"<tt><body begin="10s" end="30s"><div><p begin="2s" dur="5s"><span begin="1s" dur="2s">One</span></p></div></body></tt>"#
        let line = try XCTUnwrap(TTMLLyricsParser.parse(xml, timingMode: .relative).first)
        XCTAssertEqual(line.start, 12); XCTAssertEqual(line.end, 17)
        XCTAssertEqual(line.words.first?.start, 13); XCTAssertEqual(line.words.first?.end, 15)
    }

    func testNestedUntimedFormattingIsOneTimedWord() throws {
        let xml = #"<tt><body><p begin="1s" end="3s"><span begin="1s" end="2s">Hel<span>lo</span></span>!</p></body></tt>"#
        let line = try XCTUnwrap(TTMLLyricsParser.parse(xml).first)
        XCTAssertEqual(line.words.count, 1); XCTAssertEqual(line.words.first?.text, "Hello!")
    }

    func testPreservedSpacesAndTrailingPunctuation() throws {
        let xml = #"<tt xml:space="preserve"><body><p begin="1s" end="4s"><span begin="1s" end="2s">A</span>  <span begin="2s" end="3s">B</span>!</p></body></tt>"#
        let line = try XCTUnwrap(TTMLLyricsParser.parse(xml).first)
        XCTAssertEqual(line.text, "A  B!"); XCTAssertEqual(line.words.map(\.text), ["A  ", "B!"])
    }

    func testBackgroundBracketOnlyWordsKeepWholeRange() throws {
        let xml = #"<tt xmlns:ttm="urn:metadata"><body><p begin="1s" end="6s">Main<span ttm:role="x-bg" begin="2s" end="5s"><span begin="2s" end="3s">(</span><span begin="3s" end="4s">echo</span><span begin="4s" end="5s">)</span></span></p></body></tt>"#
        let lines = try TTMLLyricsParser.parse(xml)
        XCTAssertEqual(lines.map(\.text), ["Main", "echo"])
        XCTAssertEqual(lines.last?.words.count, 1); XCTAssertEqual(lines.last?.words.first?.start, 2); XCTAssertEqual(lines.last?.words.first?.end, 5)
        XCTAssertEqual(lines.first?.precision, .line)
    }

    func testRejectsDTDAndEntityDeclarations() {
        XCTAssertThrowsError(try TTMLLyricsParser.parse(#"<!DOCTYPE tt [<!ENTITY x SYSTEM "file:///etc/passwd">]><tt><body><p>&x;</p></body></tt>"#))
    }

    func testRejectsDeepXMLAndMalformedTiming() {
        XCTAssertThrowsError(try TTMLLyricsParser.parse("<tt>" + String(repeating: "<div>", count: 70) + String(repeating: "</div>", count: 70) + "</tt>"))
        XCTAssertThrowsError(try TTMLLyricsParser.parse(#"<tt><body><p begin="NaN">bad</p></body></tt>"#))
        XCTAssertThrowsError(try TTMLLyricsParser.parse(#"<tt><body timeContainer="seq"><p>bad</p></body></tt>"#))
        XCTAssertThrowsError(try TTMLLyricsParser.parse("<tt><body></tt>"))
    }

    func testLRCMultiTagsFractionAndQuarterSecondAlignment() throws {
        let lines = try LRCLyricsParser.parse("[00:01.1][00:02.12]one\n[00:04.123]two", translation: "[00:01.350]一\n[00:04.374]不对齐", romanization: "[00:02.120]yi", duration: 6)
        XCTAssertEqual(lines.map(\.start), [1.1, 2.12, 4.123]); XCTAssertEqual(lines.map(\.end), [2.12, 4.123, 6])
        XCTAssertEqual(lines.first?.translation, "一"); XCTAssertEqual(lines.last?.translation, "")
        XCTAssertEqual(lines[1].romanization, "yi"); XCTAssertTrue(lines.allSatisfy { $0.words.isEmpty && $0.precision == .line })
    }

    func testLRCSemanticGoldenUsesExplicitHalfOpenLineAdapter() throws {
        struct Input: Decodable { let original: String; let translation: String; let romanization: String; let durationMs: Double }
        struct Golden: Decodable { let text: String; let start: Double; let end: Double; let translation: String; let romanization: String }
        let bundle = Bundle(for: Self.self)
        let inputURL = try XCTUnwrap(bundle.url(forResource: "lrc-semantic.input", withExtension: "json"))
        let goldenURL = try XCTUnwrap(bundle.url(forResource: "lrc-semantic.golden", withExtension: "json"))
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: inputURL))
        let golden = try JSONDecoder().decode([Golden].self, from: Data(contentsOf: goldenURL))
        let lines = try LRCLyricsParser.parse(input.original, translation: input.translation, romanization: input.romanization, duration: input.durationMs / 1000)
        XCTAssertEqual(lines.count, golden.count)
        for (line, expected) in zip(lines, golden) {
            XCTAssertEqual(line.text, expected.text); XCTAssertEqual(line.start, expected.start, accuracy: 0.0001)
            XCTAssertEqual(line.end, expected.end, accuracy: 0.0001); XCTAssertEqual(line.translation, expected.translation)
            XCTAssertEqual(line.romanization, expected.romanization); XCTAssertTrue(line.words.isEmpty)
        }
    }

    func testLRCOffsetDuplicateTimesAndUnknownDuration() throws {
        let lines = try LRCLyricsParser.parse("[offset:-100]\n[00:01]a\n[00:01]b\n[00:03]c", duration: 0)
        XCTAssertEqual(lines.map(\.start), [0.9, 0.9, 2.9]); XCTAssertEqual(lines.map(\.end), [2.9, 2.9, 7.9])
    }

    func testBase64UTF8AndInvalidEncoding() throws {
        let raw = "[00:01.001]你好 🎵"
        XCTAssertEqual(try LRCLyricsParser.decodeField(Data(raw.utf8).base64EncodedString()), raw)
        XCTAssertEqual(try LRCLyricsParser.decodeField(raw), raw)
        XCTAssertThrowsError(try LRCLyricsParser.decodeField("not base64!"))
    }

    func testNoInventedWordsForPlainTTMLLine() throws {
        let line = try XCTUnwrap(TTMLLyricsParser.parse(#"<tt><body><p begin="1s" end="4s">Plain line</p></body></tt>"#).first)
        XCTAssertEqual(line.precision, .line); XCTAssertTrue(line.words.isEmpty)
    }

    func testRTLDoesNotTreatJapaneseAsRightToLeft() throws {
        let japanese = try TTMLLyricsParser.parse(#"<tt xml:lang="ja"><body><p begin="1s" end="2s">こんにちは</p></body></tt>"#)
        let arabic = try TTMLLyricsParser.parse(#"<tt xml:lang="ar"><body><p begin="1s" end="2s">مرحبا</p></body></tt>"#)
        XCTAssertEqual(japanese.first?.isRTL, false); XCTAssertEqual(arabic.first?.isRTL, true)
    }

    func testMatchingISRCWinsWithoutInventingEvidence() {
        let track = TrackIdentity(spotifyID: "spotify", title: "Title", artists: ["Artist"], duration: 200, isrc: "US123")
        let candidate = LyricCandidate(source: .apple, sourceID: "apple", title: "Localized", artists: [], isrc: "US123")
        let result = LyricsMatcher.scored(candidate, against: track)
        XCTAssertEqual(result.score, 100); XCTAssertEqual(result.evidence, ["ISRC"])
        XCTAssertEqual(LyricsMatcher.similarity("Café!", "CAFE"), 1)
    }

    func testInstrumentalIsDistinctFromEmptyLyrics() throws {
        let candidate = LyricCandidate(source: .netease, sourceID: "1", title: "t", artists: [])
        let payload = LyricsPayload(format: .lrc, original: "", isInstrumental: true)
        XCTAssertTrue(try payload.parse(candidate: candidate, duration: 1).isInstrumental)
        XCTAssertThrowsError(try LyricsPayload(format: .lrc, original: "").parse(candidate: candidate, duration: 1))
    }
}
