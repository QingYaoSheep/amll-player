import CoreImage
import Metal
import QuartzCore
import UIKit

/// Immutable, bounded snapshot of only the currently visible lower planes.
/// Pixels are never read or modified concurrently with the main actor.
struct ImmersiveBlurInput: @unchecked Sendable {
    enum Plane {
        case bitmap(CGImage)
        case solid(CIColor, frame: CGRect)
        case video(CVPixelBuffer, frame: CGRect, mask: CGImage?, opacity: Double)
        case reflection(CVPixelBuffer, frame: CGRect, mask: CGImage?, opacity: Double)
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
            case let .solid(color, frame):
                let rect = CGRect(x: (frame.minX - input.region.minX) * input.scale,
                    y: (input.region.maxY - frame.maxY) * input.scale,
                    width: frame.width * input.scale, height: frame.height * input.scale)
                image = CIImage(color: color).cropped(to: rect).composited(over: image)
            case let .video(buffer, frame, mask, opacity), let .reflection(buffer, frame, mask, opacity):
                let source = CIImage(cvPixelBuffer: buffer)
                let localSize = CGSize(width: frame.width * input.scale, height: frame.height * input.scale)
                let rect = CGRect(origin: .zero, size: localSize)
                let fitted = AMLLImmersiveArtworkGeometry.fittedFrame(container: rect, source: source.extent.size)
                var video: CIImage
                if case .reflection = plane {
                    video = ArtworkReflectionImage.image(source: source, outputSize: localSize)
                        .applyingFilter("CIBlendWithAlphaMask", parameters: [
                            kCIInputBackgroundImageKey: CIImage(color: .clear),
                            kCIInputMaskImageKey: ArtworkReflectionImage.alphaMask(size: localSize),
                        ])
                } else {
                    video = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: fitted.width / source.extent.width, y: fitted.height / source.extent.height))
                    .transformed(by: CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
                    .composited(over: CIImage(color: .clear).cropped(to: rect))
                }
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

/// The backdrop is encoded directly into a Metal drawable. No video-sized
/// CGImage is read back to the CPU or returned through the main actor.
/// At most two submissions are in flight; busy ticks do not queue old inputs.
@MainActor
final class ImmersiveLiveBlurSurface: UIView {
    var capture: (() -> ImmersiveBlurInput?)?
    private(set) var amount = 0.0
    private(set) var presentedFrames = 0
    private var generation = UUID()
    private var inFlight = 0
    private var hasOutput = false
    private var displayLink: CADisplayLink?
    private let renderer = Renderer()
    private let outputView = OutputView()
    private var submitted: [UUID: any MTLCommandBuffer] = [:]
    private var renderingAllowed = true
    private var captureOutput = false
    private(set) var capturedOutput: CGImage?
    private var inputAges: [Double] = []
    private var gpuTimes: [Double] = []
    private var captureTimes: [Double] = []
    private var presentationTimes: [CFTimeInterval] = []
    private(set) var maximumInFlight = 0
    private(set) var gpuPresentedFrames = 0
    var hasRenderedOutput: Bool { hasOutput }
    var preferredRefreshRate: Float? { displayLink?.preferredFrameRateRange.preferred }
    var diagnosticText: String {
        func p95(_ samples: [Double]) -> Double {
            let sorted = samples.sorted()
            return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        }
        let duration = (presentationTimes.last ?? 0) - (presentationTimes.first ?? 0)
        let fps = duration > 0 ? Double(presentationTimes.count - 1) / duration : 0
        return String(format: "模糊输出：%@；FPS：%.1f；采样 P95：%.2f ms；GPU P95：%.2f ms；帧龄 P95：%.2f ms；在途：%d/2",
            renderer.device == nil ? "图像回退" : "Metal 直出", fps, p95(captureTimes), p95(gpuTimes), p95(inputAges), inFlight)
    }

    private final class OutputView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    }

    private struct Submission: @unchecked Sendable {
        let id = UUID()
        let input: ImmersiveBlurInput
        let command: any MTLCommandBuffer
        let drawable: any CAMetalDrawable
        let readback: Readback?
    }

