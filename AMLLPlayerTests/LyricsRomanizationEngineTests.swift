@testable import AMLLPlayer
import UIKit
import XCTest

@MainActor
final class LyricsRomanizationEngineTests: XCTestCase {
    private struct SourceFixtures: Decodable {
        struct Case: Decodable {
            struct Line: Decodable {
                struct Token: Decodable {
                    var sourceText: String
                    var romanized: String
                    var utf16Start: Int
                    var utf16End: Int
                }

                var text: String
                var language: String
                var coverage: Double
                var tokens: [Token]
            }

            var name: String
            var text: String
            var languageHint: String
            var lines: [Line]
        }

        var cases: [Case]
    }

    private func document(_ lines: [LyricLine], language: String = "") -> LyricsDocument {
        let candidate = LyricCandidate(source: .qq, sourceID: "test", title: "Test", artists: ["Test"])
        return LyricsDocument(candidate: candidate, lines: lines, language: language, selectionReason: "test")
    }

    func testKoreanVisualWordKeepsOriginalTimedNodes() async {
        let line = LyricLine(id: "ko", text: "널 부를래 Baby", start: 0, end: 2.4, words: [
            .init(text: "널", start: 0, end: 0.6),
            .init(text: " ", start: 0.6, end: 0.6),
            .init(text: "부", start: 0.6, end: 0.9),
            .init(text: "를", start: 0.9, end: 1.2),
            .init(text: "래", start: 1.2, end: 1.6),
            .init(text: " ", start: 1.6, end: 1.6),
            .init(text: "Baby", start: 1.6, end: 2.4),
        ], precision: .word)
        let result = await LyricsRomanizationEngine.shared.generate(document: document([line]))
        XCTAssertEqual(result.lines.first?.text, "neol bu reul rae Baby")
        XCTAssertEqual(result.lines.first?.tokens[1].sourceNodeIndexes, [2, 3, 4])
        let augmented = result.applying(to: document([line]))
        XCTAssertEqual(augmented.lines[0].words[2].start, 0.6)
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        let layout = AMLLCoreTextLayout(line: augmented.lines[0], width: 600,
                                        font: UIFont.systemFont(ofSize: 32), configuration: configuration)
        XCTAssertFalse(layout.rubyFragments.filter { $0.kind == .romanization }.isEmpty)
        XCTAssertTrue(configuration.auxiliaryText(for: augmented.lines[0], displayingInlineRomanization: true).isEmpty)
    }

    func testJapanesePinnedDictionaryAndMixedLanguage() async {
        let result = await LyricsRomanizationEngine.shared.generate(document: document([
            .init(id: "ja", text: "君の名は Baby", start: 0, end: 2),
            .init(id: "ko", text: "사랑해", start: 2, end: 4),
            .init(id: "zh", text: "我爱你", start: 4, end: 6),
        ]))
        XCTAssertEqual(result.lines.map(\.text), ["kimi no na wa Baby", "sa rang hae"])
        XCTAssertEqual(result.lines[0].tokens.map(\.sourceText), ["君", "の", "名", "は", "Baby"])
        XCTAssertEqual(result.processedLineIndexes, [0, 1])
    }

    func testJapaneseDictionaryBoundaryInsideOneTimedProviderWordKeepsItsTime() async {
        let original = LyricLine(id: "ja-wide", text: "君の名は", start: 0, end: 2,
                                 words: [.init(text: "君の名は", start: 0, end: 2)], precision: .word)
        let source = document([original], language: "ja")
        let result = await LyricsRomanizationEngine.shared.generate(document: source)
        let augmented = result.applying(to: source).lines[0]
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        let layout = AMLLCoreTextLayout(line: augmented, width: 600,
                                        font: UIFont.systemFont(ofSize: 32), configuration: configuration)
        XCTAssertEqual(layout.sourceAtoms.map(\.word.text).joined(), original.text)
        XCTAssertGreaterThan(layout.sourceAtoms.count, 1)
        XCTAssertTrue(layout.sourceAtoms.allSatisfy { $0.sourceWordIndex == 0 && $0.word.start == 0 && $0.word.end == 2 })
        XCTAssertTrue(layout.diagnostics.isEmpty)
        let pronunciation = layout.rubyFragments.filter { $0.kind == .romanization }
        XCTAssertFalse(pronunciation.isEmpty)
        XCTAssertTrue(pronunciation.allSatisfy { $0.motionStart == 0 && $0.motionEnd == 2 })
    }

    func testPinnedMineradioSourceFixtures() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mineradio-romanization", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(SourceFixtures.self, from: Data(contentsOf: url))
        for item in fixtures.cases {
            let input = document([.init(id: item.name, text: item.text, start: 0, end: 2)], language: item.languageHint)
            let result = await LyricsRomanizationEngine.shared.generate(document: input)
            XCTAssertEqual(result.lines.count, item.lines.count, item.name)
            for (actual, expected) in zip(result.lines, item.lines) {
                XCTAssertEqual(actual.text, expected.text, item.name)
                XCTAssertEqual(actual.language, expected.language, item.name)
                XCTAssertEqual(actual.coverage, expected.coverage, accuracy: 0.0001, item.name)
                XCTAssertEqual(actual.tokens.map(\.sourceText), expected.tokens.map(\.sourceText), item.name)
                XCTAssertEqual(actual.tokens.map(\.romanized), expected.tokens.map(\.romanized), item.name)
                XCTAssertEqual(actual.tokens.map(\.utf16Start), expected.tokens.map(\.utf16Start), item.name)
                XCTAssertEqual(actual.tokens.map(\.utf16End), expected.tokens.map(\.utf16End), item.name)
            }
        }
    }

    func testLineLyricsNeverAcquireInventedWordTimes() async {
        let base = document([.init(id: "line", text: "널 사랑해", start: 1, end: 3, precision: .line)])
        let result = await LyricsRomanizationEngine.shared.generate(document: base)
        XCTAssertEqual(result.lines.first?.tokens.flatMap(\.sourceNodeIndexes), [])
        let line = result.applying(to: base).lines[0]
        XCTAssertTrue(line.words.isEmpty)
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        XCTAssertEqual(configuration.auxiliaryText(for: line), ["neol sa rang hae"])
    }

    func testDistinctSourceLineRomanizationSurvivesGeneratedInlineWords() async {
        var line = LyricLine(id: "ko", text: "사랑해", start: 0, end: 2, words: [
            .init(text: "사랑해", start: 0, end: 2),
        ], romanization: "independent source version", precision: .word)
        let result = await LyricsRomanizationEngine.shared.generate(document: document([line]))
        line = result.applying(to: document([line])).lines[0]
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        XCTAssertEqual(configuration.auxiliaryText(for: line, displayingInlineRomanization: true),
                       ["independent source version"])
        line.romanization = "sa rang hae"
        XCTAssertTrue(configuration.auxiliaryText(for: line, displayingInlineRomanization: true).isEmpty)
    }

    func testOverrideImportFailurePreservesCurrentValue() async throws {
        let engine = LyricsRomanizationEngine()
        let original = try await engine.exportOverrides()
        do {
            try await engine.importOverrides(Data("{broken".utf8))
            XCTFail("Malformed overrides must be rejected")
        } catch {}
        let current = try await engine.exportOverrides()
        XCTAssertEqual(current, original)
    }
}
