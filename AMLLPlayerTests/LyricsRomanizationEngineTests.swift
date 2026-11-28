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
        var placement = original
        placement.generatedRomanization = result.lines[0].tokens
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        let alignedLayout = AMLLCoreTextLayout(line: placement, width: 340,
                                               font: UIFont.systemFont(ofSize: 32), configuration: configuration)
        XCTAssertTrue(alignedLayout.hasGeneratedRomanizationLayout)
        let firstOriginal = alignedLayout.fragments.first { $0.word.text == "널" }
        let firstPronunciation = alignedLayout.rubyFragments.first { $0.kind == .romanization }
        XCTAssertEqual(firstPronunciation?.rect.minX, firstOriginal?.rect.minX)
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        canvas.position = { 0.75 }
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
        func findRomanization(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "lyricRow.generated-roman-0" { return view }
            return view.subviews.lazy.compactMap { findRomanization(in: $0) }.first
        }
        if let romanization = findRomanization(in: canvas) {
            func pixels() -> Data? {
                UIGraphicsImageRenderer(bounds: romanization.bounds).image {
                    romanization.layer.render(in: $0.cgContext)
                }.pngData()
            }
            let before = pixels()
            canvas.position = { 1.75 }
            canvas.configure(document: augmented, configuration: configuration,
                             input: .init(position: 1.75, playing: true, seekRevision: 1),
                             active: false, reduceMotion: false)
            canvas.advanceFrame(delta: 0)
            XCTAssertNotEqual(pixels(), before, "TTML pronunciation fill must advance on seek")
        }
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

    func testGeneratedKoreanUsesProjectedTTMLGeometryAndTime() async throws {
        let line = LyricLine(id: "roman", text: "부를래", start: 0, end: 4,
            words: [.init(text: "부", start: 0, end: 0.5), .init(text: "를", start: 0.5, end: 1.5),
                    .init(text: "래", start: 1.5, end: 4)], precision: .word)
        let source = document([line], language: "ko")
        let generated = await LyricsRomanizationEngine.shared.generate(document: source)
        let augmented = generated.applying(to: source)
        let cue = try XCTUnwrap(augmented.romanizationTTMLTrack?.cues.first)
        var placement = line
        placement.generatedRomanization = cue.tokens
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        configuration.selectAnimationStyle(.appleMusic164)
        let layout = AMLLCoreTextLayout(line: placement, width: 320, font: .systemFont(ofSize: 32),
                                        configuration: configuration)
        let (roman, projected) = try XCTUnwrap(layout.timedRomanization(for: line, cue: cue.line))
        let timed = roman.words.filter { $0.end > $0.start }
        XCTAssertEqual(timed.map(\.text), ["bu", "reul", "rae"])
        XCTAssertEqual(timed.map(\.start), [0, 0.5, 1.5])
        XCTAssertEqual(timed.map(\.end), [0.5, 1.5, 4])
        XCTAssertEqual(projected.fragments.map(\.rect), layout.rubyFragments.map(\.rect))
        XCTAssertGreaterThan(projected.characterFragments.count, timed.count)

        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        configuration.blurInactive = false
        func findRomanization(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "lyricRow.generated-roman-0" { return view }
            return view.subviews.lazy.compactMap { findRomanization(in: $0) }.first
        }
        func gradients(in layer: CALayer) -> [CAGradientLayer] {
            if layer.isHidden { return [] }
            if let mask = layer.mask as? CAGradientLayer { return [mask] }
            return (layer.sublayers ?? []).flatMap { gradients(in: $0) }
        }
        var revision = 0
        for height in [CGFloat(700), 370] {
            canvas.frame.size.height = height
            var sampledEdges: [[CGFloat]] = []
            for time in [0.3, 2.1, 0.3] {
                revision += 1
                canvas.position = { time }
                canvas.configure(document: augmented, configuration: configuration,
                                 input: .init(position: time, playing: false, seekRevision: revision, seekPosition: time),
                                 active: false, reduceMotion: false)
                canvas.advanceFrame(delta: 0)
                let row = try XCTUnwrap(findRomanization(in: canvas))
                let masks = gradients(in: row.layer)
                XCTAssertGreaterThan(masks.count, timed.count, "Use the native character renderer for the generated cue")
                sampledEdges.append(masks.map { $0.startPoint.x })
            }
            XCTAssertNotEqual(sampledEdges[0], sampledEdges[1])
            XCTAssertEqual(sampledEdges[0], sampledEdges[2])
        }
    }

    func testProviderRomanizationSharesPresetMaskAndEmphasisWithoutLifting() throws {
        let line = LyricLine(id: "match", text: "go", start: 0, end: 4,
            words: [.init(text: "go", start: 0, end: 4, romanWord: "go", romanStart: 0, romanEnd: 4)],
            precision: .word)
        let source = document([line])
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        canvas.position = { 2 }
        var configuration = LyricsRenderConfiguration()
        configuration.selectAnimationStyle(.appleMusic164)
        configuration.romanization = true
        configuration.auxiliaryScale = 1
        configuration.blurInactive = false
        func find(in view: UIView, identifier: String) -> UIView? {
            if view.accessibilityIdentifier == identifier { return view }
            return view.subviews.lazy.compactMap { find(in: $0, identifier: identifier) }.first
        }
        func glyphs(in layer: CALayer) -> [CALayer] {
            if layer.isHidden { return [] }
            if layer.mask is CAGradientLayer { return [layer] }
            return (layer.sublayers ?? []).flatMap { glyphs(in: $0) }
        }

        for (index, preset) in LyricsBlossomAnimationOptions.Preset.allCases.enumerated() {
            var options = LyricsBlossomAnimationOptions()
            options.apply(preset == .custom ? .appleMusic27 : preset)
            if preset == .custom { options.emphasis = 0; options.scale = 1 }
            configuration.appleMusicAnimation = options
            canvas.configure(document: source, configuration: configuration,
                             input: .init(position: 2, playing: false, seekRevision: index),
                             active: false, reduceMotion: false)
            canvas.advanceFrame(delta: 0)
            let main = try XCTUnwrap(find(in: canvas, identifier: "lyricRow.match"))
            let roman = try XCTUnwrap(find(in: canvas, identifier: "lyricRow.match.romanization"))
            let mainGlyphs = glyphs(in: main.layer)
            let romanGlyphs = glyphs(in: roman.layer)
            XCTAssertEqual(mainGlyphs.count, 2)
            XCTAssertEqual(romanGlyphs.count, mainGlyphs.count)
            XCTAssertTrue(mainGlyphs.contains { $0.affineTransform().ty != 0 })
            for (body, pronunciation) in zip(mainGlyphs, romanGlyphs) {
                let bodyMask = try XCTUnwrap(body.mask as? CAGradientLayer)
                let romanMask = try XCTUnwrap(pronunciation.mask as? CAGradientLayer)
                XCTAssertEqual(bodyMask.startPoint.x, romanMask.startPoint.x, accuracy: 0.0001)
                XCTAssertEqual(bodyMask.endPoint.x, romanMask.endPoint.x, accuracy: 0.0001)
                var emphasisOnly = body.affineTransform()
                emphasisOnly.ty = 0
                XCTAssertEqual(emphasisOnly, pronunciation.affineTransform())
                XCTAssertEqual(body.shadowRadius, pronunciation.shadowRadius)
                XCTAssertEqual(body.shadowOpacity, pronunciation.shadowOpacity)
            }
        }
    }

    func testWrappedPronunciationAddsGapBeforeTheNextBodyLine() throws {
        let line = LyricLine(id: "wrapped", text: "hello hello", start: 0, end: 4,
            words: [.init(text: "hello", start: 0, end: 2, romanWord: "he"),
                    .init(text: " ", start: 2, end: 2),
                    .init(text: "hello", start: 2, end: 4, romanWord: "he")], precision: .word)
        let font = UIFont.systemFont(ofSize: 32)
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = false
        let plain = AMLLCoreTextLayout(line: line, width: 95, font: font, configuration: configuration)
        configuration.romanization = true
        let annotated = AMLLCoreTextLayout(line: line, width: 95, font: font, configuration: configuration)
        let plainRows = Array(Set(plain.characterFragments.map(\.rect.minY))).sorted()
        let annotatedRows = Array(Set(annotated.characterFragments.map(\.rect.minY))).sorted()
        XCTAssertEqual(plainRows.count, 2)
        XCTAssertEqual(annotatedRows.count, 2)
        let first = try XCTUnwrap(annotatedRows.first)
        let second = try XCTUnwrap(annotatedRows.last)
        let normalStep = try XCTUnwrap(plainRows.last) - (try XCTUnwrap(plainRows.first))
        XCTAssertEqual(first, plainRows.first)
        XCTAssertEqual(second - first, normalStep + 16 + 6.4, accuracy: 0.001)
        XCTAssertEqual(annotated.size.height - plain.size.height, 32 + 6.4, accuracy: 0.001)
    }

    func testBodyAndPronunciationHitTheSameSeekGestureWithEitherLayout() throws {
        let line = LyricLine(id: "body", text: "hold", start: 0, end: 5,
            words: [.init(text: "hold", start: 0, end: 5, romanWord: "hold")], precision: .word)
        let separate = LyricLine(id: "separate", text: "ho ld", start: 0, end: 5,
            words: [.init(text: "ho ", start: 0, end: 2), .init(text: "ld", start: 2, end: 5)], precision: .word)
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        var calls: [String] = []
        canvas.onInteraction = { if case let .seek(lineID) = $0 { calls.append(lineID) } }
        canvas.position = { 1 }
        var configuration = LyricsRenderConfiguration()
        configuration.selectAnimationStyle(.appleMusic164)
        configuration.romanization = true
        func find(in view: UIView, id: String) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            return view.subviews.lazy.compactMap { find(in: $0, id: id) }.first
        }
        func taps(from hit: UIView?) -> [UITapGestureRecognizer] {
            guard let hit, hit !== canvas else { return [] }
            let tapsHere = (hit.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }.filter(\.isEnabled)
            return tapsHere + taps(from: hit.superview)
        }
        for immersive in [false, true] {
            canvas.frame.size.height = immersive ? 370 : 700
            configuration.immersiveLyrics = immersive
            for projected in [false, true] {
                var source = document([line])
                if !projected {
                    source.romanizationTTMLTrack = .init(ttml: "", cues: [.init(sourceLineIndex: 0, line: separate, tokens: [])])
                }
                canvas.configure(document: source, configuration: configuration,
                                 input: .init(position: 1, playing: false), active: false, reduceMotion: false)
                canvas.advanceFrame(delta: 0)
                let body = try XCTUnwrap(find(in: canvas, id: "lyricRow.body"))
                let pronunciation = try XCTUnwrap(find(in: canvas, id: projected ? "lyricRow.body.romanization" : "lyricRow.separate"))
                let bodyPoint = body.convert(CGPoint(x: 12, y: 12), to: canvas)
                let pronunciationPoint = projected
                    ? pronunciation.convert(CGPoint(x: 12, y: 46), to: canvas)
                    : pronunciation.convert(CGPoint(x: 12, y: 8), to: canvas)
                let bodyTap = taps(from: canvas.hitTest(bodyPoint, with: nil))
                let pronunciationTap = taps(from: canvas.hitTest(pronunciationPoint, with: nil))
                XCTAssertEqual(bodyTap.count, 1)
                XCTAssertEqual(pronunciationTap.count, 1)
                XCTAssertTrue(bodyTap.first === pronunciationTap.first)
                XCTAssertTrue(body.accessibilityActivate())
                XCTAssertTrue(pronunciation.accessibilityActivate())
            }
        }
        XCTAssertEqual(calls, Array(repeating: "body", count: 8))
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

    func testCancelledCachedGenerationDoesNotPersistPartialResult() async throws {
        let engine = LyricsRomanizationEngine()
        try await engine.clearGeneratedCache()
        let doc = document([
            .init(id: "ko-cancel", text: "사랑해 \(UUID().uuidString)", start: 0, end: 2),
        ], language: "ko")

        let gate = AsyncStream<Void>.makeStream()
        let cancelledTask = Task {
            for await _ in gate.stream { break }
            return await engine.generateCached(document: doc)
        }
        cancelledTask.cancel()
        gate.continuation.finish()
        let cancelledResult = await cancelledTask.value
        XCTAssertTrue(cancelledResult.lines.isEmpty)

        let completeResult = await engine.generateCached(document: doc)
        XCTAssertEqual(completeResult.lines.count, 1)
    }
}
