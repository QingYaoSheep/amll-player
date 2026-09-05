import CoreImage
import UIKit

/// TextKit shapes complete paragraphs, preserving ligatures, composed characters, fallback fonts and bidi runs.
@MainActor
final class LyricTextLayout {
    private struct RasterKey: Hashable {
        var scale: CGFloat
        var blurRadius: CGFloat
    }

    struct Fragment {
        let rect: CGRect
        let start: Double
        let end: Double
        let lower: Double
        let upper: Double
        let rtl: Bool
        let characterIndex: Int
        let characterCount: Int
        let wordText: String
        let isLastWord: Bool
        let fontSize: CGFloat
    }

    let size: CGSize
    let fragments: [Fragment]
    private let manager: NSLayoutManager
    private let storage: NSTextStorage
    private let container: NSTextContainer
    private var rasters: [RasterKey: UIImage] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(line: LyricLine, width: CGFloat, configuration: LyricsRenderConfiguration, traits: UITraitCollection) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = line.isDuet || line.isRTL ? .right : .left
        paragraph.baseWritingDirection = line.isRTL ? .rightToLeft : .natural
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 0
        let baseSize = configuration.fontSize * (line.isBackground ? AMLLMotionMetrics.backgroundLineScale : 1)
        let font = UIFontMetrics(forTextStyle: .title1).scaledFont(
            for: .systemFont(ofSize: baseSize, weight: configuration.bold ? .bold : .medium), compatibleWith: traits
        )
        paragraph.minimumLineHeight = font.pointSize * 1.2
        paragraph.maximumLineHeight = font.pointSize * 1.2
        let attributed = NSMutableAttributedString(string: line.text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .kern: configuration.tracking, .paragraphStyle: paragraph,
        ])
        for text in configuration.auxiliaryText(for: line) {
            guard let auxiliaryParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle else { continue }
            auxiliaryParagraph.minimumLineHeight = font.pointSize * AMLLMotionMetrics.auxiliaryLineScale * 1.5
            auxiliaryParagraph.maximumLineHeight = font.pointSize * AMLLMotionMetrics.auxiliaryLineScale * 1.5
            attributed.append(NSAttributedString(string: "\n" + text, attributes: [
                .font: font.withSize(font.pointSize * AMLLMotionMetrics.auxiliaryLineScale),
                .foregroundColor: UIColor.white.withAlphaComponent(AMLLMotionMetrics.auxiliaryLineOpacity),
                .paragraphStyle: auxiliaryParagraph,
            ]))
        }
        storage = NSTextStorage(attributedString: attributed)
        manager = NSLayoutManager()
        container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        size = CGSize(width: max(1, width), height: ceil(manager.usedRect(for: container).maxY) + 8)
        var result: [Fragment] = []
        let text = line.text as NSString
        var cursor = 0
        let words = line.precision == .word ? line.words : []
        for (wordIndex, word) in words.enumerated() {
            guard !word.text.isEmpty, cursor < text.length else { continue }
            let range = text.range(of: word.text, range: NSRange(location: cursor, length: text.length - cursor))
            guard range.location != NSNotFound else { continue }
            cursor = NSMaxRange(range)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var bidiLevel: UInt8 = 0
            if glyphs.length > 0 {
                _ = manager.getGlyphs(in: NSRange(location: glyphs.location, length: 1), glyphs: nil,
                                      properties: nil, characterIndexes: nil, bidiLevels: &bidiLevel)
            }
            let wordRTL = bidiLevel % 2 == 1
            var rectangles: [CGRect] = []
            for glyphIndex in glyphs.location ..< NSMaxRange(glyphs) {
                let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
                if rect.width > 0, rect.height > 0 {
                    rectangles.append(rect)
                }
            }
            // Preserve visual rows; reverse fragments within a row for RTL text.
            rectangles.sort { abs($0.minY - $1.minY) < 1 ? (wordRTL ? $0.minX > $1.minX : $0.minX < $1.minX) : $0.minY < $1.minY }
            let total = rectangles.reduce(CGFloat.zero) { $0 + $1.width }
            var consumed: CGFloat = 0
            for (characterIndex, rect) in rectangles.enumerated() where total > 0 {
                result.append(Fragment(rect: rect, start: word.start, end: word.end,
                                       lower: consumed / total, upper: (consumed + rect.width) / total, rtl: wordRTL,
                                       characterIndex: characterIndex, characterCount: rectangles.count, wordText: word.text,
                                       isLastWord: wordIndex == words.count - 1, fontSize: font.pointSize))
                consumed += rect.width
            }
        }
        fragments = result
    }

    func image(scale: CGFloat, blurRadius: CGFloat = 0) -> UIImage {
        let key = RasterKey(scale: scale, blurRadius: blurRadius)
        if let cached = rasters[key] { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale; format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
        }
        guard blurRadius > 0, let input = CIImage(image: image),
              let output = Self.context.createCGImage(
                  input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius * scale]),
                  from: input.extent
              )
        else {
            rasters[key] = image
            return image
        }
        let result = UIImage(cgImage: output, scale: scale, orientation: .up)
        rasters[key] = result
        return result
    }
}