    /// Allocated only by an explicit test export; ordinary display has no readback.
    private struct Readback: @unchecked Sendable {
        let buffer: any MTLBuffer
        let width: Int
        let height: Int
        let rowBytes: Int
        func image() -> CGImage? {
            let data = Data(bytes: buffer.contents(), count: rowBytes * height)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// Only nextDrawable is accessed by the serial worker; layer geometry and
    /// visibility remain on the main actor.
    private final class DrawableSource: @unchecked Sendable {
        let layer: CAMetalLayer
        init(_ layer: CAMetalLayer) { self.layer = layer }
        func next() -> (any CAMetalDrawable)? { layer.nextDrawable() }
    }

    private final class Renderer: @unchecked Sendable {
        let queue = DispatchQueue(label: "AMLL.artwork.live-blur", qos: .userInitiated)
        let device: (any MTLDevice)?
        let commandQueue: (any MTLCommandQueue)?
        let context: CIContext
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            commandQueue = device?.makeCommandQueue()
            // Core Animation's SDR alpha compositing is in display-encoded
            // sRGB. Linear-light blending makes the zero-blur clone brighter.
            let options: [CIContextOption: Any] = [
                .cacheIntermediates: true, .workingColorSpace: colorSpace,
            ]
            context = device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
        }
        func render(_ input: ImmersiveBlurInput, radius: CGFloat) -> CGImage? {
            let image = ImmersiveBlurImage.image(input, radius: radius)
            return context.createCGImage(image, from: image.extent)
        }
        func encode(_ input: ImmersiveBlurInput, radius: CGFloat, destination: DrawableSource,
                    captureOutput: Bool) -> Submission? {
            guard let commandQueue, let command = commandQueue.makeCommandBuffer(),
                  let drawable = destination.next() else { return nil }
            let image = ImmersiveBlurImage.image(input, radius: radius)
            let width = CGFloat(drawable.texture.width), height = CGFloat(drawable.texture.height)
            guard abs(image.extent.width - width) <= 1, abs(image.extent.height - height) <= 1 else { return nil }
            // Core Image uses bottom-left image coordinates; a CA drawable
            // stores its first row at the visible top.
            let mapped = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
            context.render(mapped, to: drawable.texture, commandBuffer: command,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
            var readback: Readback?
            if captureOutput, let device {
                let rowBytes = (drawable.texture.width * 4 + 255) / 256 * 256
                if let buffer = device.makeBuffer(length: rowBytes * drawable.texture.height,
                    options: .storageModeShared), let blit = command.makeBlitCommandEncoder() {
                    blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: drawable.texture.width, height: drawable.texture.height, depth: 1),
                        to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                        destinationBytesPerImage: rowBytes * drawable.texture.height)
                    blit.endEncoding()
                    readback = Readback(buffer: buffer, width: drawable.texture.width,
                        height: drawable.texture.height, rowBytes: rowBytes)
                }
            }
            return Submission(input: input, command: command, drawable: drawable, readback: readback)
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
        outputView.isOpaque = false
        outputView.backgroundColor = .clear
        outputView.layer.opacity = 0
        let target = outputView.metalLayer
        target.device = renderer.device
        target.pixelFormat = .bgra8Unorm
        target.colorspace = renderer.colorSpace
        target.framebufferOnly = false
        target.isOpaque = false
        target.maximumDrawableCount = 2
        target.allowsNextDrawableTimeout = true
        addSubview(outputView)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
        }
    }
    required init?(coder _: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func applicationChanged(_ notification: Notification) {
        renderingAllowed = notification.name == UIApplication.didBecomeActiveNotification
        if !renderingAllowed {
            // Prevent queued encodes from committing after deactivation, and
            // ensure already committed work is scheduled before backgrounding.
            generation = UUID()
            for command in submitted.values { command.waitUntilScheduled() }
        }
        updateScheduler()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        discardComposition()
        updateScheduler()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(1.5, window?.screen.scale ?? 1)
        outputView.frame = bounds
        outputView.metalLayer.contentsScale = scale
        outputView.metalLayer.drawableSize = CGSize(width: max(2, (bounds.width * scale).rounded()),
            height: max(2, (bounds.height * scale).rounded()))
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
        outputView.layer.opacity = 0
        hasOutput = false
        capturedOutput = nil
        CATransaction.commit()
    }

    private func updateScheduler() {
        let active = renderingAllowed && window != nil && !isHidden && amount > 0 && UIApplication.shared.applicationState == .active
        if active, displayLink == nil {
            let link = CADisplayLink(target: TickTarget(self), selector: #selector(TickTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !active {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func sample() {
        guard renderingAllowed, inFlight < 2, !isHidden, window != nil, amount > 0,
              UIApplication.shared.applicationState == .active else { return }
        let timestamp = CACurrentMediaTime()
        guard let input = capture?() else { return }
        captureTimes.append((CACurrentMediaTime() - timestamp) * 1000)
        if captureTimes.count > 120 { captureTimes.removeFirst() }
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        let token = generation
        let radius = CGFloat(amount * 80)
        let renderer = renderer
        let destination = DrawableSource(outputView.metalLayer)
        let export = captureOutput
        captureOutput = false
        renderer.queue.async { [weak self] in
            if renderer.device != nil {
                let submission = autoreleasepool { renderer.encode(input, radius: radius,
                    destination: destination, captureOutput: export) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let submission, token == generation, renderingAllowed,
                          UIApplication.shared.applicationState == .active, window != nil, !isHidden else {
                        inFlight -= 1
                        if token == generation, export { captureOutput = true }
                        return
                    }
                    let id = submission.id
                    let retainedInput = submission.input
                    let readback = submission.readback
                    submitted[id] = submission.command
                    submission.command.addCompletedHandler { [weak self] command in
                        // Hold the immutable buffer/planes until the GPU finishes.
                        _ = retainedInput
                        let gpu = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
                        let success = command.status == .completed
                        let snapshot = success ? readback?.image() : nil
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            inFlight -= 1
                            submitted.removeValue(forKey: id)
                            guard token == generation, renderingAllowed, window != nil, !isHidden, success else { return }
                            hasOutput = true
                            CATransaction.begin(); CATransaction.setDisableActions(true)
                            outputView.layer.opacity = 1
                            CATransaction.commit()
                            if let snapshot { capturedOutput = snapshot }
                            gpuTimes.append(gpu)
                            if gpuTimes.count > 120 { gpuTimes.removeFirst() }
                        }
                    }
                    submission.drawable.addPresentedHandler { [weak self] drawable in
                        let presentedAt = drawable.presentedTime
                        Task { @MainActor [weak self] in
                            guard let self, token == generation, renderingAllowed,
                                  window != nil, !isHidden, presentedAt > 0 else { return }
                            recordPresentation(timestamp: timestamp, presentedAt: presentedAt)
                            gpuPresentedFrames += 1
                        }
                    }
                    submission.command.present(submission.drawable)
                    submission.command.commit()
                }
                return
            }
            let image = autoreleasepool { renderer.render(input, radius: radius) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                inFlight -= 1
                guard token == generation, renderingAllowed, window != nil, !isHidden else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.contents = image
                layer.contentsScale = input.scale
                if image != nil {
                    hasOutput = true
                    presentedFrames += 1
                    if export { capturedOutput = image }
                }
                CATransaction.commit()
            }
        }
    }

    private func recordPresentation(timestamp: CFTimeInterval, presentedAt: CFTimeInterval) {
        hasOutput = true
        presentedFrames += 1
        inputAges.append(max(0, presentedAt - timestamp) * 1000)
        if inputAges.count > 120 { inputAges.removeFirst() }
        presentationTimes.append(presentedAt)
        if presentationTimes.count > 120 { presentationTimes.removeFirst() }
    }

    /// Explicit export for pixel tests/diagnostics only, never used per frame.
    func requestOutputSnapshot() {
        capturedOutput = nil
        captureOutput = true
    }

    func stop() {
        generation = UUID()
        amount = 0
        displayLink?.invalidate()
        displayLink = nil
        capture = nil
        layer.contents = nil
        outputView.layer.opacity = 0
        hasOutput = false
        capturedOutput = nil
        captureOutput = false
        renderer.context.clearCaches()
        mask = nil
    }
}
