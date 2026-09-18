import MetalKit
import UIKit

/// Replaces the sharp main-glyph layers using their already evaluated geometry.
/// Parent row transforms and the canvas fade mask remain shared with SDR text.
@MainActor
final class LyricsHDRRow {
    struct Piece {
        var rect: CGRect
        var transform: CGAffineTransform
        var rtl: Bool
        var edge: Double
        var feather: Double
        var dark: Double
        var bright: Double
        var glowRadius: Double = 0
        var glowOpacity: Double = 0
    }

    let layer: CAMetalLayer
    private let renderer: LyricsHDRRenderer
    private let atlas: MTLTexture
    private let atlasSize: CGSize
    private let padding: CGFloat

    init?(renderer: LyricsHDRRenderer, image: CGImage, size: CGSize, scale: CGFloat, padding: CGFloat) {
        guard let texture = renderer.glyphTexture(image) else { return nil }
        self.renderer = renderer; atlas = texture; atlasSize = size; self.padding = padding
        layer = renderer.makeLayer(size: CGSize(width: size.width + padding * 2, height: size.height + padding * 2), scale: scale)
        layer.frame.origin = CGPoint(x: -padding, y: -padding)
        layer.allowsNextDrawableTimeout = true
    }

    func draw(pieces: [Piece], gain: Double, sharpWeight: Float) -> Bool {
        guard !pieces.isEmpty, let drawable = layer.nextDrawable() else { layer.isHidden = true; return false }
        var vertices: [LyricsHDRRenderer.Vertex] = []
        vertices.reserveCapacity(pieces.count * 12)
        func append(_ piece: Piece, shadow: Bool) {
            let rect = piece.rect
            let extra = shadow ? piece.glowRadius * 3 : 0
            let extent = rect.insetBy(dx: -extra, dy: -extra)
            let crop = SIMD4<Float>(Float(rect.minX / atlasSize.width), Float(rect.minY / atlasSize.height),
                                    Float(rect.maxX / atlasSize.width), Float(rect.maxY / atlasSize.height))
            for (u, v) in [(0.0, 0.0), (0, 1), (1, 0), (1, 0), (0, 1), (1, 1)] {
                let x = extent.minX + u * extent.width
                let y = extent.minY + v * extent.height
                let point = CGPoint(x: x - rect.midX, y: y - rect.midY).applying(piece.transform)
                let alpha = shadow ? piece.glowOpacity : 1
                vertices.append(.init(
                    position: .init(Float((point.x + rect.midX + padding) / layer.bounds.width * 2 - 1),
                                    Float(1 - (point.y + rect.midY + padding) / layer.bounds.height * 2)),
                    uv: .init(Float(x / atlasSize.width), Float(y / atlasSize.height)),
                    mask: .init(Float(piece.rtl ? rect.maxX - x : x - rect.minX), Float(piece.edge)),
                    appearance: .init(Float(max(0.0001, piece.feather)), Float(piece.dark * alpha),
                                      Float(piece.bright * alpha), Float(shadow ? 1 : gain)),
                    crop: crop,
                    glow: shadow ? .init(Float(piece.glowRadius / atlasSize.width), Float(piece.glowRadius / atlasSize.height)) : .zero
                ))
            }
        }
        for piece in pieces where piece.glowRadius > 0 && piece.glowOpacity > 0 {
            append(piece, shadow: true)
        }
        for piece in pieces {
            append(piece, shadow: false)
        }
        guard renderer.render(vertices: vertices, glyphs: atlas, target: drawable.texture, drawable: drawable) != nil else {
            layer.isHidden = true; return false
        }
        layer.opacity = sharpWeight
        layer.wantsExtendedDynamicRangeContent = gain > 1
        layer.isHidden = false
        return true
    }
}
