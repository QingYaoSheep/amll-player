import CoreImage
import CoreText
import NaturalLanguage
import UIKit

fileprivate struct AMLLCoreTextRasterRow {
    var line: CTLine
    var origin: CGPoint
    var auxiliary = false
    var ruby = false
    var romanization = false
    var auxiliaryKind: LyricsAuxiliaryKind? = nil
    var auxiliaryRect: CGRect? = nil
}

/// Immutable Core Text data crosses the main-actor boundary only for image
/// preparation. UIKit views and Core Text layout construction remain on main.
struct AMLLCoreTextRasterSnapshot: @unchecked Sendable {
    fileprivate let size: CGSize
    fileprivate let rows: [AMLLCoreTextRasterRow]
    fileprivate var softwareBlur = false
    nonisolated(unsafe) private static let rasterContext = CIContext(options: nil)
    nonisolated(unsafe) private static let softwareRasterContext = CIContext(options: [.useSoftwareRenderer: true])

    func blurRasterScale(for scale: CGFloat) -> CGFloat { min(scale, softwareBlur ? 2 : 1) }

    func usingSoftwareBlur(_ enabled: Bool) -> Self {
        var copy = self
        copy.softwareBlur = enabled
        return copy
    }

    func hidingAuxiliary(_ kinds: Set<LyricsAuxiliaryKind>) -> Self {
        .init(size: size, rows: rows.filter { row in
            if let kind = row.auxiliaryKind, kinds.contains(kind) { return false }
            return !(row.romanization && kinds.contains(.romanization))
        }, softwareBlur: softwareBlur)
    }

    var auxiliaryKinds: Set<LyricsAuxiliaryKind> {
        Set(rows.compactMap { $0.auxiliaryKind ?? ($0.romanization ? .romanization : nil) })
    }

    func onlyAuxiliary(_ kind: LyricsAuxiliaryKind?) -> Self {
        .init(size: size, rows: rows.filter { ($0.auxiliaryKind ?? ($0.romanization ? .romanization : nil)) == kind })
    }

    func raster(scale: CGFloat, auxiliary: Bool? = nil, ruby: Bool? = nil,
                romanization: Bool? = nil, blurRadius: CGFloat = 0) -> UIImage {
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
                if let auxiliary, row.auxiliary != auxiliary { continue }
                if let ruby, row.ruby != ruby { continue }
                if let romanization, row.romanization != romanization { continue }
                context.textPosition = CGPoint(x: row.origin.x, y: size.height - row.origin.y)
                CTLineDraw(row.line, context)
            }
        }
        guard blurRadius > 0, let input = CIImage(image: sharp) else { return sharp }
        let extent = input.extent
        let filtered = input.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius * scale])
        let context = softwareBlur ? Self.softwareRasterContext : Self.rasterContext
        guard let output = context.createCGImage(filtered, from: extent) else { return sharp }
        return UIImage(cgImage: output, scale: scale, orientation: .up)
    }
}

/// Core Text shapes glyphs; the pinned AMLL cost function chooses the line breaks.
@MainActor
final class AMLLCoreTextLayout {
    lazy var horizontalInkBounds: CGRect = rows.reduce(.null) { union, row in
        let ink = CTLineGetBoundsWithOptions(row.line, .useGlyphPathBounds)
        guard !ink.isEmpty else { return union }
        return union.union(CGRect(x: row.origin.x + ink.minX, y: 0, width: ink.width, height: 1))
    }

    var mainOrigin: CGPoint { rows.first(where: { !$0.auxiliary && !$0.ruby && !$0.romanization })?.origin ?? .zero }
    var auxiliaryRegions: [LyricsAuxiliaryKind: [CGRect]] {
        var result: [LyricsAuxiliaryKind: [CGRect]] = [:]
        for row in rows {
            if let kind = row.auxiliaryKind, let rect = row.auxiliaryRect { result[kind, default: []].append(rect) }
        }
        result[.romanization, default: []] += rubyFragments.filter { $0.kind == .romanization }.map(\.rect)
        return result
    }
    struct RubyFragment {
        enum Kind: String { case ruby, romanization }
        var rect: CGRect
        var range: NSRange
        var wordIndex: Int
        var segmentIndex: Int
        var start: Double?
        var end: Double?
        var rtl: Bool
        var kind: Kind = .ruby
        var motionStart: Double? = nil
        var motionEnd: Double? = nil
        /// Timed span ordinal in the separate generated TTML cue.
        var ttmlWordIndex: Int? = nil
    }

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

    private typealias Row = AMLLCoreTextRasterRow

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
    /// lines. NLTokenizer supplies native word boundaries on Apple
    /// platforms; locale-specific equivalence still needs reference fixtures.
    /// Gaps are emitted as independent children so
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
    let rubyFragments: [RubyFragment]
    let diagnostics: [String]
    let breakOffsets: [Int]
    let font: UIFont
    let auxiliaryPointSize: CGFloat
    let maskWords: [AMLLWordMask.Word]
    /// Empty slot for the separately parsed romanization TTML row.
    let romanizationSlotY: CGFloat?
    let hasGeneratedRomanizationLayout: Bool
    /// Indexed by WordFragment/CharacterFragment/RubyFragment.wordIndex.
    /// Original annotation data stays on the source word; no inferred ruby
    /// character correspondence is introduced by segmentation.
    let sourceAtoms: [AMLLWordSegmentation.Atom]
    private(set) var pronunciationEmphasisChunks: [[LyricWord]]?
    private let rows: [Row]
    private struct RomanizationShape {
        var row: Row
        var text: String
        var rect: CGRect
        var segments: [RubyFragment]
    }
    private var romanizationShapes: [RomanizationShape] = []

