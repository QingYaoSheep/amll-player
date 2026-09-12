import CoreImage
import CoreText
import NaturalLanguage
import UIKit

/// Core Text shapes glyphs; the pinned AMLL cost function chooses the line breaks.
@MainActor
final class AMLLCoreTextLayout {
    struct WordFragment {
        var rect: CGRect
        var word: LyricWord
        var range: NSRange
        var rtl: Bool
        var wordIndex: Int
    }

    struct CharacterFragment {
        var rect: CGRect
        var range: NSRange
        var rtl: Bool
        var wordIndex: Int
        var characterIndex: Int
        /// The shaped/timed atom, rather than an index into the provider's
        /// original `line.words`. Word segmentation can split one provider
        /// word into multiple visual atoms, so keeping the value here avoids
        /// losing its timing and AMLL metadata (or indexing past the source
        /// array) in the CALayer renderer.
        var word: LyricWord
    }

    private struct Row {
        var line: CTLine
        var origin: CGPoint
        var auxiliary = false
        var ruby = false
    }

    private struct VisualRun {
        var range: NSRange
        var left: CGFloat
        var right: CGFloat
        var rtl: Bool

        func offset(at index: Int, in line: CTLine) -> CGFloat {
            // At a bidi boundary Core Text offers two caret offsets. The run's
            // logical start/end identifies which visual edge owns this fragment.
            if index == range.location {
                return rtl ? right : left
            }
            if index == NSMaxRange(range) {
                return rtl ? left : right
            }
            var secondary: CGFloat = 0
            let primary = CTLineGetOffsetForStringIndex(line, index, &secondary)
            let value = primary >= left && primary <= right ? primary : secondary
            return min(right, max(left, value))
        }
    }

    private static func visualRuns(in line: CTLine) -> [VisualRun] {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        return runs.compactMap { run -> VisualRun? in
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { return nil }
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            let left = positions.map(\.x).min() ?? 0
            let right = zip(positions, advances).map { $0.x + $1.width }.max() ?? left
            let range = CTRunGetStringRange(run)
            return VisualRun(range: NSRange(location: range.location, length: range.length), left: left, right: right,
                             rtl: CTRunGetStatus(run).contains(.rightToLeft))
        }.sorted { $0.range.location < $1.range.location }
    }

