import CoreImage
import SwiftUI

/// Frame handoff from the existing silent video; reflection never creates a second player.
@MainActor final class ArtworkReflectionFrames {
    weak var surface: ArtworkReflection.Surface?
    private var source: UUID?

    func begin() -> UUID {
        let token = UUID()
        source = token
        surface?.layer.contents = nil
        return token
    }

    func display(_ buffer: CVPixelBuffer, source token: UUID) {
        guard token == source else { return }
        surface?.display(buffer)
    }

    func clear(source token: UUID?) {
        guard token == source else { return }
        source = nil
        surface?.layer.contents = nil
    }
}

enum ArtworkReflectionGeometry {
    static func frame(cover: CGRect, viewportHeight: CGFloat) -> CGRect {
        CGRect(x: cover.minX, y: ceil(cover.maxY) + 49, width: cover.width,
               height: max(220, min(viewportHeight * 0.30, 340)))
    }
}

struct ArtworkReflection: UIViewRepresentable {
    let frames: ArtworkReflectionFrames

    func makeUIView(context _: Context) -> Surface {
        let view = Surface()
        frames.surface = view
        return view
    }

    func updateUIView(_ view: Surface, context _: Context) {
        frames.surface = view
    }

    static func dismantleUIView(_ view: Surface, coordinator _: ()) {
        view.layer.contents = nil
    }

    final class Surface: UIView {
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let fade = CAGradientLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            layer.opacity = 0.24
            fade.colors = [0.78, 0.58, 0.34, 0.15, 0.045, 0].map { UIColor(white: 1, alpha: $0).cgColor }
            fade.locations = [0, 0.22, 0.50, 0.72, 0.88, 1]
            layer.mask = fade
        }

        required init?(coder _: NSCoder) {
            nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fade.frame = bounds
            CATransaction.commit()
        }

        func display(_ buffer: CVPixelBuffer) {
            guard bounds.width > 0, bounds.height > 0, window != nil else { return }
            let scale = min(1.5, window?.screen.scale ?? 1)
            let size = CGSize(width: max(2, (bounds.width * scale).rounded()), height: max(2, (bounds.height * scale).rounded()))
            let source = CIImage(cvPixelBuffer: buffer)
            let height = max(2, (source.extent.height * 0.24).rounded())
            let crop = CGRect(x: source.extent.minX, y: source.extent.minY, width: source.extent.width, height: height)
            let image = source.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
                .transformed(by: CGAffineTransform(scaleX: size.width / crop.width, y: size.height / height))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9 * scale])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.06])
            guard let rendered = context.createCGImage(image, from: CGRect(origin: .zero, size: size)) else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.contents = rendered
            CATransaction.commit()
        }
    }
}