    /// Use the already shaped annotation glyphs as a timed row. Source indices
    /// here address the pronunciation text, not the body or its ruby ranges.
    func timedRomanization(for body: LyricLine, cue: LyricLine?) -> (LyricLine, AMLLCoreTextLayout)? {
        guard !romanizationShapes.isEmpty, cue == nil || cue?.precision == .word else { return nil }
        var words: [LyricWord] = []
        var pieces: [WordFragment] = []
        var characters: [CharacterFragment] = []
        var rasterRows: [Row] = []
        var atoms: [AMLLWordSegmentation.Atom] = []
        var mask: [AMLLWordMask.Word] = []
        var offset = 0
        var matchedCueWords = Set<Int>()
        for shape in romanizationShapes {
            let ns = shape.text as NSString
            var raster = shape.row
            raster.ruby = false
            raster.romanization = false
            var hasTiming = false
            let segments = Dictionary(grouping: shape.segments, by: \.segmentIndex)
            for index in segments.keys.sorted() {
                guard let first = segments[index]?.first, let parts = segments[index] else { continue }
                let lower = parts.map(\.range.location).min() ?? 0
                let upper = parts.map { NSMaxRange($0.range) }.max() ?? lower
                let range = NSRange(location: lower, length: upper - lower)
                let text = ns.substring(with: range)
                let word: LyricWord
                if let cue {
                    guard let ordinal = first.ttmlWordIndex, cue.words.indices.contains(ordinal),
                          cue.words[ordinal].text.trimmingCharacters(in: .whitespacesAndNewlines)
                            == text.trimmingCharacters(in: .whitespacesAndNewlines),
                          matchedCueWords.insert(ordinal).inserted else { return nil }
                    word = .init(text: text, start: cue.words[ordinal].start, end: cue.words[ordinal].end)
                } else if let start = first.start, let end = first.end {
                    word = .init(text: text, start: start, end: end)
                } else { continue }
                guard word.start.isFinite, word.end.isFinite, word.end > word.start else {
                    if cue != nil { return nil }
                    continue
                }
                if !words.isEmpty {
                    let space = LyricWord(text: " ", start: word.start, end: word.start)
                    atoms.append(.init(word: space, sourceWordIndex: words.count, sourceRange: NSRange(location: 0, length: 1)))
                    words.append(space)
                    mask.append(.init(start: space.start, end: space.end, width: 0))
                    offset += 1
                }
                let wordIndex = words.count
                words.append(word)
                atoms.append(.init(word: word, sourceWordIndex: wordIndex,
                                   sourceRange: NSRange(location: 0, length: range.length)))
                mask.append(.init(start: word.start, end: word.end, width: parts.reduce(0) { $0 + $1.rect.width }))
                let runs = Self.visualRuns(in: raster.line)
                for part in parts where part.rect.width > 0 {
                    pieces.append(.init(rect: part.rect, word: word,
                                        range: NSRange(location: offset + part.range.location - lower, length: part.range.length),
                                        rtl: part.rtl, wordIndex: wordIndex))
                }
                var cursor = lower
                for (characterIndex, character) in text.enumerated() {
                    let value = String(character)
                    let characterRange = NSRange(location: cursor, length: value.utf16.count)
                    cursor += characterRange.length
                    for part in parts {
                        let overlap = NSIntersectionRange(characterRange, part.range)
                        guard overlap.length > 0,
                              let run = runs.first(where: { NSIntersectionRange($0.range, overlap) == overlap }) else { continue }
                        let start = run.offset(at: overlap.location, in: raster.line)
                        let end = run.offset(at: NSMaxRange(overlap), in: raster.line)
                        guard abs(end - start) > 0 else { continue }
                        characters.append(.init(
                            rect: CGRect(x: raster.origin.x + min(start, end), y: part.rect.minY,
                                         width: abs(end - start), height: part.rect.height),
                            range: NSRange(location: offset + overlap.location - lower, length: overlap.length),
                            rtl: part.rtl, wordIndex: wordIndex, characterIndex: characterIndex, word: word))
                    }
                }
                offset += range.length
                hasTiming = true
            }
            if !hasTiming {
                raster.auxiliary = true
                raster.auxiliaryKind = .romanization
                raster.auxiliaryRect = shape.rect
            }
            rasterRows.append(raster)
        }
        guard !pieces.isEmpty, let start = pieces.map(\.word.start).min(), let end = pieces.map(\.word.end).max() else { return nil }
        if let cue, cue.words.indices.contains(where: {
            let word = cue.words[$0]
            return word.end > word.start && !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !matchedCueWords.contains($0)
        }) { return nil }
        var line = cue ?? .init(id: body.id + ".romanization", text: "", start: start, end: end)
        line.text = words.map(\.text).joined()
        line.words = words
        line.start = start; line.end = end
        line.precision = .word
        line.isBackground = body.isBackground
        let layout = AMLLCoreTextLayout(size: size, font: font.withSize(auxiliaryPointSize), rows: rasterRows,
                                       fragments: pieces, characters: characters, atoms: atoms, mask: mask)
        return (line, layout)
    }