    /// `LineBalancer` receives Intl.Segmenter word nodes for non-dynamic
    /// lines. NLTokenizer supplies the same word boundaries on Apple
    /// platforms; the gaps are emitted as independent whitespace children so
    /// balanced breaks never delete or collapse the original text.
    private static func staticSegments(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        var cursor = 0
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let token = NSRange(range, in: text)
            if token.location > cursor {
                result.append(nsText.substring(with: NSRange(location: cursor, length: token.location - cursor)))
            }
            result.append(nsText.substring(with: token))
            cursor = token.location + token.length
            return true
        }
        if cursor < nsText.length {
            result.append(nsText.substring(from: cursor))
        }
        return result.isEmpty ? [text] : result
    }

    let size: CGSize
    let fragments: [WordFragment]
    let characterFragments: [CharacterFragment]
    let breakOffsets: [Int]
    let font: UIFont
    let maskWords: [AMLLWordMask.Word]
    private let rows: [Row]

    init(line: LyricLine, width: CGFloat, font: UIFont, configuration: LyricsRenderConfiguration) {
        self.font = font
        let availableWidth = max(1, width)
        let chunks: [[LyricWord]] = if line.precision == .word {
            AMLLWordSegmentation.chunks(line.words)
        } else {
            // Static lines have no timed word fragments, but their line-break
            // children still follow source word segmentation rather than one
            // Swift grapheme per child.
            Self.staticSegments(line.text).map { [.init(text: $0, start: line.start, end: line.end)] }
        }
        let texts = chunks.map { $0.map(\.text).joined() }
        let timedWords = chunks.flatMap(\.self)
        let text = texts.joined()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .kern: configuration.tracking]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let children = texts.map { text in
            AMLLBalancedLayout.Child(text: text,
                                     width: CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), nil, nil, nil),
                                     isSpace: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var boundaries: Set<Int> = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            if text[range].contains(where: { AMLLWordSegmentation.isCJK(String($0)) }) {
                boundaries.insert(NSRange(range, in: text).location)
            }
            return true
        }
        let breaks = AMLLBalancedLayout.breaks(children: children, width: availableWidth, cjkBoundaries: boundaries)
        var offsets = [0]
        for text in texts {
            offsets.append(offsets[offsets.count - 1] + text.utf16.count)
        }
        breakOffsets = breaks.map { offsets[$0] }
        let rowLimits = [0] + breakOffsets + [attributed.length]
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var rows: [Row] = []
        var fragments: [WordFragment] = []
        var characterFragments: [CharacterFragment] = []
        // lyricBgLine's nested main line carries 1.2em vertical padding in
        // the source CSS; the ordinary wrapper padding is supplied by the
        // frame engine, so only the background-specific inset belongs here.
        let backgroundPadding = line.isBackground ? font.pointSize * 1.2 : 0
        var y: CGFloat = backgroundPadding
        let mainHeight = max(font.lineHeight, font.pointSize * 1.2)
        let rubyFont = font.withSize(max(10, font.pointSize * 0.5))
        let rubyHeight = timedWords.contains { !$0.rubySegments.isEmpty || !($0.ruby?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            ? rubyFont.pointSize * 1.5
            : 0
        for index in 0 ..< rowLimits.count - 1 {
            let range = NSRange(location: rowLimits[index], length: rowLimits[index + 1] - rowLimits[index])
            guard range.length > 0 else { continue }
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            let rowWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let x = line.isDuet || line.isRTL ? availableWidth - rowWidth : 0
            rows.append(.init(line: ctLine, origin: CGPoint(x: x, y: y + rubyHeight + font.ascender)))
            if line.precision == .word {
                let runs = Self.visualRuns(in: ctLine)
                var cursor = 0
                for (wordIndex, word) in timedWords.enumerated() {
                    let wordRange = NSRange(location: cursor, length: word.text.utf16.count)
                    cursor += wordRange.length
                    let intersection = NSIntersectionRange(range, wordRange)
                    guard intersection.length > 0, !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    for run in runs {
                        let fragment = NSIntersectionRange(intersection, run.range)
                        guard fragment.length > 0 else { continue }
                        let first = run.offset(at: fragment.location, in: ctLine)
                        let last = run.offset(at: NSMaxRange(fragment), in: ctLine)
                        fragments.append(.init(rect: CGRect(x: x + min(first, last), y: y + rubyHeight, width: abs(last - first), height: mainHeight),
                                               word: word, range: fragment, rtl: run.rtl, wordIndex: wordIndex))
                    }

                    // Core Text exposes glyph runs while AMLL addresses
                    // characters. Build grapheme-sized visual pieces from the
                    // original Swift string so emoji, combining marks and
                    // surrogate pairs remain one animation unit.
                    var localOffset = 0
                    for (characterIndex, character) in word.text.enumerated() {
                        let characterText = String(character)
                        let characterRange = NSRange(location: cursor - word.text.utf16.count + localOffset,
                                                     length: characterText.utf16.count)
                        localOffset += characterRange.length
                        let characterIntersection = NSIntersectionRange(range, characterRange)
                        guard characterIntersection.length > 0,
                              !characterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        for run in runs {
                            let visual = NSIntersectionRange(characterIntersection, run.range)
                            guard visual.length > 0 else { continue }
                            let first = run.offset(at: visual.location, in: ctLine)
                            let last = run.offset(at: NSMaxRange(visual), in: ctLine)
                            characterFragments.append(.init(
                                rect: CGRect(x: x + min(first, last), y: y + rubyHeight, width: abs(last - first), height: mainHeight),
                                range: visual,
                                rtl: run.rtl,
                                wordIndex: wordIndex,
                                characterIndex: characterIndex,
                                word: word
                            ))
                        }
                    }
                }
            }
            y += mainHeight
        }
        // Ruby is part of the main glyph layer in AMLL. Reserve one compact
        // line above the shaped main rows and center each annotation over the
        // visual run(s) belonging to its timed word. It remains in the sharp
        // raster so the main word mask and ruby keep one layout origin.
        if rubyHeight > 0 {
            for (wordIndex, word) in timedWords.enumerated() {
                let rubyText = word.rubySegments.map(\.text).joined()
                    .isEmpty ? (word.ruby ?? "") : word.rubySegments.map(\.text).joined()
                guard !rubyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let wordFragments = fragments.filter { $0.wordIndex == wordIndex }
                guard let first = wordFragments.first else { continue }
                let minX = wordFragments.map(\.rect.minX).min() ?? first.rect.minX
                let maxX = wordFragments.map(\.rect.maxX).max() ?? first.rect.maxX
                let value = NSAttributedString(string: rubyText, attributes: [
                    .font: rubyFont,
                    .foregroundColor: UIColor.white.withAlphaComponent(0.3),
                    .kern: configuration.tracking,
                ])
                let rubyLine = CTLineCreateWithAttributedString(value)
                let rubyWidth = CTLineGetTypographicBounds(rubyLine, nil, nil, nil)
                let x = minX + max(0, (maxX - minX - rubyWidth) / 2)
                let rubyTop = first.rect.minY - rubyHeight
                rows.append(.init(line: rubyLine, origin: CGPoint(x: x, y: rubyTop + rubyFont.ascender), ruby: true))
            }
            y += rubyHeight
        }
        // lyricLineWrapper uses a .3em flex gap between the main and
        // auxiliary rows. Keeping it in the cached layout also keeps the
        // engine's measured group height aligned with the pixels.
        if !configuration.auxiliaryText(for: line).isEmpty {
            y += font.pointSize * 0.3
        }
        for auxiliary in configuration.auxiliaryText(for: line) {
            let auxiliaryFont = font.withSize(max(10, font.pointSize * (configuration.auxiliaryScale ?? 0.5)))
            let value = NSAttributedString(string: auxiliary, attributes: [.font: auxiliaryFont, .foregroundColor: UIColor.white.withAlphaComponent(0.3)])
            let typesetter = CTTypesetterCreateWithAttributedString(value)
            var cursor = 0
            while cursor < value.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, cursor, availableWidth))
                let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: cursor, length: count))
                let rowWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                rows.append(.init(line: ctLine, origin: CGPoint(x: line.isDuet || line.isRTL ? availableWidth - rowWidth : 0,
                                                                y: y + auxiliaryFont.ascender), auxiliary: true))
                y += auxiliaryFont.pointSize * 1.5
                cursor += count
            }
        }
        if line.isBackground {
            y += backgroundPadding
        }
        self.rows = rows
        self.fragments = fragments
        self.characterFragments = characterFragments
        // A wrapped word has several drawable fragments, but only one timing interval.
        // Pure spaces are DOM text nodes and do not contribute mask travel in AMLL.
        maskWords = timedWords.enumerated().map { index, word in
            .init(start: word.start, end: word.end, width: fragments.filter { $0.wordIndex == index }.reduce(0) { $0 + $1.rect.width })
        }
        size = CGSize(width: availableWidth, height: max(1, y + (configuration.paragraphSpacing ?? 0)))
    }

    /// nil draws both layers for inspection; the renderer composites auxiliary text separately.
    private static let rasterContext = CIContext(options: nil)

    func raster(scale: CGFloat, auxiliary: Bool? = nil, ruby: Bool? = nil, blurRadius: CGFloat = 0) -> UIImage {
        // Three Gaussian standard deviations plus a pixel of rounding room.
        // Transparent padding must exist before filtering, not just on CALayer.
        let padding = blurRadius > 0 ? ceil(blurRadius * 3 + 1) : 0
        let rasterSize = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let sharp = UIGraphicsImageRenderer(size: rasterSize, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: padding, y: padding)
            context.textMatrix = .identity
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            for row in rows {
                if let auxiliary, row.auxiliary != auxiliary {
                    continue
                }
                if let ruby, row.ruby != ruby {
                    continue
                }
                context.textPosition = CGPoint(x: row.origin.x, y: size.height - row.origin.y)
                CTLineDraw(row.line, context)
            }
        }
        guard blurRadius > 0, let input = CIImage(image: sharp) else { return sharp }
        let extent = input.extent
        let filtered = input.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius * scale])
        guard let output = Self.rasterContext.createCGImage(filtered, from: extent) else { return sharp }
        return UIImage(cgImage: output, scale: scale, orientation: .up)
    }
}
