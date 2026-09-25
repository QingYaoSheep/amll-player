@testable import AMLLPlayer
import CoreText
import UIKit
import XCTest

final class AMLLNativeEngineTests: XCTestCase {
    @MainActor
    func testInlineRomanizationDoesNotRepeatMatchingProviderLine() {
        let words = [
            LyricWord(text: "Hello ", start: 0, end: 1, romanWord: "heh"),
            LyricWord(text: "world", start: 1, end: 2, romanWord: "wo"),
        ]
        let line = LyricLine(id: "duplicate-roman", text: "Hello world", start: 0, end: 2,
                             words: words, translation: "你好，世界", romanization: "heh   wo", precision: .word)
        let configuration = LyricsRenderConfiguration()
        let layout = AMLLCoreTextLayout(line: line, width: 300, font: .systemFont(ofSize: 32), configuration: configuration)
        XCTAssertEqual(layout.rubyFragments.filter { $0.kind == .romanization }.count, 2)
        XCTAssertEqual(configuration.auxiliaryText(for: line, displayingInlineRomanization: true), ["你好，世界"])
        XCTAssertEqual(configuration.accessibilityText(for: line, displayingInlineRomanization: true),
                       "Hello, heh, world, wo, 你好，世界")

        var hidden = configuration
        hidden.romanization = false
        XCTAssertEqual(hidden.accessibilityText(for: line, displayingInlineRomanization: false),
                       "Hello world, 你好，世界")
        XCTAssertFalse(AMLLCoreTextLayout(line: line, width: 300, font: .systemFont(ofSize: 32),
                                          configuration: hidden).rubyFragments.contains { $0.kind == .romanization })
    }

    @MainActor
    func testDistinctLineRomanizationSurvivesInlineWords() {
        let words = [LyricWord(text: "漢", start: 0, end: 1, romanWord: "kan")]
        let line = LyricLine(id: "independent-roman", text: "漢", start: 0, end: 1,
                             words: words, romanization: "independent line", precision: .word)
        let configuration = LyricsRenderConfiguration()
        XCTAssertEqual(configuration.auxiliaryText(for: line, displayingInlineRomanization: true), ["independent line"])
        XCTAssertEqual(configuration.accessibilityText(for: line, displayingInlineRomanization: true),
                       "漢, kan, independent line")
    }

    func testVoiceOverUsesTheWordsActuallyShapedByInlineLayout() {
        let line = LyricLine(id: "summary-differs", text: "provider summary", start: 0, end: 1,
                             words: [.init(text: "歌", start: 0, end: 1, romanWord: "ge")], precision: .word)
        XCTAssertEqual(LyricsRenderConfiguration().accessibilityText(for: line, displayingInlineRomanization: true),
                       "歌, ge")
    }