    private init(size: CGSize, font: UIFont, rows: [Row], fragments: [WordFragment],
                 characters: [CharacterFragment], atoms: [AMLLWordSegmentation.Atom], mask: [AMLLWordMask.Word]) {
        self.size = size; self.font = font; self.rows = rows; self.fragments = fragments
        characterFragments = characters; sourceAtoms = atoms; maskWords = mask
        auxiliaryPointSize = font.pointSize; rubyFragments = []; diagnostics = []; breakOffsets = []
        romanizationSlotY = nil; hasGeneratedRomanizationLayout = false
        pronunciationEmphasisChunks = atoms.map { [$0.word] }
    }

    private struct VisualLine {
        var drawingRange: NSRange
        var preservesEmptyLine: Bool
    }

    /// Balanced offsets still partition the original text. Only drawing drops
    /// collapsible whitespace carried over a soft break, like a DOM text node
    /// after <br>. Hard-line indentation and nonbreaking spaces remain authored.
    private static func visualLines(in text: String, breaks: [Int]) -> [VisualLine] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        func collapsible(_ index: Int) -> Bool {
            let value = source.character(at: index)
            return value == 0x20 || value == 0x09
        }
        var paragraphs: [(start: Int, end: Int)] = []
        var start = 0, cursor = 0
        while cursor < source.length {
            let value = source.character(at: cursor)
            if value == 0x0A || value == 0x0D || value == 0x2028 || value == 0x2029 {
                let length = value == 0x0D && cursor + 1 < source.length && source.character(at: cursor + 1) == 0x0A ? 2 : 1
                paragraphs.append((start, cursor))
                cursor += length; start = cursor
            } else { cursor += 1 }
        }
        paragraphs.append((start, source.length))
        return paragraphs.flatMap { paragraph -> [VisualLine] in
            var firstContent = paragraph.start
            while firstContent < paragraph.end && collapsible(firstContent) { firstContent += 1 }
            // A soft break within an authored indent must not detach that
            // indent from the first text of its hard line.
            let limits = [paragraph.start] + breaks.filter { $0 > firstContent && $0 < paragraph.end } + [paragraph.end]
            return (0 ..< limits.count - 1).map { index in
                let lower = limits[index], upper = limits[index + 1]
                var visibleStart = lower, visibleEnd = upper
                if lower != paragraph.start {
                    while visibleStart < visibleEnd && collapsible(visibleStart) { visibleStart += 1 }
                }
                if upper != paragraph.end {
                    while visibleEnd > visibleStart && collapsible(visibleEnd - 1) { visibleEnd -= 1 }
                }
                return VisualLine(drawingRange: NSRange(location: visibleStart, length: visibleEnd - visibleStart),
                    preservesEmptyLine: paragraph.start == paragraph.end)
            }
        }
    }

    init(line: LyricLine, width: CGFloat, font: UIFont, configuration: LyricsRenderConfiguration,
         romanizationReserve: CGFloat = 0, preservesWordTiming: Bool = false, centered: Bool = false) {
        self.font = font
        auxiliaryPointSize = max(10, font.pointSize * (configuration.auxiliaryScale ?? 0.5))
        let availableWidth = max(1, width)
        func originX(for contentWidth: CGFloat) -> CGFloat {
            if centered { return (availableWidth - contentWidth) / 2 }
            return line.isDuet || line.isRTL ? availableWidth - contentWidth : 0
        }
        let generated = configuration.romanization && line.precision == .word
            ? (line.generatedRomanization ?? []) : []
        let originalChunks: [[AMLLWordSegmentation.Atom]] = if !generated.isEmpty,
            line.words.map(\.text).joined() == line.text
        {
            // The legacy splitter apportions one provider word's time over
            // CJK characters. Generated lexical words must instead retain the
            // exact provider node, even if a node spans several visual words.
            line.words.enumerated().map { index, word in
                [.init(word: word, sourceWordIndex: index,
                       sourceRange: NSRange(location: 0, length: word.text.utf16.count))]
            }
        } else if line.precision == .word {
            AMLLWordSegmentation.mappedChunks(line.words).map { chunk in
                guard preservesWordTiming else { return chunk }
                return chunk.map { atom in
                    guard !atom.word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return atom }
                    let source = line.words[atom.sourceWordIndex]
                    var preserved = atom
                    preserved.word.start = source.start
                    preserved.word.end = source.end
                    return preserved
                }
            }
        } else { [] }
        // A provider may time a whole phrase while the dictionary identifies
        // several lexical words. Split only the visual atom at safe Unicode
        // boundaries; every piece retains the one real provider time range.
        // No per-token timestamp is inferred from character length.
        var globalOffset = 0
        let mappedChunks: [[AMLLWordSegmentation.Atom]] = originalChunks.map { chunk in
            chunk.flatMap { atom -> [AMLLWordSegmentation.Atom] in
                let start = globalOffset
                let end = start + atom.word.text.utf16.count
                globalOffset = end
                let hasAnnotation = atom.word.romanWord != nil || atom.word.ruby != nil || !atom.word.rubySegments.isEmpty
                guard !hasAnnotation, !generated.isEmpty else { return [atom] }
                let boundaries = Set(generated.flatMap { [$0.utf16Start, $0.utf16End] })
                    .filter { $0 > start && $0 < end }.sorted()
                guard !boundaries.isEmpty else { return [atom] }
                let limits = [start] + boundaries + [end]
                let source = atom.word.text as NSString
                var pieces: [AMLLWordSegmentation.Atom] = []
                for index in 0 ..< limits.count - 1 {
                    let local = NSRange(location: limits[index] - start,
                                        length: limits[index + 1] - limits[index])
                    guard Range(local, in: atom.word.text) != nil else { return [atom] }
                    var word = atom.word
                    word.text = source.substring(with: local)
                    pieces.append(.init(word: word, sourceWordIndex: atom.sourceWordIndex,
                                        sourceRange: NSRange(location: atom.sourceRange.location + local.location,
                                                             length: local.length)))
                }
                return pieces
            }
        }
        let atoms = mappedChunks.flatMap(\.self)
        sourceAtoms = atoms
        if preservesWordTiming { pronunciationEmphasisChunks = mappedChunks.map { $0.map(\.word) } }
        var sourceRanges: [NSRange] = []
        var sourceCursor = 0
        for atom in atoms {
            let length = atom.word.text.utf16.count
            sourceRanges.append(NSRange(location: sourceCursor, length: length))
            sourceCursor += length
        }
        let validGenerated = !generated.isEmpty && atoms.map(\.word.text).joined() == line.text &&
            sourceCursor == line.text.utf16.count &&
            generated.allSatisfy { token in
                token.utf16Start >= 0 && token.utf16End <= sourceCursor && token.utf16End > token.utf16Start &&
                    sourceRanges.contains { $0.location == token.utf16Start } &&
                    sourceRanges.contains { NSMaxRange($0) == token.utf16End } &&
                    (line.text as NSString).substring(with: NSRange(location: token.utf16Start,
                                                                     length: token.utf16End - token.utf16Start)) == token.sourceText
            }
        hasGeneratedRomanizationLayout = validGenerated
        let layoutChunks: [[AMLLWordSegmentation.Atom]] = if validGenerated {
            // The pronunciation container owns every real timed atom beneath
            // it. Grouping only changes line breaks; no source time is changed.
            atoms.enumerated().reduce(into: [[AMLLWordSegmentation.Atom]]()) { chunks, item in
                let range = sourceRanges[item.offset]
                let owner = generated.firstIndex {
                    range.location >= $0.utf16Start && NSMaxRange(range) <= $0.utf16End
                }
                let previous = item.offset > 0 ? sourceRanges[item.offset - 1] : nil
                let previousOwner = previous.flatMap { previous in
                    generated.firstIndex { previous.location >= $0.utf16Start && NSMaxRange(previous) <= $0.utf16End }
                }
                if owner != nil && owner == previousOwner && !chunks.isEmpty {
                    chunks[chunks.count - 1].append(item.element)
                } else { chunks.append([item.element]) }
            }
        } else { mappedChunks }
        let chunks: [[LyricWord]] = if line.precision == .word {
            layoutChunks.map { $0.map(\.word) }
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
        let rubyFont = font.withSize(max(10, font.pointSize * 0.5))
        let romanFont = font.withSize(max(10, font.pointSize * (configuration.auxiliaryScale ?? 0.5)))
        let unambiguousRomanization = line.words.enumerated().allSatisfy { index, word in
            guard !(word.romanWord ?? "").isEmpty else { return true }
            return atoms.filter {
                $0.sourceWordIndex == index && !$0.word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count == 1
        }
        let wantsWordRomanization = configuration.romanization && line.precision == .word && line.words.contains {
            !($0.romanWord?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        let hasWordRomanization = !generated.isEmpty ? validGenerated
            : (wantsWordRomanization && unambiguousRomanization)
        func rubyText(_ word: LyricWord) -> String {
            word.rubySegments.isEmpty ? (word.ruby ?? "") : word.rubySegments.map(\.text).joined()
        }
        func measure(_ text: String, _ font: UIFont) -> Double {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [.font: font, .kern: configuration.tracking]
            )), nil, nil, nil)
        }
        func romanMeasure(_ token: RomanizationToken) -> Double {
            let plain = measure(token.romanized, romanFont)
            guard token.language == "ko" else { return plain }
            let spaces = token.romanized.filter { $0 == " " }.count
            return plain + Double(spaces) * (Double(romanFont.pointSize) * 0.22 - measure(" ", romanFont))
        }
        var generatedExtras = [Double](repeating: 0, count: timedWords.count)
        if validGenerated {
            for token in generated {
                let indexes = sourceRanges.indices.filter {
                    sourceRanges[$0].location >= token.utf16Start &&
                        NSMaxRange(sourceRanges[$0]) <= token.utf16End
                }
                guard let last = indexes.last else { continue }
                let mainWidth = indexes.reduce(0) { $0 + measure(timedWords[$1].text, font) }
                let romanWidth = romanMeasure(token) + romanFont.pointSize * 0.3
                generatedExtras[last] += max(0, romanWidth - mainWidth)
            }
        }
        let usesAnnotationContainers = line.precision == .word && (hasWordRomanization || timedWords.contains { !rubyText($0).isEmpty })
        func containerWidth(_ word: LyricWord, at index: Int, displayedText: String? = nil) -> Double {
            let main = measure(displayedText ?? word.text, font)
            let ruby = measure(rubyText(word), rubyFont)
            let roman = hasWordRomanization && !validGenerated ? measure(word.romanWord ?? "", romanFont) + romanFont.pointSize * 0.3 : 0
            return max(main, max(ruby, roman)) + generatedExtras[index]
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var children = texts.map { text in
            AMLLBalancedLayout.Child(text: text,
                                     width: CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), nil, nil, nil),
                                     isSpace: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if usesAnnotationContainers {
            var wordIndex = 0
            for index in children.indices {
                children[index].width = chunks[index].reduce(0) { width, word in
                    defer { wordIndex += 1 }
                    return width + containerWidth(word, at: wordIndex)
                }
            }
        }
        if line.precision != .word {
            let fullLine = CTLineCreateWithAttributedString(attributed)
            children = AMLLBalancedLayout.calibrated(children, visualWidth: CTLineGetTypographicBounds(fullLine, nil, nil, nil))
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
        let visualLines = Self.visualLines(in: text, breaks: breakOffsets)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var rows: [Row] = []
        var fragments: [WordFragment] = []
        var characterFragments: [CharacterFragment] = []
        var rubyFragments: [RubyFragment] = []
        var romanizationShapes: [RomanizationShape] = []
        // The original CSS uses 1.2em. The native compact secondary voice
        // uses 0.4em per the requested spacing; this is the entire inter-voice
        // gap, without an additional inset from the group layout.
        let backgroundPadding = line.isBackground ? font.pointSize * 0.4 : 0
        var y: CGFloat = backgroundPadding
        let mainHeight = if let typography = configuration.tabletTypography {
            max(font.lineHeight, font.pointSize + typography.visualLineLeading)
        } else {
            max(font.lineHeight, font.pointSize * 1.2)
        }
        // Segmentation can split one provider word into several atoms.
        // Without an explicit correspondence, keep the provider's line fallback
        // instead of repeating the same pronunciation under every atom.
        diagnostics = !generated.isEmpty && !validGenerated
            ? ["自动音译词边界与来源排版原子不重合，保留逐行音译。"]
            : wantsWordRomanization && !unambiguousRomanization && !validGenerated
                ? ["逐词罗马音对应关系不唯一，回退行级显示。"] : []
        let romanHeight = hasWordRomanization ? romanFont.pointSize : 0
        let rubyHeight = timedWords.contains { !$0.rubySegments.isEmpty || !($0.ruby?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            ? rubyFont.pointSize * 1.5
            : 0
        let lastBodyLine = visualLines.lastIndex { $0.drawingRange.length > 0 }
        for (visualIndex, visualLine) in visualLines.enumerated() {
            let range = visualLine.drawingRange
            guard range.length > 0 else {
                if visualLine.preservesEmptyLine { y += rubyHeight + mainHeight + romanHeight }
                continue
            }
            // A wrapped body line starts below the previous pronunciation's
            // descent. Keep the final annotation-to-next-cue spacing intact.
            let nextBodyGap = hasWordRomanization && visualIndex < (lastBodyLine ?? visualIndex)
                ? font.pointSize * 0.2 : 0
            let rowHeight = rubyHeight + mainHeight + romanHeight + nextBodyGap
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            if usesAnnotationContainers {
                // Source inline-flex words shape independently. Use the whole
                // row's bidi order to place containers, preserving logical UTF-16
                // ranges for masks rather than rebuilding indexes from glyph order.
                let referenceRuns = Self.visualRuns(in: ctLine)
                var cursor = 0
                var atoms: [(index: Int, range: NSRange, visualX: Double)] = []
                for (wordIndex, word) in timedWords.enumerated() {
                    let wordRange = NSRange(location: cursor, length: word.text.utf16.count)
                    cursor += wordRange.length
                    let displayedRange = NSIntersectionRange(range, wordRange)
                    guard displayedRange.length > 0 else { continue }
                    let positions = referenceRuns.compactMap { run -> Double? in
                        let overlap = NSIntersectionRange(wordRange, run.range)
                        guard overlap.length > 0 else { return nil }
                        return min(run.offset(at: overlap.location, in: ctLine), run.offset(at: NSMaxRange(overlap), in: ctLine))
                    }
                    atoms.append((wordIndex, displayedRange, positions.min() ?? 0))
                }
                atoms.sort { $0.visualX == $1.visualX ? $0.index < $1.index : $0.visualX < $1.visualX }
                let displayedText = text as NSString
                let total = atoms.reduce(0.0) {
                    $0 + containerWidth(timedWords[$1.index], at: $1.index,
                        displayedText: displayedText.substring(with: $1.range))
                }
                var atomX = originX(for: total)
                for atom in atoms {
                    let word = timedWords[atom.index]
                    let visibleText = displayedText.substring(with: atom.range)
                    let width = containerWidth(word, at: atom.index, displayedText: visibleText)
                    let shaped = CTLineCreateWithAttributedString(NSAttributedString(string: visibleText, attributes: attributes))
                    let mainWidth = CTLineGetTypographicBounds(shaped, nil, nil, nil)
                    // Only wordBody inside wordWithRuby centers its children.
                    // Plain romanWord containers inherit text-align: start.
                    let wordRTL = Self.visualRuns(in: shaped).first?.rtl ?? line.isRTL
                    let originX = atomX + (rubyHeight > 0 ? (width - mainWidth) / 2 : (wordRTL ? width - mainWidth : 0))
                    rows.append(.init(line: shaped, origin: CGPoint(x: originX, y: y + rubyHeight + font.ascender)))
                    atomX += width
                    let runs = Self.visualRuns(in: shaped)
                    guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    for run in runs {
                        fragments.append(.init(rect: CGRect(x: originX + run.left, y: y + rubyHeight, width: run.right - run.left, height: mainHeight),
                                               word: word, range: NSRange(location: atom.range.location + run.range.location, length: run.range.length),
                                               rtl: run.rtl, wordIndex: atom.index))
                    }
                    var localOffset = 0
                    let sourceStart = sourceRanges[atom.index].location
                    for (characterIndex, character) in word.text.enumerated() {
                        let value = String(character)
                        let originalRange = NSRange(location: sourceStart + localOffset, length: value.utf16.count)
                        localOffset += originalRange.length
                        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let displayedRange = NSIntersectionRange(originalRange, atom.range)
                        guard displayedRange.length > 0 else { continue }
                        let localRange = NSRange(location: displayedRange.location - atom.range.location, length: displayedRange.length)
                        for run in runs {
                            let overlap = NSIntersectionRange(localRange, run.range)
                            guard overlap.length > 0 else { continue }
                            let first = run.offset(at: overlap.location, in: shaped)
                            let last = run.offset(at: NSMaxRange(overlap), in: shaped)
                            characterFragments.append(.init(rect: CGRect(x: originX + min(first, last), y: y + rubyHeight, width: abs(last - first), height: mainHeight),
                                                            range: NSRange(location: atom.range.location + overlap.location, length: overlap.length),
                                                            rtl: run.rtl, wordIndex: atom.index, characterIndex: characterIndex, word: word))
                        }
                    }
                }
                y += rowHeight
                continue
            }
            let rowWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let x = originX(for: rowWidth)
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
            y += rowHeight
        }
        if hasWordRomanization {
            if validGenerated {
                var ttmlOrdinal = 0
                for token in generated {
                    let firstRuby = rubyFragments.count
                    let indexes = sourceRanges.indices.filter {
                        sourceRanges[$0].location >= token.utf16Start &&
                            NSMaxRange(sourceRanges[$0]) <= token.utf16End
                    }
                    guard let wordIndex = indexes.first,
                          let first = fragments.first(where: { indexes.contains($0.wordIndex) }) else { continue }
                    let sameRow = fragments.filter {
                        indexes.contains($0.wordIndex) && abs($0.rect.minY - first.rect.minY) < 0.01
                    }
                    let minX = sameRow.map(\.rect.minX).min() ?? first.rect.minX
                    let maxX = sameRow.map(\.rect.maxX).max() ?? first.rect.maxX
                    let value = NSMutableAttributedString(string: token.romanized, attributes: [
                        .font: romanFont, .foregroundColor: UIColor.white,
                        .kern: configuration.tracking,
                    ])
                    if token.language == "ko" {
                        let spaceAdjustment = Double(romanFont.pointSize) * 0.22 - measure(" ", romanFont)
                        let nsRoman = token.romanized as NSString
                        for offset in 0 ..< nsRoman.length where nsRoman.substring(with: NSRange(location: offset, length: 1)) == " " {
                            value.addAttribute(.kern, value: configuration.tracking + spaceAdjustment,
                                               range: NSRange(location: offset, length: 1))
                        }
                    }
                    let ctLine = CTLineCreateWithAttributedString(value)
                    let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                    let x = first.rtl ? maxX - width : minX
                    let top = first.rect.maxY
                    let leading = (romanHeight - romanFont.lineHeight) / 2
                    rows.append(.init(line: ctLine, origin: CGPoint(x: x, y: top + leading + romanFont.ascender),
                                      ruby: true, romanization: true))
                    let nodeIndexes = token.sourceNodeIndexes.filter { line.words.indices.contains($0) }
                    let tokenStart = nodeIndexes.map { line.words[$0].start }.min()
                    let tokenEnd = nodeIndexes.map { line.words[$0].end }.max()
                    let parts = token.romanized.split(separator: " ", omittingEmptySubsequences: true)
                    let timedSyllables = token.language == "ko" && !nodeIndexes.isEmpty && parts.count == nodeIndexes.count
                    var segments: [(NSRange, Double?, Double?)] = []
                    if timedSyllables {
                        var cursor = 0
                        for (part, node) in zip(parts, nodeIndexes) {
                            let range = NSRange(location: cursor, length: part.utf16.count)
                            segments.append((range, line.words[node].start, line.words[node].end))
                            cursor += part.utf16.count + 1
                        }
                    } else {
                        segments = [(NSRange(location: 0, length: value.length),
                                     nodeIndexes.map { line.words[$0].start }.min(),
                                     nodeIndexes.map { line.words[$0].end }.max())]
                    }
                    for (segmentIndex, segment) in segments.enumerated() {
                        for run in Self.visualRuns(in: ctLine) {
                            let overlap = NSIntersectionRange(segment.0, run.range)
                            guard overlap.length > 0 else { continue }
                            let left = run.offset(at: overlap.location, in: ctLine)
                            let right = run.offset(at: NSMaxRange(overlap), in: ctLine)
                            rubyFragments.append(.init(
                                rect: CGRect(x: x + min(left, right), y: top + min(0, leading),
                                             width: abs(right - left), height: max(romanHeight, romanFont.lineHeight)),
                                range: overlap, wordIndex: wordIndex, segmentIndex: segmentIndex,
                                start: segment.1, end: segment.2, rtl: run.rtl, kind: .romanization,
                                motionStart: tokenStart, motionEnd: tokenEnd,
                                ttmlWordIndex: ttmlOrdinal
                            ))
                        }
                        ttmlOrdinal += 1
                    }
                    if configuration.animationStyle == .appleMusic164, let row = rows.last {
                        romanizationShapes.append(.init(row: row, text: token.romanized,
                            rect: CGRect(x: x, y: top + min(0, leading), width: width, height: romanFont.lineHeight),
                            segments: Array(rubyFragments[firstRuby...])))
                    }
                }
            } else { for (wordIndex, word) in timedWords.enumerated() {
                guard let text = word.romanWord, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let first = fragments.first(where: { $0.wordIndex == wordIndex }) else { continue }
                let firstRow = fragments.filter { $0.wordIndex == wordIndex && abs($0.rect.minY - first.rect.minY) < 0.01 }
                let minX = firstRow.map(\.rect.minX).min() ?? first.rect.minX
                let maxX = firstRow.map(\.rect.maxX).max() ?? first.rect.maxX
                let value = NSAttributedString(string: text, attributes: [
                    .font: romanFont, .foregroundColor: UIColor.white,
                    .kern: configuration.tracking,
                ])
                let ctLine = CTLineCreateWithAttributedString(value)
                let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                let padding = romanFont.pointSize * 0.3
                let x = rubyHeight > 0
                    ? minX + (maxX - minX - width) / 2 + (first.rtl ? padding / 2 : -padding / 2)
                    : (first.rtl ? maxX - width : minX)
                let top = first.rect.maxY
                // Both inline annotation kinds use the disjoint annotation
                // raster; the separate line-level auxiliary raster stays intact.
                let leading = (romanHeight - romanFont.lineHeight) / 2
                rows.append(.init(line: ctLine, origin: CGPoint(x: x, y: top + leading + romanFont.ascender),
                                  ruby: true, romanization: true))
                let firstRuby = rubyFragments.count
                for run in Self.visualRuns(in: ctLine) {
                    rubyFragments.append(.init(
                        // Preserve ink extending beyond CSS's compact line box.
                        rect: CGRect(x: x + run.left, y: top + min(0, leading), width: run.right - run.left,
                                     height: max(romanHeight, romanFont.lineHeight)),
                        range: run.range, wordIndex: wordIndex, segmentIndex: 0,
                        start: word.romanStart ?? word.start, end: word.romanEnd ?? word.end, rtl: run.rtl, kind: .romanization
                    ))
                }
                if configuration.animationStyle == .appleMusic164, let row = rows.last {
                    romanizationShapes.append(.init(row: row, text: text,
                        rect: CGRect(x: x, y: top + min(0, leading), width: width, height: romanFont.lineHeight),
                        segments: Array(rubyFragments[firstRuby...])))
                }
            } }
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
                // Never span the horizontal bounds of two different visual rows.
                let firstRow = wordFragments.filter { abs($0.rect.minY - first.rect.minY) < 0.01 }
                let minX = firstRow.map(\.rect.minX).min() ?? first.rect.minX
                let maxX = firstRow.map(\.rect.maxX).max() ?? first.rect.maxX
                let value = NSAttributedString(string: rubyText, attributes: [
                    .font: rubyFont,
                    .foregroundColor: UIColor.white.withAlphaComponent(0.3),
                    .kern: configuration.tracking,
                ])
                let rubyLine = CTLineCreateWithAttributedString(value)
                let rubyWidth = CTLineGetTypographicBounds(rubyLine, nil, nil, nil)
                let x = minX + (maxX - minX - rubyWidth) / 2
                let rubyTop = first.rect.minY - rubyHeight
                rows.append(.init(line: rubyLine, origin: CGPoint(x: x, y: rubyTop + rubyFont.ascender), ruby: true))
                let segments = word.rubySegments.isEmpty ? [LyricRuby(text: rubyText)] : word.rubySegments
                var cursor = 0
                for (segmentIndex, segment) in segments.enumerated() {
                    let range = NSRange(location: cursor, length: segment.text.utf16.count)
                    cursor += range.length
                    for run in Self.visualRuns(in: rubyLine) {
                        let intersection = NSIntersectionRange(range, run.range)
                        guard intersection.length > 0 else { continue }
                        let left = run.offset(at: intersection.location, in: rubyLine)
                        let right = run.offset(at: NSMaxRange(intersection), in: rubyLine)
                        rubyFragments.append(.init(
                            rect: CGRect(x: x + min(left, right), y: rubyTop, width: abs(right - left), height: rubyHeight),
                            range: intersection, wordIndex: wordIndex, segmentIndex: segmentIndex,
                            start: segment.start, end: segment.end, rtl: run.rtl
                        ))
                    }
                }
            }
        }
        // lyricLineWrapper uses a .3em flex gap between the main and
        // auxiliary rows. Keeping it in the cached layout also keeps the
        // engine's measured group height aligned with the pixels.
        let auxiliaryTexts = configuration.auxiliaryEntries(for: line, displayingInlineRomanization: hasWordRomanization)
        var separateRomanizationY: CGFloat?
        if romanizationReserve > 0 && configuration.romanizationFirst {
            y += font.pointSize * 0.3
            separateRomanizationY = y
            y += romanizationReserve
        }
        if !auxiliaryTexts.isEmpty {
            y += font.pointSize * 0.3
        }
        for auxiliary in auxiliaryTexts {
            let auxiliaryFont = font.withSize(max(10, font.pointSize * (configuration.auxiliaryScale ?? 0.5)))
            let value = NSAttributedString(string: auxiliary.text, attributes: [.font: auxiliaryFont, .foregroundColor: UIColor.white.withAlphaComponent(0.3)])
            let typesetter = CTTypesetterCreateWithAttributedString(value)
            var cursor = 0
            var suggestedBreaks: [Int] = []
            while cursor < value.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, cursor, availableWidth))
                cursor += count
                if cursor < value.length { suggestedBreaks.append(cursor) }
            }
            for visualLine in Self.visualLines(in: auxiliary.text, breaks: suggestedBreaks) {
                let range = visualLine.drawingRange
                guard range.length > 0 else {
                    if visualLine.preservesEmptyLine { y += auxiliaryFont.pointSize * 1.5 }
                    continue
                }
                let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
                let rowWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                rows.append(.init(line: ctLine, origin: CGPoint(x: originX(for: rowWidth),
                                                                y: y + auxiliaryFont.ascender), auxiliary: true,
                                  auxiliaryKind: auxiliary.kind,
                                  auxiliaryRect: CGRect(x: 0, y: y, width: availableWidth, height: auxiliaryFont.pointSize * 1.5)))
                y += auxiliaryFont.pointSize * 1.5
            }
        }
        if romanizationReserve > 0 && !configuration.romanizationFirst {
            y += font.pointSize * 0.3
            separateRomanizationY = y
            y += romanizationReserve
        }
        if line.isBackground {
            y += backgroundPadding
        }
        self.rows = rows
        self.romanizationShapes = romanizationShapes
        romanizationSlotY = separateRomanizationY
        self.fragments = fragments
        self.characterFragments = characterFragments
        self.rubyFragments = rubyFragments
        // A wrapped word has several drawable fragments, but only one timing interval.
        // Pure spaces are DOM text nodes and do not contribute mask travel in AMLL.
        var fragmentWidths = [Double](repeating: 0, count: timedWords.count)
        for fragment in fragments where fragmentWidths.indices.contains(fragment.wordIndex) {
            fragmentWidths[fragment.wordIndex] += fragment.rect.width
        }
        maskWords = timedWords.enumerated().map { index, word in
            .init(start: word.start, end: word.end, width: fragmentWidths[index])
        }
        size = CGSize(width: availableWidth, height: max(1, y + (configuration.paragraphSpacing ?? 0)))
    }

    #if DEBUG
        struct GlyphFontRun: Codable {
            var role: String
            var name: String
            var family: String
            var pointSize: Double
        }

        /// The font resolved by the typesetter, not the requested UIFont name.
        var glyphFontRuns: [GlyphFontRun] {
            rows.flatMap { row in
                (CTLineGetGlyphRuns(row.line) as! [CTRun]).compactMap { run in
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let value = attributes[kCTFontAttributeName] else { return nil }
                    let font = value as! CTFont
                    return GlyphFontRun(role: row.romanization ? "romanization" : row.ruby ? "ruby" : row.auxiliary ? "auxiliary" : "body",
                                        name: CTFontCopyPostScriptName(font) as String,
                                        family: CTFontCopyFamilyName(font) as String,
                                        pointSize: Double(CTFontGetSize(font)))
                }
            }
        }
    #endif

    func rasterSnapshot() -> AMLLCoreTextRasterSnapshot { .init(size: size, rows: rows) }

    /// nil draws both layers for inspection; the renderer composites auxiliary text separately.
    func raster(scale: CGFloat, auxiliary: Bool? = nil, ruby: Bool? = nil,
                romanization: Bool? = nil, blurRadius: CGFloat = 0) -> UIImage {
        rasterSnapshot().raster(scale: scale, auxiliary: auxiliary, ruby: ruby,
                                romanization: romanization, blurRadius: blurRadius)
    }
}