@MainActor
final class LyricRowView: UIView {
    private let base = CALayer()
    private let highlight = CALayer()
    private var pieces: [(CALayer, CAGradientLayer, LyricTextLayout.Fragment)] = []
    private var sharp: CGImage?
    private var softNear: CGImage?
    private var softFar: CGImage?
    var line: LyricLine?
    var onSeek: (() -> Void)?
    var onFocus: (() -> Void)?
    var onResume: (() -> Void)?
    private var wasActive: Bool?
    private var canSeek = false
    private var scaleSpring = AMLLSpring(value: 100)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(base); layer.addSublayer(highlight)
        isAccessibilityElement = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func configure(line: LyricLine, layout: LyricTextLayout, scale: CGFloat, configuration: LyricsRenderConfiguration, blur: Bool, canSeek: Bool, onSeek: @escaping () -> Void) {
        self.line = line; self.onSeek = onSeek
        let context = [line.text] + configuration.auxiliaryText(for: line)
        accessibilityLabel = context.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityIdentifier = "lyricRow." + line.id
        setCanSeek(canSeek)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: NSLocalizedString("render.returnCurrent", comment: ""), target: self, selector: #selector(resume))]
        pieces.forEach { $0.0.removeFromSuperlayer() }; pieces.removeAll()
        sharp = layout.image(scale: scale).cgImage
        softNear = blur ? layout.image(scale: scale, blurRadius: 2).cgImage : sharp
        softFar = blur ? layout.image(scale: scale, blurRadius: 5).cgImage : softNear
        base.frame = CGRect(origin: .zero, size: layout.size); base.contents = softNear
        highlight.frame = base.frame; highlight.contents = sharp; highlight.opacity = 0
        for fragment in layout.fragments {
            let piece = CALayer(), mask = CAGradientLayer()
            piece.contents = sharp
            piece.frame = fragment.rect
            piece.contentsRect = CGRect(x: fragment.rect.minX / layout.size.width, y: fragment.rect.minY / layout.size.height,
                                        width: fragment.rect.width / layout.size.width, height: fragment.rect.height / layout.size.height)
            mask.frame = piece.bounds
            mask.startPoint = CGPoint(x: fragment.rtl ? 1 : 0, y: 0.5)
            mask.endPoint = CGPoint(x: fragment.rtl ? 0 : 1, y: 0.5)
            mask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
            piece.mask = mask; layer.addSublayer(piece)
            pieces.append((piece, mask, fragment))
        }
        wasActive = nil
        scaleSpring.set(value: 100)
        layer.removeAllAnimations(); transform = .identity
    }

    func setCanSeek(_ value: Bool) {
        canSeek = value
        accessibilityTraits = value ? [.button] : [.staticText]
        if wasActive == true {
            accessibilityTraits.insert(.selected)
        }
        accessibilityHint = value ? NSLocalizedString("render.seekHint", comment: "") : nil
    }

    func update(time: Double, active: Bool, configuration: LyricsRenderConfiguration, policy: RenderQualityPolicy,
                reduceMotion: Bool, delta: TimeInterval = 1.0 / 60.0, blurLevel: Double = 0)
    {
        guard let line else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if active || !policy.blur || !configuration.blurInactive {
            base.contents = sharp
        } else {
            base.contents = blurLevel >= 3.5 ? softFar : softNear
        }
        let lineOpacity = line.isBackground ? AMLLMotionMetrics.backgroundLineOpacity : 1
        base.opacity = Float((active ? 0.4 : 0.2) * lineOpacity)
        // LRC is a genuine line-level highlight; never manufacture word progress.
        highlight.opacity = pieces.isEmpty && active ? Float(lineOpacity) : 0
        for (piece, mask, fragment) in pieces {
            let global = LyricsTimeline.progress(time: time, start: fragment.start, end: fragment.end)
            let progress = min(1, max(0, (global - fragment.lower) / max(0.00001, fragment.upper - fragment.lower)))
            let fadeWidth = fragment.fontSize * configuration.gradientWidth
            let feather = min(0.5, fadeWidth / max(1, fragment.rect.width))
            mask.locations = [0, NSNumber(value: max(0, progress - feather)), NSNumber(value: progress), 1]
            // A completed word is entirely filled, including its final glyph edge.
            piece.mask = progress >= 1 ? nil : mask
            piece.opacity = active && progress > 0 ? Float(lineOpacity) : 0
            let motion = AMLLWordMotion.presentation(
                time: time, wordStart: fragment.start, wordEnd: fragment.end,
                characterIndex: fragment.characterIndex, characterCount: fragment.characterCount,
                text: fragment.wordText, isLastWord: fragment.isLastWord, isBackground: line.isBackground,
                enabled: configuration.emphasizeWords && policy.emphasis && active
            )
            let em = Double(fragment.fontSize)
            var transform = CATransform3DMakeTranslation(motion.offsetX * em, motion.offsetY * em, 0)
            transform = CATransform3DScale(transform, motion.scale, motion.scale, 1)
            piece.transform = transform
            piece.shadowColor = UIColor.white.cgColor
            piece.shadowRadius = motion.glowRadius * em
            piece.shadowOpacity = Float(motion.glowOpacity)
            piece.shadowOffset = .zero
        }
        CATransaction.commit()
        if active != wasActive {
            wasActive = active; setCanSeek(canSeek)
        }
        scaleSpring.parameters = line.isBackground ? .backgroundScale : .scale
        let targetScale = active || reduceMotion ? 100 : (line.isBackground ? AMLLMotionMetrics.inactiveBackgroundScale * 100 : AMLLMotionMetrics.inactiveScale * 100)
        let scale = reduceMotion ? targetScale : scaleSpring.step(target: targetScale, delta: delta)
        transform = CGAffineTransform(scaleX: scale / 100, y: scale / 100)
    }

    override func accessibilityActivate() -> Bool {
        guard canSeek, let onSeek else { return false }
        onSeek(); return true
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused(); onFocus?()
    }

    @objc private func tapped() {
        if canSeek {
            onSeek?()
        }
    }

    @objc private func resume() -> Bool {
        onResume?(); return onResume != nil
    }
}
