import CoreImage
import SwiftUI

/// Frame handoff from the existing silent video; reflection never creates a second player.
@MainActor final class ArtworkReflectionFrames {
    weak var surface: ArtworkReflection.Surface?
    weak var transitionSurface: ArtworkVideoTransition.Surface?
    private var source: UUID?

    func begin() -> UUID {
        let token = UUID()
        source = token
        surface?.clear()
        transitionSurface?.clear()
        return token
    }

    func display(_ buffer: CVPixelBuffer, source token: UUID) {
        guard token == source else { return }
        surface?.display(buffer)
        transitionSurface?.display(buffer)
    }

    func clear(source token: UUID?) {
        guard token == source else { return }
        source = nil
        surface?.clear()
        transitionSurface?.clear()
    }
}

enum ArtworkReflectionGeometry {
    static func frame(cover: CGRect, viewportHeight: CGFloat) -> CGRect {
        CGRect(x: cover.minX, y: cover.maxY, width: cover.width,
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
        view.clear()
    }

    final class Surface: UIView {
        private let renderer = Renderer()
        private var generation = UUID()
        private var rendering = false
        private var pending: Frame?
        private var previousSize = CGSize.zero
        private let fade = CAGradientLayer()

        /// Pixel buffers are retained immutable inputs. Only the serial worker
        /// accesses Core Image; the main actor owns scheduling and the layer.
        private struct Frame: @unchecked Sendable {
            let buffer: CVPixelBuffer
            let size: CGSize
            let scale: CGFloat
            let generation: UUID
        }

        private final class Renderer: @unchecked Sendable {
            let queue = DispatchQueue(label: "AMLL.artwork.reflection", qos: .userInitiated)
            let context = CIContext(options: [.cacheIntermediates: false])

            func render(_ frame: Frame) -> CGImage? {
                let source = CIImage(cvPixelBuffer: frame.buffer)
                let height = max(2, (source.extent.height * 0.24).rounded())
                let crop = CGRect(x: source.extent.minX, y: source.extent.minY, width: source.extent.width, height: height)
                let image = source.cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
                    .transformed(by: CGAffineTransform(scaleX: frame.size.width / crop.width, y: frame.size.height / height))
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9 * frame.scale])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.06])
                return context.createCGImage(image, from: CGRect(origin: .zero, size: frame.size))
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            layer.opacity = 0.32
            fade.colors = [0.78, 0.58, 0.34, 0.15, 0.045, 0].map { UIColor(white: 1, alpha: $0).cgColor }
            fade.locations = [0, 0.22, 0.50, 0.72, 0.88, 1]
            layer.mask = fade
        }

        required init?(coder _: NSCoder) {
            nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                previousSize = bounds.size
                clear()
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fade.frame = bounds
            CATransaction.commit()
        }

        func display(_ buffer: CVPixelBuffer) {
            guard bounds.width > 0, bounds.height > 0, window != nil else { return }
            let scale = min(1.5, window?.screen.scale ?? 1)
            let size = CGSize(width: max(2, (bounds.width * scale).rounded()), height: max(2, (bounds.height * scale).rounded()))
            pending = Frame(buffer: buffer, size: size, scale: scale, generation: generation)
            renderNext()
        }

        func clear() {
            generation = UUID()
            pending = nil
            layer.contents = nil
        }

        private func renderNext() {
            guard !rendering, let frame = pending else { return }
            pending = nil
            rendering = true
            let renderer = renderer
            renderer.queue.async { [weak self] in
                let image = autoreleasepool { renderer.render(frame) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    rendering = false
                    if frame.generation == generation, window != nil {
                        present(image)
                    }
                    renderNext()
                }
            }
        }

        private func present(_ image: CGImage?) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
    }
}

/// Production image mapping, shared with the pixel regressions. The overlap has
/// the exact video scale; only the bottommost pixels extend beyond the frame.
enum ArtworkVideoTransitionImage {
    static func image(source: CIImage, videoSize: CGSize, surfaceSize: CGSize,
                      outputSize: CGSize, blurRadius: CGFloat = AMLLImmersiveArtworkGeometry.maximumBlur) -> CIImage?
    {
        guard source.extent.width > 0, source.extent.height > 0,
              videoSize.width > 0, videoSize.height > 0,
              surfaceSize.width > 0, surfaceSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else { return nil }
        let pixelScaleX = outputSize.width / surfaceSize.width
        let pixelScaleY = outputSize.height / surfaceSize.height
        let horizontalExtension = max(0, (surfaceSize.width - videoSize.width) / 2) * pixelScaleX
        let overlap = videoSize.height * AMLLImmersiveArtworkGeometry.overlapFraction
        let extensionHeight = max(0, surfaceSize.height - overlap) * pixelScaleY
        let image = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: videoSize.width * pixelScaleX / source.extent.width,
                                               y: videoSize.height * pixelScaleY / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: horizontalExtension, y: extensionHeight))
            .clampedToExtent()
        let output = CGRect(origin: .zero, size: outputSize)
        guard blurRadius > 0 else { return image.cropped(to: output) }
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: outputSize.height),
            "inputPoint1": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])?.outputImage
        guard let mask else { return nil }
        return image.applyingFilter("CIMaskedVariableBlur", parameters: [
            kCIInputRadiusKey: blurRadius * outputSize.width / surfaceSize.width,
            "inputMask": mask,
        ]).cropped(to: output)
    }
}

