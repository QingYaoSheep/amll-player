import CoreImage
import UIKit

/// Immutable, bounded snapshot of only the currently visible lower planes.
/// Pixels are never read or modified concurrently with the main actor.
struct ImmersiveBlurInput: @unchecked Sendable {
    enum Plane {
        case bitmap(CGImage)
        case video(CVPixelBuffer, frame: CGRect, mask: CGImage?, opacity: Double)
    }
    let region: CGRect
    let profile: ImmersiveBackgroundBlurProfile
    var transition: CGRect { profile.frame }
    let scale: CGFloat
    let planes: [Plane]
}

/// Pure Gaussian backdrop softening. Unlike a system material this does not
/// change color, saturation, or darkening. Only the filter radius ramps through
/// the upward extension; it does not apply an image-opacity fade. Below the
/// junction it remains fully blurred.
enum ImmersiveBlurImage {
    static func image(_ input: ImmersiveBlurInput, radius: CGFloat) -> CIImage {
        let size = CGSize(width: input.region.width * input.scale, height: input.region.height * input.scale)
        let extent = CGRect(origin: .zero, size: size)
        var image = CIImage(color: .clear).cropped(to: extent)
        for plane in input.planes {
            switch plane {
            case let .bitmap(bitmap):
                image = CIImage(cgImage: bitmap).composited(over: image)
            case let .video(buffer, frame, mask, opacity):
                let source = CIImage(cvPixelBuffer: buffer)
                let localSize = CGSize(width: frame.width * input.scale, height: frame.height * input.scale)
                let rect = CGRect(origin: .zero, size: localSize)
                let fitted = AMLLImmersiveArtworkGeometry.fittedFrame(container: rect, source: source.extent.size)
                var video = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: fitted.width / source.extent.width, y: fitted.height / source.extent.height))
                    .transformed(by: CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
                    .composited(over: CIImage(color: .clear).cropped(to: rect))
                if let mask {
                    let alpha = CIImage(cgImage: mask).transformed(by: CGAffineTransform(
                        scaleX: localSize.width / CGFloat(mask.width), y: localSize.height / CGFloat(mask.height)))
                    video = video.applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: .clear), kCIInputMaskImageKey: alpha,
                    ])
                }
                video = video.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
                ]).cropped(to: rect).transformed(by: CGAffineTransform(
                    translationX: (frame.minX - input.region.minX) * input.scale,
                    y: (input.region.maxY - frame.maxY) * input.scale))
                image = video.composited(over: image)
            }
        }
        let output = CGRect(x: (input.transition.minX - input.region.minX) * input.scale,
            y: (input.region.maxY - input.transition.maxY) * input.scale,
            width: input.transition.width * input.scale, height: input.transition.height * input.scale)
        guard radius > 0 else { return image.cropped(to: output) }
        let fadeHeight = max(0, min(input.transition.maxY, input.profile.fullStrengthY) - input.transition.minY) * input.scale
        let ramp: CIImage
        if fadeHeight > 0 {
            ramp = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: output.maxY),
                "inputPoint1": CIVector(x: 0, y: output.maxY - fadeHeight),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white,
            ])!.outputImage!
        } else {
            ramp = CIImage(color: .white)
        }
        // This grayscale mask controls filter radius only, never image alpha.
        let mask = ramp.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
            "inputGreenCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
            "inputBlueCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
        ]).cropped(to: extent)
        return image.cropped(to: extent).clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: [
                kCIInputRadiusKey: radius * input.scale, "inputMask": mask,
            ]).cropped(to: output)
    }
}

/// One 30Hz sampling loop, one serial CI worker, at most one in-flight image.
/// Busy ticks are coalesced: they do not queue obsolete backdrop snapshots.
@MainActor
final class ImmersiveLiveBlurSurface: UIView {
    var capture: (() -> ImmersiveBlurInput?)?
    private(set) var amount = 0.0
    private(set) var presentedFrames = 0
    private var generation = UUID()
    private var rendering = false
    private var displayLink: CADisplayLink?
    private let renderer = Renderer()

    private final class Renderer: @unchecked Sendable {
        let queue = DispatchQueue(label: "AMLL.artwork.live-blur", qos: .userInitiated)
        let context = CIContext(options: [.cacheIntermediates: false])
        func render(_ input: ImmersiveBlurInput, radius: CGFloat) -> CGImage? {
            let image = ImmersiveBlurImage.image(input, radius: radius)
            return context.createCGImage(image, from: image.extent)
        }
    }

    @MainActor private final class TickTarget: NSObject {
        weak var surface: ImmersiveLiveBlurSurface?
        init(_ surface: ImmersiveLiveBlurSurface) { self.surface = surface }
        @objc func tick(_ link: CADisplayLink) {
            if let surface { surface.sample() } else { link.invalidate() }
        }
    }

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.contentsGravity = .resize
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
        }
    }
    required init?(coder _: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func applicationChanged(_: Notification) { updateScheduler() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        generation = UUID()
        layer.contents = nil
        updateScheduler()
    }

    func configure(amount: Double, mask: UIView?) {
        self.amount = amount.isFinite ? min(1, max(0, amount)) : 0
        // Discard old composition on hide/reorder/resize/strength changes, even paused.
        discardComposition()
        self.mask = mask
        alpha = 1
        updateScheduler()
    }

    /// Invalidate both the displayed image and an in-flight snapshot when the
    /// visible video has no pixels for its current resource generation.
    func discardComposition() {
        generation = UUID()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = nil
        CATransaction.commit()
    }

    private func updateScheduler() {
        let active = window != nil && !isHidden && amount > 0 && UIApplication.shared.applicationState == .active
        if active, displayLink == nil {
            let link = CADisplayLink(target: TickTarget(self), selector: #selector(TickTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !active {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func sample() {
        guard !rendering, !isHidden, window != nil, amount > 0,
              UIApplication.shared.applicationState == .active, let input = capture?() else { return }
        rendering = true
        let token = generation
        let radius = CGFloat(amount * 80)
        let renderer = renderer
        renderer.queue.async { [weak self] in
            let image = autoreleasepool { renderer.render(input, radius: radius) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                rendering = false
                guard token == generation, window != nil, !isHidden else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.contents = image
                layer.contentsScale = input.scale
                if image != nil { presentedFrames += 1 }
                CATransaction.commit()
            }
        }
    }

    func stop() {
        generation = UUID()
        amount = 0
        displayLink?.invalidate()
        displayLink = nil
        capture = nil
        layer.contents = nil
        mask = nil
    }
}
