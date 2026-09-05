import CoreImage
import UIKit

/// TextKit shapes complete paragraphs, preserving ligatures, composed characters, fallback fonts and bidi runs.
@MainActor
final class LyricTextLayout {
    struct Fragment {
        let rect: CGRect
        let start: Double
        let end: Double
        let lower: Double
        let upper: Double
        let rtl: Bool
    }

    let size: CGSize
    let fragments: [Fragment]
    private let manager: NSLayoutManager
    private let storage: NSTextStorage
    private let container: NSTextContainer
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(line: LyricLine, width: CGFloat, configuration: LyricsRenderConfiguration, traits: UITraitCollection) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = line.isDuet || line.isRTL ? .right : .left
        paragraph.baseWritingDirection = line.isRTL ? .rightToLeft : .natural
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        let baseSize = configuration.fontSize * (line.isBackground ? 0.78 : 1)
        let font = UIFontMetrics(forTextStyle: .title1).scaledFont(
            for: .systemFont(ofSize: baseSize, weight: configuration.bold ? .bold : .medium), compatibleWith: traits
        )
        let attributed = NSMutableAttributedString(string: line.text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .kern: configuration.tracking, .paragraphStyle: paragraph,
        ])
        for text in configuration.auxiliaryText(for: line) {
            attributed.append(NSAttributedString(string: "\n" + text, attributes: [
                .font: font.withSize(font.pointSize * 0.56), .foregroundColor: UIColor.white.withAlphaComponent(0.8),
                .paragraphStyle: paragraph,
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
        for word in words {
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
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                if rect.width > 0 {
                    rectangles.append(rect)
                }
            }
            // Preserve visual rows; reverse fragments within a row for RTL text.
            rectangles.sort { abs($0.minY - $1.minY) < 1 ? (wordRTL ? $0.minX > $1.minX : $0.minX < $1.minX) : $0.minY < $1.minY }
            let total = rectangles.reduce(CGFloat.zero) { $0 + $1.width }
            var consumed: CGFloat = 0
            for rect in rectangles where total > 0 {
                result.append(Fragment(rect: rect, start: word.start, end: word.end,
                                       lower: consumed / total, upper: (consumed + rect.width) / total, rtl: wordRTL))
                consumed += rect.width
            }
        }
        fragments = result
    }

    func image(scale: CGFloat, blurred: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale; format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
        }
        guard blurred, let input = CIImage(image: image),
              let output = Self.context.createCGImage(input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2 * scale]), from: input.extent)
        else { return image }
        return UIImage(cgImage: output, scale: scale, orientation: .up)
    }
}

@MainActor
final class LyricRowView: UIView {
    private let base = CALayer()
    private let highlight = CALayer()
    private var pieces: [(CALayer, CAGradientLayer, LyricTextLayout.Fragment)] = []
    private var sharp: CGImage?
    private var soft: CGImage?
    var line: LyricLine?
    var onSeek: (() -> Void)?
    var onFocus: (() -> Void)?
    var onResume: (() -> Void)?
    private var wasActive: Bool?
    private var canSeek = false

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
        soft = blur ? layout.image(scale: scale, blurred: true).cgImage : sharp
        base.frame = CGRect(origin: .zero, size: layout.size); base.contents = soft
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

    func update(time: Double, active: Bool, configuration: LyricsRenderConfiguration, policy: RenderQualityPolicy, reduceMotion: Bool) {
        guard line != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.contents = active || !policy.blur || !configuration.blurInactive ? sharp : soft
        base.opacity = active ? 0.45 : 0.28
        // LRC is a genuine line-level highlight; never manufacture word progress.
        highlight.opacity = pieces.isEmpty && active ? 1 : 0
        for (piece, mask, fragment) in pieces {
            let global = LyricsTimeline.progress(time: time, start: fragment.start, end: fragment.end)
            let progress = min(1, max(0, (global - fragment.lower) / max(0.00001, fragment.upper - fragment.lower)))
            let feather = min(0.4, configuration.gradientWidth / max(1, fragment.rect.width))
            mask.locations = [0, NSNumber(value: max(0, progress - feather)), NSNumber(value: progress), 1]
            // A completed word is entirely filled, including its final glyph edge.
            piece.mask = progress >= 1 ? nil : mask
            piece.opacity = active && progress > 0 ? 1 : 0
            let lift = configuration.emphasizeWords && policy.emphasis && global > 0 && global < 1 ? sin(global * .pi) * 2 : 0
            piece.transform = CATransform3DMakeTranslation(0, -lift, 0)
        }
        CATransaction.commit()
        if active != wasActive {
            wasActive = active
            setCanSeek(canSeek)
            let scale = active || reduceMotion ? 1.0 : 0.97
            if reduceMotion {
                layer.removeAllAnimations(); transform = .identity
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.transform = CGAffineTransform(scaleX: scale, y: scale) }
            }
        }
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
