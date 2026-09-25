import QuartzCore
import UIKit

/// Draws only the generated pronunciation glyphs from the original word
/// containers. The glyph positions come from Core Text's shared layout, while
/// every fill edge reads the separately parsed TTML cue.
@MainActor
final class AMLLRomanizationOverlay: UIView {
    private struct Piece {
        var layer: CALayer
        var mask: CAGradientLayer
        var fragment: AMLLCoreTextLayout.RubyFragment
        var width: Double
        var advance: Double
    }

    private let cue: LyricLine
    private let layout: AMLLCoreTextLayout
    private let nearBlur = CALayer()
    private let farBlur = CALayer()
    private var pieces: [Piece] = []
    var onSeek: (() -> Void)?

    init(layout: AMLLCoreTextLayout, cue: LyricLine, scale: CGFloat) {
        self.layout = layout
        self.cue = cue
        super.init(frame: CGRect(origin: .zero, size: layout.size))
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = cue.text
        accessibilityIdentifier = "lyricRow." + cue.id
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))

        let image = layout.raster(scale: scale, auxiliary: false, ruby: true, romanization: true)
        let fragments = layout.rubyFragments.filter { $0.kind == .romanization && $0.rect.width > 0 }
        var advances: [Int: Double] = [:]
        for fragment in fragments {
            let ordinal = fragment.ttmlWordIndex ?? -1
            let width = fragments.filter { $0.ttmlWordIndex == fragment.ttmlWordIndex }
                .reduce(0.0) { $0 + $1.rect.width }
            let glyph = CALayer()
            glyph.frame = fragment.rect
            glyph.contents = image.cgImage
            glyph.contentsScale = scale
            glyph.contentsRect = CGRect(x: fragment.rect.minX / layout.size.width,
                                        y: fragment.rect.minY / layout.size.height,
                                        width: fragment.rect.width / layout.size.width,
                                        height: fragment.rect.height / layout.size.height)
            let mask = CAGradientLayer()
            mask.frame = glyph.bounds
            glyph.mask = mask
            layer.addSublayer(glyph)
            pieces.append(.init(layer: glyph, mask: mask, fragment: fragment,
                                width: width, advance: advances[ordinal, default: 0]))
            advances[ordinal, default: 0] += fragment.rect.width
        }
        for (blurLayer, radius) in [(nearBlur, CGFloat(2)), (farBlur, CGFloat(5))] {
            let blurred = layout.raster(scale: min(scale, 1), ruby: true, romanization: true,
                                        blurRadius: radius)
            let paddingX = (blurred.size.width - bounds.width) / 2
            let paddingY = (blurred.size.height - bounds.height) / 2
            blurLayer.frame = CGRect(x: -paddingX, y: -paddingY,
                                     width: blurred.size.width, height: blurred.size.height)
            blurLayer.contents = blurred.cgImage
            blurLayer.contentsScale = min(scale, 1)
            blurLayer.opacity = 0
            layer.addSublayer(blurLayer)
        }
    }

    required init?(coder _: NSCoder) { nil }

    func setCanSeek(_ value: Bool) {
        accessibilityTraits = value ? .button : []
        accessibilityHint = value ? NSLocalizedString("render.seekHint", comment: "") : nil
    }

    override func accessibilityActivate() -> Bool {
        onSeek?()
        return onSeek != nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -22, dy: -22).contains(point) || super.point(inside: point, with: event)
    }

    func update(row: AMLLFrameState.Row, lyricTime: Double, configuration: LyricsRenderConfiguration) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alpha = row.opacity * (cue.isBackground ? 0.4 : 1)
        let radius = min(5, max(0, row.blur))
        let sharp = Float(max(0, 1 - radius / 2))
        let active = lyricTime >= cue.start && lyricTime < cue.end
        let bright = active ? row.brightAlpha : row.darkAlpha
        nearBlur.opacity = Float(radius <= 2 ? radius / 2 : (5 - radius) / 3) * Float(row.darkAlpha)
        farBlur.opacity = Float(max(0, (radius - 2) / 3)) * Float(row.darkAlpha)
        let feather = max(0.0001, layout.font.lineHeight * configuration.gradientWidth * 0.5)
        for piece in pieces {
            piece.layer.opacity = sharp
            let ordinal = piece.fragment.ttmlWordIndex ?? -1
            guard cue.words.indices.contains(ordinal) else {
                // The TTML file has only paragraph timing for this source
                // line. Keep the pronunciation line-level, without making up
                // syllable or word timestamps.
                let brightness = bright
                piece.mask.colors = [UIColor.white.withAlphaComponent(brightness).cgColor,
                                     UIColor.white.withAlphaComponent(brightness).cgColor]
                continue
            }
            let word = cue.words[ordinal]
            let edge = AMLLWordMask.edge(time: lyricTime, index: 0,
                                         words: [.init(start: word.start, end: word.end,
                                                       width: piece.width)], feather: feather) - piece.advance
            let first = edge / max(1, piece.fragment.rect.width)
            let last = (edge + feather) / max(1, piece.fragment.rect.width)
            piece.mask.colors = [UIColor.white.withAlphaComponent(bright).cgColor,
                                 UIColor.white.withAlphaComponent(row.darkAlpha).cgColor]
            piece.mask.locations = [0, 1]
            piece.mask.startPoint = CGPoint(x: piece.fragment.rtl ? 1 - first : first, y: 0.5)
            piece.mask.endPoint = CGPoint(x: piece.fragment.rtl ? 1 - last : last, y: 0.5)
        }
        CATransaction.commit()
    }

    @objc private func tap() { onSeek?() }
}
