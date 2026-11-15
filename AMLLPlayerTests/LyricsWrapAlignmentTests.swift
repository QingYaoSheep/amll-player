@testable import AMLLPlayer
import CoreText
import UIKit
import XCTest

@MainActor final class LyricsWrapAlignmentTests: XCTestCase {
    private enum Spacing: String, CaseIterable { case separate, leading, trailing, phrase }

    private func words(_ text: String, spacing: Spacing) -> [LyricWord] {
        let tokens = text.split(separator: " ").map(String.init)
        if spacing == .phrase { return [.init(text: text, start: 0, end: Double(tokens.count))] }
        var result: [LyricWord] = []
        for (index, token) in tokens.enumerated() {
            let start = Double(index), end = start + 0.8
            switch spacing {
            case .separate:
                if index > 0 { result.append(.init(text: " ", start: start, end: start)) }
                result.append(.init(text: token, start: start, end: end))
            case .leading:
                result.append(.init(text: (index > 0 ? " " : "") + token, start: start, end: end))
            case .trailing:
                result.append(.init(text: token + (index < tokens.count - 1 ? " " : ""), start: start, end: end))
            case .phrase: break
            }
        }
        return result
    }

    func testScreenshotSentencesDoNotIndentTheirSoftContinuation() {
        let sentences = ["I wake up, the world is my buffet", "I might call you, might call my ex"]
        var configuration = LyricsRenderConfiguration()
        configuration.translation = false; configuration.romanization = false
        configuration.emphasizeWords = false
        let font = AMLLLyricsFont.make(pointSize: 32, weight: .bold)
        for text in sentences {
            for spacing in Spacing.allCases {
                let line = LyricLine(id: "alignment", text: text, start: 0, end: 10,
                    words: words(text, spacing: spacing), precision: .word)
                let layout = AMLLCoreTextLayout(line: line, width: 338, font: font, configuration: configuration)
                let rows = Dictionary(grouping: layout.characterFragments, by: { $0.rect.minY })
                    .sorted { $0.key < $1.key }
                XCTAssertGreaterThan(rows.count, 1, "The screenshot fixture must actually wrap")
                let starts = rows.map { $0.value.map(\.rect.minX).min() ?? .nan }
                XCTAssertEqual(layout.breakOffsets, text.hasPrefix("I wake") ? [10] : [17],
                    "The original punctuation-reward break must not change")
                print("[WRAP-ALIGNMENT] \(spacing.rawValue) \(text); breaks=\(layout.breakOffsets); starts=\(starts)")
                for start in starts {
                    // Caret geometry deliberately preserves the font's ink bearing.
                    XCTAssertEqual(start, 0, accuracy: 0.01,
                        "Soft-wrapped text must share its layout origin: \(spacing.rawValue), \(text)")
                }
            }
        }
    }

    private func layout(_ text: String, width: CGFloat, size: CGFloat = 32,
                        configure: (inout LyricLine, inout LyricsRenderConfiguration) -> Void = { _, _ in }) -> AMLLCoreTextLayout {
        var line = LyricLine(id: "wrap", text: text, start: 0, end: 30,
                             words: words(text, spacing: .phrase), precision: .word)
        var configuration = LyricsRenderConfiguration()
        configuration.translation = false; configuration.romanization = false
        configuration.emphasizeWords = false
        configure(&line, &configuration)
        return AMLLCoreTextLayout(line: line, width: width,
            font: AMLLLyricsFont.make(pointSize: size, weight: .bold), configuration: configuration)
    }

    private func rows(_ layout: AMLLCoreTextLayout) -> [[AMLLCoreTextLayout.CharacterFragment]] {
        Dictionary(grouping: layout.characterFragments, by: { $0.rect.minY })
            .sorted { $0.key < $1.key }.map(\.value)
    }