    @MainActor
    func testInlinePronunciationPreservesMultilingualOwnershipAndProviderTime() throws {
        struct Fixture: Decodable {
            struct Line: Decodable {
                struct Word: Decodable { var word: String; var romanWord: String }
                var words: [Word]
            }

            var lines: [Line]
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "romanization-containers", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for source in fixture.lines {
            let text = try XCTUnwrap(source.words.first).word
            let word = LyricWord(text: text, start: 0, end: 4, romanWord: source.words[0].romanWord,
                                 romanStart: 0.25, romanEnd: 3.75)
            let line = LyricLine(id: text, text: text, start: 0, end: 4, words: [word], precision: .word)
            var configuration = LyricsRenderConfiguration()
            configuration.romanization = true
            let layout = AMLLCoreTextLayout(line: line, width: 160, font: .systemFont(ofSize: 32), configuration: configuration)
            let annotations = layout.rubyFragments.filter { $0.kind == .romanization }
            XCTAssertFalse(annotations.isEmpty, text)
            XCTAssertEqual(layout.sourceAtoms.count, 1, text)
            XCTAssertEqual(layout.sourceAtoms[0].sourceRange.length, text.utf16.count)
            XCTAssertTrue(annotations.allSatisfy { $0.start == 0.25 && $0.end == 3.75 }, text)
            configuration.romanization = false
            let hidden = AMLLCoreTextLayout(line: line, width: 160, font: .systemFont(ofSize: 32), configuration: configuration)
            XCTAssertFalse(hidden.rubyFragments.contains { $0.kind == .romanization }, text)
            XCTAssertEqual(line.words[0], word)
        }
    }

    func testSplitAtomsRetainSourceUTF16OwnershipWithoutSplittingGraphemes() {
        let words: [LyricWord] = [
            .init(text: "中日", start: 1, end: 3),
            .init(text: "a  👩‍💻 é", start: 3, end: 6, romanWord: "one annotation"),
            .init(text: "עברית", start: 6, end: 8),
        ]
        let atoms = AMLLWordSegmentation.mappedChunks(words).flatMap(\.self)
        for (index, word) in words.enumerated() {
            let owned = atoms.filter { $0.sourceWordIndex == index }
            XCTAssertEqual(owned.map(\.word.text).joined(), word.text)
            var offset = 0
            for atom in owned {
                XCTAssertEqual(atom.sourceRange.location, offset)
                XCTAssertNotNil(Range(atom.sourceRange, in: word.text))
                XCTAssertEqual((word.text as NSString).substring(with: atom.sourceRange), atom.word.text)
                offset = NSMaxRange(atom.sourceRange)
            }
            XCTAssertEqual(offset, word.text.utf16.count)
        }
        XCTAssertEqual(atoms.filter { $0.sourceWordIndex == 0 }.count, 2)
        XCTAssertEqual(atoms.filter { $0.sourceWordIndex == 1 }.map(\.word.romanWord), ["one annotation"])
        XCTAssertEqual(words[1].romanWord, "one annotation")
    }

    @MainActor
    func testProviderPhraseKeepsSingleInlineRomanizationContainer() {
        let line = LyricLine(id: "phrase", text: "one two", start: 0, end: 5,
                             words: [.init(text: "one two", start: 0, end: 5, romanWord: "single annotation")], precision: .word)
        var configuration = LyricsRenderConfiguration()
        configuration.romanization = true
        let layout = AMLLCoreTextLayout(line: line, width: 300, font: .systemFont(ofSize: 32), configuration: configuration)
        XCTAssertTrue(layout.diagnostics.isEmpty)
        let annotations = layout.rubyFragments.filter { $0.kind == .romanization }
        XCTAssertFalse(annotations.isEmpty)
        XCTAssertTrue(annotations.allSatisfy { $0.wordIndex == 0 && $0.start == 0 && $0.end == 5 })
        XCTAssertEqual(layout.sourceAtoms.count, 1)
        XCTAssertEqual(configuration.auxiliaryText(for: line).filter { $0 == "single annotation" }.count, 1)
        XCTAssertTrue(layout.sourceAtoms.allSatisfy { $0.sourceWordIndex == 0 })
    }

    @MainActor
    func testShapedFragmentsResolveToOriginalWordOwnership() {
        let line = LyricLine(id: "ownership", text: "中文 hello", start: 0, end: 5,
                             words: [.init(text: "中文", start: 0, end: 2),
                                     .init(text: " hello", start: 2, end: 5, romanWord: "greeting")], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 180, font: .systemFont(ofSize: 32), configuration: .init())
        XCTAssertFalse(layout.fragments.isEmpty)
        for fragment in layout.fragments {
            let atom = layout.sourceAtoms[fragment.wordIndex]
            let original = line.words[atom.sourceWordIndex]
            XCTAssertEqual((original.text as NSString).substring(with: atom.sourceRange), fragment.word.text)
        }
    }

    func testReleaseCoastsAndKeepsBlurOffUntilNextLyric() {
        let lines: [LyricLine] = (0 ..< 10).map { (index: Int) -> LyricLine in
            LyricLine(id: String(index), text: "Line", start: Double(index) * 10, end: Double(index) * 10 + 9)
        }
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32),
                                     heights: Array(repeating: 60, count: 10))
        _ = engine.render(.init(position: 1, playing: true), delta: 0)
        engine.handle(.beginBrowsing)
        engine.handle(.browseBy(40))
        let drag = engine.render(.init(position: 1, playing: true), delta: 0)
        XCTAssertTrue(drag.rows.allSatisfy { $0.blur == 0 })
        engine.handle(.endBrowsing(velocity: -600))
        let coast = engine.render(.init(position: 1.1, playing: true), delta: 0.1)
        XCTAssertLessThan(coast.rows[0].y, drag.rows[0].y)
        XCTAssertLessThan(drag.rows[0].y - coast.rows[0].y, 96)
        let resting = engine.render(.init(position: 8, playing: true), delta: 6.9)
        XCTAssertTrue(resting.browsing)
        XCTAssertTrue(resting.rows.allSatisfy { $0.blur == 0 })
        _ = engine.render(.init(position: 10, playing: true), delta: 0)
        let following = engine.render(.init(position: 10.5, playing: true), delta: 0.5)
        XCTAssertFalse(following.browsing)
        XCTAssertTrue(following.rows.contains { $0.blur > 0 })
    }

    func testClockDiscontinuityDoesNotPretendToBeASeek() {
        let lines: [LyricLine] = (0 ..< 4).map { (index: Int) -> LyricLine in
            LyricLine(id: String(index), text: "Line \(index)", start: Double(index) * 5, end: Double(index) * 5 + 3)
        }
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60, 60, 60, 60])
        _ = engine.render(.init(position: 1, playing: true), delta: 0)
        engine.handle(.beginBrowsing)
        engine.handle(.browseBy(40))
        engine.handle(.endBrowsing(velocity: 0))
        let discontinuity = engine.render(.init(position: 12, playing: false), delta: 0.18)
        XCTAssertTrue(discontinuity.browsing)
        let seek = engine.render(.init(position: 2, playing: false, seekRevision: 1), delta: 0)
        XCTAssertFalse(seek.browsing)
        XCTAssertEqual(seek.focusGroup, 0)
    }

    func testBrowsingWaitsForActualNextLineAndThenSpringsBack() {
        let lines: [LyricLine] = (0 ..< 4).map { (index: Int) -> LyricLine in
            LyricLine(id: String(index), text: "Line", start: Double(index) * 10, end: Double(index) * 10 + 9)
        }
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60, 60, 60, 60])
        let initial = engine.render(.init(position: 1, playing: true), delta: 0)
        engine.handle(.beginBrowsing)
        engine.handle(.browseBy(40))
        let dragged = engine.render(.init(position: 1, playing: true), delta: 0)
        XCTAssertEqual(dragged.rows[0].y, initial.rows[0].y - 40, accuracy: 0.1)
        engine.handle(.endBrowsing(velocity: 1200))
        XCTAssertTrue(engine.render(.init(position: 8, playing: true), delta: 7).browsing)
        XCTAssertTrue(engine.render(.init(position: 9.8, playing: true), delta: 0.1).browsing)
        let resumed = engine.render(.init(position: 10, playing: true), delta: 0)
        XCTAssertFalse(resumed.browsing)
        let moving = engine.render(.init(position: 10.02, playing: true), delta: 0.02)
        XCTAssertNotEqual(resumed.rows[0].y, moving.rows[0].y)
    }

    func testDifferentRowsRetainIndependentSpringDelays() {
        let lines: [LyricLine] = (0 ..< 5).map { (index: Int) -> LyricLine in
            LyricLine(id: String(index), text: "Line \(index)", start: Double(index) * 2, end: Double(index) * 2 + 2)
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

    func testNonSpringLineMotionUsesAMLLTransitionCurve() {
        var transition = AMLLSourceTransition(0)
        transition.setTarget(100)
        transition.update(0)
        XCTAssertEqual(transition.value, 0, accuracy: 0.000_001)
        transition.update(0.16)
        XCTAssertGreaterThan(transition.value, 80)
        XCTAssertLessThan(transition.value, 100)
        transition.update(0.16)
        XCTAssertEqual(transition.value, 100, accuracy: 0.000_001)
        XCTAssertTrue(transition.arrived)
    }

    func testDisplayDocumentPreservesTimedWhitespace() {
        let line = LyricLine(
            id: "spaces",
            text: "A  B",
            start: 0,
            end: 2,
            words: [
                .init(text: "A", start: 0, end: 0.8),
                .init(text: "  ", start: 0.8, end: 0.8),
                .init(text: "B", start: 0.8, end: 2),
            ],
            precision: .word
        )
        let display = AMLLDisplayDocument(lines: [line])
        XCTAssertEqual(display.lines.first?.text, "A  B")
        XCTAssertEqual(display.lines.first?.words.map(\.text).joined(), "A  B")
    }

    @MainActor
    func testSegmentedProviderWordKeepsAllVisualAtomsInNativeRowData() {
        let line = LyricLine(
            id: "segmented",
            text: "Held note",
            start: 0,
            end: 4,
            words: [.init(text: "Held note", start: 0, end: 4)],
            precision: .word
        )
        let layout = AMLLCoreTextLayout(
            line: line,
            width: 320,
            font: .systemFont(ofSize: 32, weight: .semibold),
            configuration: .init()
        )
        XCTAssertGreaterThanOrEqual(layout.fragments.count, 2)
        XCTAssertTrue(layout.characterFragments.allSatisfy { $0.word.text != "" })
    }

    @MainActor
    func testCoreTextPreservesEmojiCombiningMarksAndBidirectionalText() {
        let text = "مرحبا 👩‍👩‍👦 é 世界"
        let line = LyricLine(id: "unicode", text: text, start: 0, end: 4,
                             words: [.init(text: text, start: 0, end: 4)], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 160, font: .systemFont(ofSize: 32, weight: .semibold), configuration: .init())
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertFalse(layout.fragments.isEmpty)
        let combined = AMLLWordSegmentation.chunks(line.words).flatMap(\.self).map(\.text).joined()
        XCTAssertEqual(combined, text)
        for offset in layout.breakOffsets {
            XCTAssertNotNil(Range(NSRange(location: offset, length: 0), in: text))
        }
        XCTAssertNotNil(layout.raster(scale: 3).cgImage)
    }

    @MainActor
    func testMixedDirectionWordUsesDisjointVisualRunsWithLogicalMaskOrder() {
        let text = "abcمرحبا123"
        let line = LyricLine(id: "mixed", text: text, start: 1, end: 5,
                             words: [.init(text: text, start: 1, end: 5)], precision: .word)
        let font = UIFont.systemFont(ofSize: 32, weight: .semibold)
        let layout = AMLLCoreTextLayout(line: line, width: 400, font: font, configuration: .init())
        XCTAssertTrue(layout.fragments.contains(where: \.rtl))
        XCTAssertTrue(layout.fragments.contains { !$0.rtl })
        XCTAssertEqual(layout.fragments.map(\.range.location), layout.fragments.map(\.range.location).sorted())
        XCTAssertEqual(layout.fragments.reduce(0) { $0 + $1.range.length }, text.utf16.count)
        for (index, fragment) in layout.fragments.enumerated() {
            XCTAssertGreaterThan(fragment.rect.width, 0)
            for other in layout.fragments.dropFirst(index + 1) {
                XCTAssertLessThanOrEqual(fragment.rect.intersection(other.rect).width, 0.001)
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 0]
        let shaped = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let expectedWidth = CTLineGetTypographicBounds(shaped, nil, nil, nil)
        XCTAssertEqual(layout.maskWords.reduce(0) { $0 + $1.width }, expectedWidth, accuracy: 0.01)
    }

    @MainActor
    func testNativeLayoutExposesCharacterClustersAndCachedBlurRaster() {
        let text = "长音 é 👩‍👩‍👦"
        let line = LyricLine(id: "clusters", text: text, start: 0, end: 4,
                             words: [.init(text: text, start: 0, end: 4)], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 360,
                                        font: .systemFont(ofSize: 32, weight: .semibold), configuration: .init())
        XCTAssertGreaterThanOrEqual(layout.characterFragments.count, 4)
        XCTAssertNotNil(layout.raster(scale: 2, blurRadius: 2).cgImage)
        XCTAssertNotNil(layout.raster(scale: 2, auxiliary: true, blurRadius: 5).cgImage)
    }

    @MainActor
    func testWholeLineBlurExtendsOutsideOriginalLeftEdge() throws {
        let line = LyricLine(id: "edge", text: "MMMM", start: 0, end: 4)
        let layout = AMLLCoreTextLayout(line: line, width: 240,
                                        font: .systemFont(ofSize: 32, weight: .bold), configuration: .init())
        let sharp = layout.raster(scale: 1)
        let blurred = layout.raster(scale: 1, blurRadius: 5)
        XCTAssertGreaterThan(blurred.size.width, sharp.size.width)
        XCTAssertGreaterThan(blurred.size.height, sharp.size.height)
        let image = try XCTUnwrap(blurred.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let inset = Int((blurred.size.width - layout.size.width) / 2)
        let hasOutsideInk = (0 ..< height).contains { y in
            (0 ..< inset).contains { x in pixels[(y * width + x) * 4 + 3] > 0 }
        }
        XCTAssertTrue(hasOutsideInk, "Blur must extend into transparent padding left of the text origin")
    }

    @MainActor
    func testTimedRubyReservesInlineAnnotationSpace() {
        let word = LyricWord(text: "漢", start: 0, end: 2,
                             rubySegments: [.init(text: "かん", start: 0, end: 2)])
        let line = LyricLine(id: "ruby", text: "漢", start: 0, end: 2,
                             words: [word], precision: .word)
        let font = UIFont.systemFont(ofSize: 32, weight: .semibold)
        let without = AMLLCoreTextLayout(
            line: LyricLine(id: "plain", text: "漢", start: 0, end: 2,
                            words: [.init(text: "漢", start: 0, end: 2)], precision: .word),
            width: 240, font: font, configuration: .init()
        )
        let withRuby = AMLLCoreTextLayout(line: line, width: 240, font: font, configuration: .init())
        XCTAssertGreaterThan(withRuby.size.height, without.size.height)
        XCTAssertNotNil(withRuby.raster(scale: 2, ruby: true).cgImage)
        XCTAssertTrue(AMLLWordSegmentation.chunks([word]).flatMap(\.self).count == 1)
    }

    @MainActor
    func testRubySegmentsKeepIndependentTimingAndUTF16Ranges() {
        let word = LyricWord(text: "漢字", start: 1, end: 5,
                             rubySegments: [.init(text: "かん", start: 1, end: 2),
                                            .init(text: "じ", start: 3, end: 5)])
        let layout = AMLLCoreTextLayout(
            line: LyricLine(id: "segmented", text: word.text, start: 1, end: 5, words: [word], precision: .word),
            width: 240, font: .systemFont(ofSize: 32), configuration: .init()
        )
        let first = layout.rubyFragments.filter { $0.segmentIndex == 0 }
        let second = layout.rubyFragments.filter { $0.segmentIndex == 1 }
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0.start == 1 && $0.end == 2 && $0.wordIndex == 0 })
        XCTAssertTrue(second.allSatisfy { $0.start == 3 && $0.end == 5 && $0.range.location >= 2 })
        XCTAssertEqual(first.reduce(0) { $0 + $1.range.length }, 2)
        XCTAssertEqual(second.reduce(0) { $0 + $1.range.length }, 1)
    }

    @MainActor
    func testWordRomanizationIsPlacedBelowItsWordAndCanBeDisabled() throws {
        let word = LyricWord(text: "漢", start: 1, end: 4, romanWord: "kan", ruby: "かん")
        let line = LyricLine(id: "roman", text: word.text, start: 1, end: 4, words: [word], precision: .word)
        let font = UIFont.systemFont(ofSize: 32)
        let layout = AMLLCoreTextLayout(line: line, width: 240, font: font, configuration: .init())
        let roman = layout.rubyFragments.filter { $0.kind == .romanization }
        XCTAssertFalse(roman.isEmpty)
        XCTAssertTrue(roman.allSatisfy { $0.start == 1 && $0.end == 4 && $0.wordIndex == 0 })
        XCTAssertEqual(try XCTUnwrap(roman.first).rect.midY, try XCTUnwrap(layout.fragments.first).rect.maxY + font.pointSize * 0.25, accuracy: 0.01)
        XCTAssertTrue(layout.diagnostics.isEmpty)
        var hidden = LyricsRenderConfiguration()
        hidden.romanization = false
        let without = AMLLCoreTextLayout(line: line, width: 240, font: font, configuration: hidden)
        XCTAssertFalse(without.rubyFragments.contains { $0.kind == .romanization })
        XCTAssertTrue(without.rubyFragments.contains { $0.kind == .ruby })
        XCTAssertGreaterThan(layout.size.height, without.size.height)
        XCTAssertEqual(layout.size.height - without.size.height, font.pointSize * 0.5, accuracy: 0.01)
    }

    @MainActor
    func testWideWordRomanizationExpandsContainerWithoutLineFallback() throws {
        let word = LyricWord(text: "字", start: 0, end: 1, romanWord: "a very long pronunciation")
        let line = LyricLine(id: "fallback", text: word.text, start: 0, end: 1, words: [word], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 90, font: .systemFont(ofSize: 32), configuration: .init())
        XCTAssertTrue(layout.rubyFragments.contains { $0.kind == .romanization })
        XCTAssertTrue(layout.diagnostics.isEmpty)
        let main = try XCTUnwrap(layout.fragments.first)
        let roman = try XCTUnwrap(layout.rubyFragments.first)
        XCTAssertGreaterThan(roman.rect.width, main.rect.width)
        XCTAssertEqual(roman.rect.minX, main.rect.minX, accuracy: 0.01)
        XCTAssertEqual(LyricsRenderConfiguration().auxiliaryText(for: line), try [XCTUnwrap(word.romanWord)])
    }

    @MainActor
    func testWideRubyParticipatesInBreaksAndPreservesWordRanges() throws {
        let words = [LyricWord(text: "字", start: 0, end: 1, ruby: "long annotation"),
                     LyricWord(text: "文", start: 1, end: 2, ruby: "long annotation")]
        let line = LyricLine(id: "ruby-width", text: "字文", start: 0, end: 2, words: words, precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 145, font: .systemFont(ofSize: 32), configuration: .init())
        XCTAssertEqual(layout.breakOffsets, [1])
        XCTAssertEqual(layout.fragments.map(\.range.location), [0, 1])
        for ruby in layout.rubyFragments {
            let main = try XCTUnwrap(layout.fragments.first { $0.wordIndex == ruby.wordIndex })
            XCTAssertEqual(ruby.rect.midX, main.rect.midX, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(ruby.rect.minX, -0.01)
        }
    }

    @MainActor
    func testRomanizationContainerPaddingFollowsRTLWord() throws {
        let word = LyricWord(text: "مرحبا", start: 0, end: 1, romanWord: "a long pronunciation")
        let line = LyricLine(id: "rtl-annotation", text: word.text, start: 0, end: 1, words: [word], isRTL: true, precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 240, font: .systemFont(ofSize: 32), configuration: .init())
        let main = try XCTUnwrap(layout.fragments.first)
        let roman = try XCTUnwrap(layout.rubyFragments.first)
        XCTAssertTrue(main.rtl)
        XCTAssertEqual(roman.rect.maxX, main.rect.maxX, accuracy: 0.01)
    }

    @MainActor
    func testWrappedRubyRowsDoNotOccupyPreviousMainRow() {
        let words = (0 ..< 6).map { index in
            LyricWord(text: "漢字 ", start: Double(index), end: Double(index + 1), ruby: "かんじ")
        }
        let layout = AMLLCoreTextLayout(
            line: LyricLine(id: "wrapped", text: words.map(\.text).joined(), start: 0, end: 6, words: words, precision: .word),
            width: 90, font: .systemFont(ofSize: 32), configuration: .init()
        )
        let mainRows = Set(layout.fragments.map(\.rect.minY)).sorted()
        XCTAssertGreaterThan(mainRows.count, 1)
        for annotation in layout.rubyFragments {
            let main = layout.fragments.first { $0.wordIndex == annotation.wordIndex }
            XCTAssertNotNil(main)
            XCTAssertLessThanOrEqual(annotation.rect.maxY, (main?.rect.minY ?? 0) + 0.01)
            for previous in layout.fragments where previous.rect.minY < (main?.rect.minY ?? 0) {
                XCTAssertGreaterThanOrEqual(annotation.rect.minY + 0.01, previous.rect.maxY)
            }
        }
    }

    func testFrameStateCarriesRealPageBackgroundAndControlInput() {
        let line = LyricLine(id: "page", text: "Page", start: 0, end: 4)
        var configuration = LyricsRenderConfiguration()
        configuration.showControls = true
        configuration.backgroundBlur = 40
        let item = PlaybackItem(id: "track", uri: "spotify:track:track", title: "Page", artists: ["Test"],
                                albumTitle: nil, artworkURL: URL(string: "https://example.com/cover.jpg"),
                                duration: 100, isEpisode: false, isAdvertisement: false)
        let snapshot = PlaybackSnapshot(item: item, isPlaying: true, position: 25, duration: 100,
                                        device: nil, restrictions: .unrestricted, source: .webAPI, sampledAtUptime: 0)
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: [line]),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60])
        let state = engine.render(.init(position: 25, playing: true, playbackSnapshot: snapshot,
                                        artworkURL: item.artworkURL, configuration: configuration), delta: 0)
        XCTAssertEqual(state.background.artworkURL, item.artworkURL)
        XCTAssertEqual(state.background.progress, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(state.background.blur, 40, accuracy: 0.000_001)
        XCTAssertTrue(state.controls.visible)
        XCTAssertEqual(state.controls.progress, 0.25, accuracy: 0.000_001)
    }

    func testBackgroundSeedIsStableForTheSameArtwork() {
        let line = LyricLine(id: "seed", text: "Seed", start: 0, end: 4)
        let url = URL(string: "https://example.com/artwork.jpg")
        var engine = AMLLFrameEngine(
            document: AMLLDisplayDocument(lines: [line]),
            environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32),
            heights: [60]
        )
        let first = engine.render(.init(position: 0, playing: false, artworkURL: url), delta: 0)
        let second = engine.render(.init(position: 0, playing: false, artworkURL: url), delta: 0)
        XCTAssertNotEqual(first.background.seed, 0)
        XCTAssertEqual(first.background.seed, second.background.seed)
    }

    func testPausedBackgroundOccupiesFlowAndKeepsItsOwnMaskScale() throws {
        let lines = [
            LyricLine(id: "main", text: "Lead", start: 1, end: 3),
            LyricLine(id: "background", text: "Echo", start: 1, end: 3, isBackground: true),
            LyricLine(id: "next", text: "Next", start: 8, end: 10),
        ]
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.enableSpring = false
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines), environment: environment, heights: [60, 30, 60])
        let playing = engine.render(.init(position: 0, playing: true), delta: 0)
        _ = engine.render(.init(position: 0, playing: false), delta: 0)
        var paused = engine.render(.init(position: 0, playing: false), delta: 0)
        for _ in 0 ..< 30 {
            paused = engine.render(.init(position: 0, playing: false), delta: 1.0 / 60)
        }
        let background = try XCTUnwrap(paused.rows.first { $0.lineIndex == 1 })
        XCTAssertFalse(background.hidden)
        XCTAssertGreaterThan(background.opacity, 0)
        XCTAssertEqual(background.scale, 1, accuracy: 0.000_001)
        XCTAssertEqual(background.darkAlpha, 0.4, accuracy: 0.000_001)
        // CSS :not(.playing) puts inactive background wrappers back into normal flow.
        let before = try XCTUnwrap(playing.rows.first { $0.lineIndex == 2 })
        let after = try XCTUnwrap(paused.rows.first { $0.lineIndex == 2 })
        XCTAssertEqual(after.y - before.y, 30 + 32 * 0.3, accuracy: 0.000_001)
    }

    @MainActor
    func testNativeCanvasExportsActualFramesWithoutAdvancingLiveState() throws {
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        canvas.backgroundColor = .black
        canvas.position = { 6 }
        canvas.configure(document: LyricsRenderFixture.document, configuration: .init(),
                         input: .init(position: 6, playing: true), active: false, reduceMotion: false)
        for _ in 0 ..< 120 {
            canvas.advanceFrame(delta: 1.0 / 60)
        }
        let before = try XCTUnwrap(canvas.frameState)
        let bytes = try XCTUnwrap(canvas.exportMotionTrace(fps: 60))
        struct Trace: Decodable {
            var environment: AMLLRenderEnvironment
            var fps: Int
            var lineIDs: [String]
            var breaks: [[Int]]
            var frames: [AMLLFrameState]
        }
        let trace = try JSONDecoder().decode(Trace.self, from: bytes)
        XCTAssertEqual(trace.frames.count, 300)
        XCTAssertEqual(trace.environment.width, 402)
        XCTAssertEqual(trace.lineIDs.count, trace.breaks.count)
        XCTAssertEqual(trace.frames.first?.rows.count, before.rows.count)
        XCTAssertEqual(canvas.frameState?.animationTime, before.animationTime)
        XCTAssertEqual(canvas.frameState?.rows.map(\.y), before.rows.map(\.y))
        XCTAssertGreaterThan(canvas.visibleRowCount, 0)
        XCTAssertLessThan(canvas.cachedLayoutCount, trace.lineIDs.count)
        XCTAssertTrue(trace.frames.flatMap(\.rows).allSatisfy { $0.y.isFinite && $0.scale.isFinite })
        let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { canvas.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "AMLL-source-port-402pt-unapproved"
        attachment.lifetime = .keepAlways
        add(attachment)
        canvas.removeFromSuperview()
    }

    @MainActor
    func testPausedMaskPixelsRemainFrozenUntilExplicitSeek() throws {
        let line = LyricLine(id: "held", text: "Held note", start: 1, end: 10,
                             words: [.init(text: "Held note", start: 1, end: 10)], precision: .word)
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "mask-clock", title: "Clock fixture", artists: ["Test"]),
                                      lines: [line], language: "en", selectionReason: "Synthetic clock fixture")
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        canvas.backgroundColor = .black
        var position = 3.0
        canvas.position = { position }
        canvas.configure(document: document, configuration: .init(), input: .init(position: position, playing: false), active: false, reduceMotion: false)
        for _ in 0 ..< 180 {
            canvas.advanceFrame(delta: 1.0 / 60)
        }
        func pixels() throws -> Data {
            try XCTUnwrap(UIGraphicsImageRenderer(bounds: canvas.bounds).image { canvas.layer.render(in: $0.cgContext) }.pngData())
        }
        XCTAssertGreaterThan(canvas.visibleRowCount, 0)
        let before = try pixels()
        position = 7
        canvas.advanceFrame(delta: 0)
        XCTAssertEqual(try pixels(), before, "A paused snapshot correction must not move the visible fill")
        canvas.configure(document: document, configuration: .init(), input: .init(position: position, playing: false, seekRevision: 1), active: false, reduceMotion: false)
        XCTAssertNotEqual(try pixels(), before, "Explicit seek must update the actual rendered mask")
    }

    func testMaskClockIgnoresSnapshotCorrectionsAndReanchorsOnlyOnSeek() throws {
        let line = LyricLine(id: "held", text: "Held", start: 1, end: 10,
                             words: [.init(text: "Held", start: 1, end: 10)], precision: .word)
        let document = AMLLDisplayDocument(lines: [line])
        var engine = AMLLFrameEngine(document: document,
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60])
        let initial = engine.render(.init(position: 2, playing: true), delta: 0)
        let startTime = try XCTUnwrap(initial.rows.first).wordClock.time
        let corrected = engine.render(.init(position: 4, playing: true), delta: 0.18)
        XCTAssertEqual(try XCTUnwrap(corrected.rows.first).wordClock.time, startTime + 0.18, accuracy: 0.000_001)
        _ = engine.render(.init(position: 4, playing: false), delta: 0)
        let paused = engine.render(.init(position: 5, playing: false), delta: 3)
        XCTAssertEqual(try XCTUnwrap(paused.rows.first).wordClock.time, startTime + 0.18, accuracy: 0.000_001)
        let seek = engine.render(.init(position: 1.5, playing: false, seekRevision: 1), delta: 0)
        XCTAssertEqual(try XCTUnwrap(seek.rows.first).wordClock.time, 1.5 - document.lines[0].start, accuracy: 0.000_001)
        _ = engine.render(.init(position: 1.5, playing: true, seekRevision: 1), delta: 0)
        let resumed = engine.render(.init(position: 1.5, playing: true, seekRevision: 1), delta: 1.0 / 120)
        XCTAssertEqual(try XCTUnwrap(resumed.rows.first).wordClock.time, 1.5 - document.lines[0].start + 1.0 / 120, accuracy: 0.000_001)
    }

    func testScrollAheadMovesFocusWithoutAdvancingSungLineOrWordClock() throws {
        let lines = [
            LyricLine(id: "first", text: "First", start: 0, end: 3.75,
                      words: [.init(text: "First", start: 0, end: 3.75)], precision: .word),
            LyricLine(id: "second", text: "Second", start: 4, end: 6,
                      words: [.init(text: "Second", start: 4, end: 6)], precision: .word),
        ]
        let document = AMLLDisplayDocument(lines: lines)
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.advance = 1
        environment.hidePassedLines = true
        var engine = AMLLFrameEngine(document: document, environment: environment, heights: [60, 60])
        var unadvancedEnvironment = environment
        unadvancedEnvironment.advance = 0
        var unadvanced = AMLLFrameEngine(document: document, environment: unadvancedEnvironment, heights: [60, 60])

        _ = engine.render(.init(position: 1, playing: true), delta: 0)
        _ = unadvanced.render(.init(position: 1, playing: true), delta: 0)
        let early = engine.render(.init(position: 3.25, playing: true), delta: 0.5)
        let normal = unadvanced.render(.init(position: 3.25, playing: true), delta: 0.5)
        let future = try XCTUnwrap(early.rows.first { $0.lineIndex == 1 })
        let current = try XCTUnwrap(early.rows.first { $0.lineIndex == 0 })
        XCTAssertEqual(normal.focusGroup, 0)
        XCTAssertEqual(early.focusGroup, 1, "The viewport may scroll before the next line starts")
        XCTAssertEqual(early.lyricTime, 3.25, accuracy: 0.000_001)
        XCTAssertTrue(current.active)
        XCTAssertGreaterThan(current.opacity, 0.1, "Scroll-ahead must not hide a still-sung line")
        XCTAssertFalse(future.active, "The next line must not become sung before its source timestamp")
        XCTAssertGreaterThan(future.blur, 0, "The unsung line must retain its inactive appearance")
        XCTAssertFalse(future.wordClock.enabled)
        XCTAssertEqual(future.wordClock.time, 0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(normal.rows.first { $0.lineIndex == 1 }).wordClock.time,
                       future.wordClock.time, accuracy: 0.000_001)

        let start = engine.render(.init(position: 4, playing: true), delta: 0.75)
        let singing = try XCTUnwrap(start.rows.first { $0.lineIndex == 1 })
        XCTAssertTrue(singing.active)
        XCTAssertTrue(singing.wordClock.enabled)
        XCTAssertEqual(document.lines[1].start + singing.wordClock.time, 4, accuracy: 0.000_001)

        let back = engine.render(.init(position: 3.25, playing: true, seekRevision: 1), delta: 0)
        let rewound = try XCTUnwrap(back.rows.first { $0.lineIndex == 1 })
        XCTAssertEqual(back.focusGroup, 1)
        XCTAssertFalse(rewound.active)
        XCTAssertFalse(rewound.wordClock.enabled)
        XCTAssertEqual(rewound.wordClock.time, 0, accuracy: 0.000_001)
    }

    func testWordFloatClockPausesSeeksAndReversesFromEachWordsOwnEnd() {
        var clock = AMLLWordAnimationClock()
        clock.enable(at: 2)
        clock.advance(0.18, playing: true)
        XCTAssertEqual(clock.time, 2.18, accuracy: 0.000_001)
        clock.advance(4, playing: false)
        XCTAssertEqual(clock.time, 2.18, accuracy: 0.000_001)
        clock.disable()
        clock.advance(0.2, playing: false)
        XCTAssertEqual(clock.floatElapsed(wordStart: 0, duration: 1), 0.8, accuracy: 0.000_001)
        XCTAssertEqual(clock.floatElapsed(wordStart: 1, duration: 2), 0.98, accuracy: 0.000_001)
        clock.enable(at: 0.4)
        XCTAssertEqual(clock.time, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(clock.reverseElapsed, 0)
        XCTAssertTrue(clock.enabled)
    }
}