/// Uses the same silent player's frame output as the optional reflection.
/// Sits underneath the fading full video, so neither layer has a visible cut edge.
struct ArtworkVideoTransition: UIViewRepresentable {
    let frames: ArtworkReflectionFrames
    let videoSize: CGSize

    func makeUIView(context _: Context) -> Surface {
        let view = Surface()
        view.configure(videoSize: videoSize)
        frames.transitionSurface = view
        return view
    }

    func updateUIView(_ view: Surface, context _: Context) {
        view.configure(videoSize: videoSize)
        frames.transitionSurface = view
    }

    static func dismantleUIView(_ view: Surface, coordinator _: ()) {
        view.clear()
    }

    final class Surface: UIView {
        private struct Frame: @unchecked Sendable {
            let buffer: CVPixelBuffer
            let size: CGSize
            let surfaceSize: CGSize
            let videoSize: CGSize
            let generation: UUID
        }

        private final class Renderer: @unchecked Sendable {
            let queue = DispatchQueue(label: "AMLL.artwork.transition", qos: .userInitiated)
            let context = CIContext(options: [.cacheIntermediates: false])

            func render(_ frame: Frame) -> CGImage? {
                guard let image = ArtworkVideoTransitionImage.image(source: CIImage(cvPixelBuffer: frame.buffer),
                                                                    videoSize: frame.videoSize, surfaceSize: frame.surfaceSize, outputSize: frame.size)
                else { return nil }
                return context.createCGImage(image, from: CGRect(origin: .zero, size: frame.size))
            }
        }

        private let renderer = Renderer()
        private let fade = CAGradientLayer()
        private var generation = UUID()
        private var rendering = false
        private var pending: Frame?
        private var previousSize = CGSize.zero
        private var videoSize = CGSize.zero
        private var lastBuffer: CVPixelBuffer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            fade.colors = AMLLImmersiveArtworkGeometry.transitionFadeStops.map {
                UIColor(white: 1, alpha: CGFloat($0.alpha)).cgColor
            }
            fade.locations = AMLLImmersiveArtworkGeometry.transitionFadeStops.map { NSNumber(value: $0.location) }
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
            if previousSize != bounds.size {
                previousSize = bounds.size
                invalidateGeometry()
            }
        }

        func configure(videoSize: CGSize) {
            guard self.videoSize != videoSize else { return }
            self.videoSize = videoSize
            invalidateGeometry()
        }

        func display(_ buffer: CVPixelBuffer) {
            lastBuffer = buffer
            guard bounds.width > 0, bounds.height > 0, window != nil,
                  videoSize.width > 0, videoSize.height > 0 else { return }
            let scale = min(1.5, window?.screen.scale ?? 1)
            let size = CGSize(width: max(2, (bounds.width * scale).rounded()),
                              height: max(2, (bounds.height * scale).rounded()))
            pending = Frame(buffer: buffer, size: size, surfaceSize: bounds.size,
                            videoSize: videoSize, generation: generation)
            renderNext()
        }

        func clear() {
            generation = UUID()
            pending = nil
            lastBuffer = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.contents = nil
            CATransaction.commit()
        }

        private func invalidateGeometry() {
            generation = UUID()
            pending = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.contents = nil
            CATransaction.commit()
            if let lastBuffer {
                display(lastBuffer)
            }
        }

        private func renderNext() {
            guard !rendering, let frame = pending else { return }
            pending = nil
            rendering = true
            let renderer = renderer
            renderer.queue.async { [weak self] in
                let image = autoreleasepool { renderer.render(frame) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    rendering = false
                    if frame.generation == generation, window != nil {
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        layer.contents = image
                        CATransaction.commit()
                    }
                    renderNext()
                }
            }
        }
    }
}
