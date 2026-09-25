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
        XCTAssertNil(augmented.lines[0].generatedRomanization)
        let cue = augmented.romanizationTTMLTrack?.line(for: 0)
        XCTAssertEqual(cue?.text, "neol bu reul rae Baby")
        XCTAssertEqual(cue?.words.map(\.start).filter { $0 > 0 }.first, 0.6)
        XCTAssertTrue(result.ttml.contains("<span begin=\"0.600000s\" end=\"0.900000s\">bu</span>"))
    }

    func testJapanesePinnedDictionaryAndMixedLanguage() async {
        let result = await LyricsRomanizationEngine.shared.generate(document: document([
            .init(id: "ja", text: "君の名は Baby", start: 0, end: 2),
            .init(id: "ko", text: "사랑해", start: 2, end: 4),
            .init(id: "zh", text: "我爱你", start: 4, end: 6),
        ]))
        XCTAssertEqual(result.lines.map(\.text), ["kimi no na wa Baby", "sa rang hae"])
        XCTAssertEqual(result.lines[0].tokens.map(\.sourceText), ["君", "の", "名", "は", "Baby"])
        // In a Japanese corpus the Han-only line is inspected, then rejected
        // by strict dictionary coverage; it is not emitted as pronunciation.
        XCTAssertEqual(result.processedLineIndexes, [0, 1, 2])
    }

    func testJapaneseDictionaryBoundaryInsideOneTimedProviderWordKeepsItsTime() async {
        let original = LyricLine(id: "ja-wide", text: "君の名は", start: 0, end: 2,
                                 words: [.init(text: "君の名は", start: 0, end: 2)], precision: .word)
        let source = document([original], language: "ja")
        let result = await LyricsRomanizationEngine.shared.generate(document: source)
        let augmented = result.applying(to: source)
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        let layout = AMLLCoreTextLayout(line: augmented.lines[0], width: 600,
                                        font: UIFont.systemFont(ofSize: 32), configuration: configuration)
        XCTAssertEqual(layout.sourceAtoms.map(\.word.text).joined(), original.text)
        XCTAssertTrue(layout.rubyFragments.filter { $0.kind == .romanization }.isEmpty)
        let pronunciation = augmented.romanizationTTMLTrack?.line(for: 0)
        XCTAssertEqual(pronunciation?.text, "kimi no na wa")
        XCTAssertGreaterThan(pronunciation?.words.count ?? 0, 1)
        XCTAssertTrue(pronunciation?.words.allSatisfy { $0.start == 0 && $0.end == 2 } ?? false)
    }

    func testGeneratedLineFallbackTakesPriorityOverProviderWordAnnotation() async {
        let original = LyricLine(id: "ja-provider", text: "君の名は", start: 0, end: 2,
                                 words: [.init(text: "君の名は", start: 0, end: 2, romanWord: "provider")],
                                 precision: .word)
        let source = document([original], language: "ja")
        let result = await LyricsRomanizationEngine.shared.generate(document: source)
        let augmented = result.applying(to: source)
        let line = augmented.lines[0]
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        let layout = AMLLCoreTextLayout(line: line, width: 600,
                                        font: UIFont.systemFont(ofSize: 32), configuration: configuration)
        // Source annotations stay intact for fallback; the canvas hides them
        // only in its display copy when an independent TTML cue exists.
        XCTAssertFalse(layout.rubyFragments.filter { $0.kind == .romanization }.isEmpty)
        XCTAssertEqual(line.words[0].romanWord, "provider")
        XCTAssertEqual(augmented.romanizationTTMLTrack?.line(for: 0)?.text, "kimi no na wa")
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
        let augmented = result.applying(to: base)
        let line = augmented.lines[0]
        XCTAssertTrue(line.words.isEmpty)
        XCTAssertEqual(augmented.romanizationTTMLTrack?.line(for: 0)?.precision, .line)
        XCTAssertTrue(augmented.romanizationTTMLTrack?.line(for: 0)?.words.isEmpty ?? false)
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        XCTAssertTrue(configuration.auxiliaryText(for: line).isEmpty)
    }

    func testGeneratedTTMLIsIndependentAndEscapesProviderText() async {
        let original = LyricLine(id: "ko-xml", text: "사랑해 & Baby", start: 1, end: 4,
                                 words: [.init(text: "사랑해", start: 1, end: 2),
                                         .init(text: " ", start: 2, end: 2),
                                         .init(text: "&", start: 2, end: 2.2),
                                         .init(text: " ", start: 2.2, end: 2.2),
                                         .init(text: "Baby", start: 2.2, end: 4)], precision: .word)
        let source = document([original])
        let result = await LyricsRomanizationEngine.shared.generate(document: source)
        XCTAssertTrue(result.ttml.contains("&amp;"))
        XCTAssertTrue(result.ttml.contains("generated-roman-0"))
        let documentWithTrack = result.applying(to: source)
        XCTAssertEqual(documentWithTrack.lines, source.lines)
        XCTAssertEqual(documentWithTrack.romanizationTTMLTrack?.line(for: 0)?.text, "sa rang hae & Baby")
        XCTAssertEqual(documentWithTrack.romanizationTTMLTrack?.line(for: 0)?.words.first?.start, 1)
        XCTAssertEqual(documentWithTrack.romanizationTTMLTrack?.line(for: 0)?.words.first?.end, 2)
        if let cue = documentWithTrack.romanizationTTMLTrack?.line(for: 0) {
            var configuration = LyricsRenderConfiguration()
            configuration.romanization = false
            configuration.translation = false
            let font = UIFont.systemFont(ofSize: 32)
            let pronunciation = AMLLCoreTextLayout(line: cue, width: 600,
                                                    font: font.withSize(16), configuration: configuration)
            let ordinary = AMLLCoreTextLayout(line: original, width: 600, font: font,
                                              configuration: configuration)
            let combined = AMLLCoreTextLayout(line: original, width: 600, font: font,
                                              configuration: configuration,
                                              romanizationReserve: pronunciation.size.height)
            XCTAssertNotNil(combined.romanizationSlotY)
            XCTAssertGreaterThan(combined.size.height, ordinary.size.height)
        }
    }

    func testNativeCanvasCreatesSeparateRomanizationRowFromTTML() async {
        let original = LyricLine(id: "original", text: "널 부를래", start: 0, end: 2,
                                 words: [.init(text: "널", start: 0, end: 0.5),
                                         .init(text: " ", start: 0.5, end: 0.5),
                                         .init(text: "부", start: 0.5, end: 1),
                                         .init(text: "를", start: 1, end: 1.5),
                                         .init(text: "래", start: 1.5, end: 2)],
                                 precision: .word)
        let source = document([original])
        let result = await LyricsRomanizationEngine.shared.generate(document: source)
        let augmented = result.applying(to: source)
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        canvas.position = { 0.75 }
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        canvas.configure(document: augmented, configuration: configuration,
                         input: .init(position: 0.75, playing: true), active: false,
                         reduceMotion: false)
        canvas.advanceFrame(delta: 1.0 / 60)
        func identifiers(in view: UIView) -> [String] {
            (view.accessibilityIdentifier.map { [$0] } ?? [])
                + view.subviews.flatMap { identifiers(in: $0) }
        }
        let rows = identifiers(in: canvas)
        XCTAssertTrue(rows.contains("lyricRow.original"))
        XCTAssertTrue(rows.contains("lyricRow.generated-roman-0"))
        XCTAssertEqual(augmented.lines[0], original)
    }

    func testDistinctSourceLineRomanizationSurvivesGeneratedInlineWords() async {
        var line = LyricLine(id: "ko", text: "사랑해", start: 0, end: 2, words: [
            .init(text: "사랑해", start: 0, end: 2),
        ], romanization: "independent source version", precision: .word)
        let result = await LyricsRomanizationEngine.shared.generate(document: document([line]))
        let augmented = result.applying(to: document([line]))
        line = augmented.lines[0]
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        XCTAssertEqual(configuration.auxiliaryText(for: line), ["independent source version"])
        XCTAssertEqual(augmented.romanizationTTMLTrack?.line(for: 0)?.text, "sa rang hae")
        XCTAssertNil(line.generatedRomanization)
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