    private func firstInkColumn(_ image: UIImage, row: CGRect) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: row.minY * image.scale,
            width: CGFloat(source.width), height: row.height * image.scale).integral))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let column: Int? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            return (0..<crop.width).first { x in
                (0..<crop.height).contains { y in rgba[(y * crop.width + x) * 4 + 3] > 16 }
            }
        }
        return try XCTUnwrap(column, "The glyph reference must contain visible ink")
    }

    func testContinuationInkMatchesTheSameUnwrappedGlyphAtNativeScales() throws {
        for (text, continuation) in [("I wake up, the world is my buffet", "the world is my buffet"),
                                     ("I might call you, might call my ex", "might call my ex")] {
            let wrapped = layout(text, width: 338)
            let control = layout(continuation, width: 1000)
            let second = try XCTUnwrap(rows(wrapped).dropFirst().first?.first?.rect)
            let first = try XCTUnwrap(rows(control).first?.first?.rect)
            for scale in [CGFloat(2), 3] {
                let actual = try firstInkColumn(wrapped.raster(scale: scale, auxiliary: false, ruby: false), row: second)
                let expected = try firstInkColumn(control.raster(scale: scale, auxiliary: false, ruby: false), row: first)
                XCTAssertLessThanOrEqual(abs(actual - expected), 1, "Compare identical glyph bearings, not ink against zero")
            }
        }
    }

    func testWidthsFontsAndUnicodePreserveSourceIdentityAndTime() {
        let text = "I wake up,   the world is my buffet e\u{301} 👩🏽‍🚀 中文"
        let reference = layout(text, width: 4000)
        for size in [CGFloat(24), 32, 40] {
            for width in [CGFloat(200), 338, 500] {
                for style in [LyricsAnimationStyle.amll, .appleMusic164] {
                    let wrapped = layout(text, width: width, size: size) { _, configuration in
                        configuration.selectAnimationStyle(style)
                    }
                    for row in rows(wrapped) {
                        XCTAssertEqual(row.map(\.rect.minX).min() ?? .nan, 0, accuracy: 0.01)
                    }
                    XCTAssertEqual(wrapped.characterFragments.map(\.range), reference.characterFragments.map(\.range))
                    XCTAssertEqual(wrapped.characterFragments.map(\.word), reference.characterFragments.map(\.word))
                    XCTAssertEqual(wrapped.characterFragments.map(\.characterIndex), reference.characterFragments.map(\.characterIndex))
                }
            }
        }
    }

    func testAuthoredIndentationHardLinesAndNonbreakingSpacesSurvive() throws {
        let paragraphs = ["  Alpha,", "  Beta,", "\tGamma,", "\u{00a0}Delta", "\u{3000}Omega"]
        let combined = layout(paragraphs[0] + "\n" + paragraphs[1] + "\r\n" + paragraphs[2] + "\u{2028}" + paragraphs[3] + "\u{2029}" + paragraphs[4], width: 1200)
        let actualRows = rows(combined)
        XCTAssertEqual(actualRows.count, paragraphs.count)
        for (index, paragraph) in paragraphs.enumerated() {
            let expected = try XCTUnwrap(rows(layout(paragraph, width: 1200)).first?.map(\.rect.minX).min())
            XCTAssertGreaterThan(expected, 0, "Authored indentation must remain")
            if actualRows.indices.contains(index) {
                XCTAssertEqual(actualRows[index].map(\.rect.minX).min() ?? .nan, expected, accuracy: 0.01)
            }
        }
        let blank = rows(layout("Alpha\n\nBeta", width: 1200))
        XCTAssertEqual(blank.count, 2)
        if blank.count == 2 {
            let first = try XCTUnwrap(blank[0].first?.rect)
            XCTAssertEqual(try XCTUnwrap(blank[1].first?.rect.minY) - first.minY, 2 * first.height, accuracy: 0.01)
        }
        let nbsp = rows(layout("A,\u{00a0}B", width: 50))
        XCTAssertEqual(nbsp.count, 2)
        if nbsp.count == 2 {
            let expected = try XCTUnwrap(rows(layout("\u{00a0}B", width: 500)).first?.map(\.rect.minX).min())
            XCTAssertGreaterThan(expected, 0)
            XCTAssertEqual(nbsp[1].map(\.rect.minX).min() ?? .nan, expected, accuracy: 0.01)
        }
    }

    func testDuetAndRTLKeepTheirRightAlignment() {
        for (text, rtl) in [("I wake up, the world is my buffet", false),
                            ("مرحبا بكم، في عالم الموسيقى الجميل", true)] {
            let wrapped = layout(text, width: 220) { line, _ in
                line.isRTL = rtl; line.isDuet = !rtl
            }
            XCTAssertGreaterThan(rows(wrapped).count, 1)
            for row in rows(wrapped) {
                XCTAssertEqual(row.map(\.rect.maxX).max() ?? .nan, 220, accuracy: 0.01)
                XCTAssertGreaterThanOrEqual(row.map(\.rect.minX).min() ?? -.infinity, -0.01)
            }
        }
    }

    func testOnlySoftBoundarySpacesAndTabsCollapse() {
        for separator in [" ", "   ", "\t", " \t "] {
            let wrapped = layout("I wake up," + separator + "the world is my buffet", width: 338)
            XCTAssertGreaterThan(rows(wrapped).count, 1)
            for row in rows(wrapped) {
                XCTAssertEqual(row.map(\.rect.minX).min() ?? .nan, 0, accuracy: 0.01)
            }
        }
    }

    func testProductionCanvasKeepsContinuationInkAlignedAcrossModesAndAuxiliaryChanges() async throws {
        let text = "I might call you, I might call you"
        let line = LyricLine(id: "wrap", text: text, start: 0, end: 30,
            words: words(text, spacing: .separate), translation: "Translation", romanization: "Pronunciation", precision: .word)
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "wrap", title: "Wrap", artists: []),
            lines: [line], language: "en", selectionReason: "Alignment regression")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let canvas = AMLLNativeCanvas(frame: window.bounds)
        canvas.traitOverrides.preferredContentSizeCategory = .large
        window.addSubview(canvas)
        defer { canvas.stop(); canvas.removeFromSuperview() }
        var position = 1.0
        var seekRevision = 0
        canvas.position = { position }
        func lyric(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "lyricRow.wrap" { return view }
            return view.subviews.lazy.compactMap { lyric(in: $0) }.first
        }
        for immersive in [false, true] {
            canvas.frame.size.height = immersive ? 360 : 874
            var configuration = LyricsRenderConfiguration()
            configuration.immersiveLyrics = immersive
            configuration.anchor = immersive ? 0.18 : 0.28
            configuration.translation = false; configuration.romanization = false
            configuration.emphasizeWords = false; configuration.enableScale = false
            configuration.blurInactive = false; configuration.hdr = .init(enabled: false)
            for auxiliary in [false, true, false] {
                configuration.translation = auxiliary; configuration.romanization = auxiliary
                canvas.configure(document: document, configuration: configuration,
                    input: .init(position: position, playing: false, seekRevision: seekRevision), active: false, reduceMotion: false)
                canvas.advanceFrame(delta: 0)
                for _ in 0..<50 where lyric(in: canvas) == nil {
                    try await Task.sleep(for: .milliseconds(20)); canvas.advanceFrame(delta: 1 / 120)
                }
                let body = try XCTUnwrap(lyric(in: canvas))
                let font = AMLLLyricsFont.make(pointSize: 32, weight: .bold)
                let rowHeight = max(font.lineHeight, font.pointSize * 1.2)
                let format = UIGraphicsImageRendererFormat(); format.scale = 3
                let image = UIGraphicsImageRenderer(size: body.bounds.size, format: format).image {
                    body.layer.render(in: $0.cgContext)
                }
                let first = try firstInkColumn(image, row: CGRect(x: 0, y: 0, width: body.bounds.width, height: rowHeight))
                let second = try firstInkColumn(image, row: CGRect(x: 0, y: rowHeight, width: body.bounds.width, height: rowHeight))
                XCTAssertLessThanOrEqual(abs(first - second), 1, "Both visual rows start with the same I glyph")
                XCTAssertEqual(canvas.frameState?.lyricTime ?? -1, position, accuracy: 0.001)
                canvas.handleInteraction(.beginBrowsing); canvas.handleInteraction(.browseBy(20))
                canvas.advanceFrame(delta: 1 / 120)
                canvas.handleInteraction(.resumeFollowing)
                position = position == 1 ? 2 : 1
                seekRevision += 1
                canvas.configure(document: document, configuration: configuration,
                    input: .init(position: position, playing: false, seekRevision: seekRevision, seekPosition: position),
                    active: false, reduceMotion: false)
                canvas.advanceFrame(delta: 1 / 120)
                XCTAssertEqual(canvas.frameState?.lyricTime ?? -1, position, accuracy: 0.001)
            }
        }
    }

    func testRubyContainersTrimSoftSpacesWithoutLosingTheirCenteringOrTiming() throws {
        let wrapped = layout("A, B", width: 90, size: 22) { line, _ in
            line.words = [.init(text: "A,", start: 1, end: 2, ruby: "annotation"),
                          .init(text: " B", start: 3, end: 4, ruby: "annotation")]
        }
        XCTAssertEqual(rows(wrapped).count, 2)
        for index in 0..<2 {
            let body = try XCTUnwrap(wrapped.fragments.first { $0.wordIndex == index })
            let ruby = try XCTUnwrap(wrapped.rubyFragments.first { $0.wordIndex == index })
            XCTAssertEqual(body.rect.midX, ruby.rect.midX, accuracy: 0.01)
            XCTAssertEqual(ruby.rect.minX, 0, accuracy: 0.01)
            XCTAssertEqual(body.word.start, index == 0 ? 1 : 3)
        }
        XCTAssertEqual(wrapped.characterFragments.last?.range, NSRange(location: 3, length: 1))
        XCTAssertEqual(wrapped.characterFragments.last?.characterIndex, 1)
    }

    func testTextKitCompatibilityPageHasNoContinuationSpaceIndent() throws {
        for text in ["I wake up, the world is my buffet", "I might call you, might call my ex"] {
            var configuration = LyricsRenderConfiguration()
            configuration.fontSize = 32; configuration.translation = false; configuration.romanization = false
            let line = LyricLine(id: "compatibility", text: text, start: 0, end: 10,
                                 words: words(text, spacing: .separate), precision: .word)
            let shaped = LyricTextLayout(line: line, width: 338, configuration: configuration,
                                        traits: UITraitCollection(preferredContentSizeCategory: .large))
            let rowStarts = Dictionary(grouping: shaped.fragments.filter {
                !$0.wordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, by: { $0.rect.minY }).values.map { $0.map(\.rect.minX).min() ?? .nan }
            XCTAssertGreaterThan(rowStarts.count, 1)
            for start in rowStarts { XCTAssertEqual(start, 0, accuracy: 0.5) }
        }
    }
}
