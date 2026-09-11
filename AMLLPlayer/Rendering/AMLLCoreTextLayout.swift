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

    private struct Row {
        var line: CTLine
        var origin: CGPoint
        var auxiliary = false
    }

    let size: CGSize
    let fragments: [WordFragment]
    let breakOffsets: [Int]
    let font: UIFont
    let maskWords: [AMLLWordMask.Word]
    private let rows: [Row]

    init(line: LyricLine, width: CGFloat, font: UIFont, configuration: LyricsRenderConfiguration) {
        self.font = font
        let availableWidth = max(1, width)
        let chunks: [[LyricWord]]
        if line.precision == .word {
            chunks = AMLLWordSegmentation.chunks(line.words)
        } else {
            // Static lines have no timed word fragments.
            chunks = line.text.map { [.init(text: String($0), start: line.start, end: line.end)] }
        }
        let texts = chunks.map { $0.map(\.text).joined() }
        let timedWords = chunks.flatMap { $0 }
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
        var y: CGFloat = 0
        let mainHeight = max(font.lineHeight, font.pointSize * 1.2)
        for index in 0 ..< rowLimits.count - 1 {
            let range = NSRange(location: rowLimits[index], length: rowLimits[index + 1] - rowLimits[index])
            guard range.length > 0 else { continue }
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            let rowWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let x = line.isDuet || line.isRTL ? availableWidth - rowWidth : 0
            rows.append(.init(line: ctLine, origin: CGPoint(x: x, y: y + font.ascender)))
            if line.precision == .word {
                var cursor = 0
                for (wordIndex, word) in timedWords.enumerated() {
                    let wordRange = NSRange(location: cursor, length: word.text.utf16.count)
                    cursor += wordRange.length
                    let intersection = NSIntersectionRange(range, wordRange)
                    guard intersection.length > 0, !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let first = CTLineGetOffsetForStringIndex(ctLine, intersection.location, nil)
                    let last = CTLineGetOffsetForStringIndex(ctLine, NSMaxRange(intersection), nil)
                    fragments.append(.init(rect: CGRect(x: x + min(first, last), y: y, width: abs(last - first), height: mainHeight),
                                           word: word, range: intersection, rtl: first > last, wordIndex: wordIndex))
                }
            }
            y += mainHeight
        }
        for auxiliary in configuration.auxiliaryText(for: line) {
            let auxiliaryFont = font.withSize(max(10, font.pointSize * 0.5))
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
        self.rows = rows
        self.fragments = fragments
        // A wrapped word has several drawable fragments, but only one timing interval.
        // Pure spaces are DOM text nodes and do not contribute mask travel in AMLL.
        maskWords = timedWords.enumerated().map { index, word in
            .init(start: word.start, end: word.end, width: fragments.filter { $0.wordIndex == index }.reduce(0) { $0 + $1.rect.width })
        }
        size = CGSize(width: availableWidth, height: max(1, y))
    }

    /// nil draws both layers for inspection; the renderer composites auxiliary text separately.
    func raster(scale: CGFloat, auxiliary: Bool? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.textMatrix = .identity
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            for row in rows {
                if let auxiliary, row.auxiliary != auxiliary {
                    continue
                }
                context.textPosition = CGPoint(x: row.origin.x, y: size.height - row.origin.y)
                CTLineDraw(row.line, context)
            }
        }
    }
}
