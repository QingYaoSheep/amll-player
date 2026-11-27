import CoreGraphics

enum ArtworkReflectionGeometry {
    static func frame(cover: CGRect, viewportHeight: CGFloat) -> CGRect {
        CGRect(x: cover.minX, y: cover.maxY, width: cover.width,
               height: max(220, min(viewportHeight * 0.30, 340)))
    }
}

enum ArtworkReflectionStyle {
    static let fadeStops: [(location: Double, alpha: Double)] = [
        (0, 1), (0.12, 0.78), (0.22, 0.58), (0.50, 0.34), (0.72, 0.15), (0.88, 0.045), (1, 0),
    ]
}
