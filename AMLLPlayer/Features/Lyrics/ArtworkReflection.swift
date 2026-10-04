import CoreImage
import SwiftUI

/// A presentation's order is allocated once, never on an ordinary view update.
struct ArtworkFramePresentation: Equatable {
    fileprivate let order: UInt64
    fileprivate let id: UUID
}

/// Frame handoff from the existing silent video; reflection never creates a second player.
@MainActor final class ArtworkReflectionFrames {
    weak var surface: ArtworkReflection.Surface?
    weak var transitionSurface: ArtworkVideoTransition.Surface?
    private var source: UUID?
    private var presentation: ArtworkFramePresentation?
    private var nextPresentationOrder: UInt64 = 0
    private var resource: UUID?
    private var lastBuffer: CVPixelBuffer?
    private(set) var receivedFrames = 0
    private(set) var acquiredFrames = 0
    var outputAttached = false
    var outputKind = "item 级（BGRA）"
    var samplingAttempts = 0
    var mediaTime = 0.0
    var mediaRate: Float = 0
    var videoDisplayed = false
    var resourceKind = ""
    var producerIdentifier: UUID?
    var primaryFrameReady = false
    var producerSource: UUID?
    var pageDiagnostic = "页面资源状态：尚未记录"
    private var lifecycleEvents: [String] = []
    var producerBindingValid: Bool { producerSource.map { accepts(source: $0) } ?? false }
    private var producerDiagnostic: String {
        "播放器实例：\(producerIdentifier.map { String($0.uuidString.prefix(8)) } ?? "未配置")；主视频首帧：\(primaryFrameReady ? "已就绪" : "等待")；倒影帧绑定：\(producerBindingValid ? "有效" : "等待配置恢复")"
    }
    var outputStarvationSeconds = 0.0
    var frameOutputSwitches = 0
    private(set) var rejectedFrames = 0
    private(set) var rejectionReason = "无"
    weak var liveBlurSurface: ImmersiveLiveBlurSurface?
    var blurInputs: [String] = []
    var blurWaitingForVideoFrame = false
    var blurLayoutDiagnostic = ""
    var layoutDiagnostic = "尚未安装沉浸画布"
    var hasFrame: Bool { lastBuffer != nil }
    /// Immutable current frame for the visible-plane blur compositor.
    var currentBuffer: CVPixelBuffer? { lastBuffer }
    var sessionDiagnostic: String {
        "呈现实例：\(presentation.map { String($0.id.uuidString.prefix(8)) } ?? "独立")；资源代次：\(resource.map { String($0.uuidString.prefix(8)) } ?? "无")；帧来源：\(source.map { String($0.uuidString.prefix(8)) } ?? "已结束")；拒绝原因：\(rejectionReason)"
    }
    var diagnosticText: String {
        let commit = Bundle.main.object(forInfoDictionaryKey: "AMLLBuildCommit") as? String ?? "local"
        return "动态封面构建：\(commit.prefix(8))；倒影链路：4\n\(pageDiagnostic)\n\(producerDiagnostic)\n\(frameDiagnosticText)\n视图生命周期：\(lifecycleEvents.isEmpty ? "无" : lifecycleEvents.joined(separator: " → "))"
    }
    private var frameDiagnosticText: String {
        "取帧输出：\(outputAttached ? "已接入" : "未接入")；取得像素帧：\(acquiredFrames)；接受帧：\(receivedFrames)；倒影提交：\(surface?.presentedFrames ?? 0)\n输出类型：\(outputKind)；采样次数：\(samplingAttempts)\n无像素帧累计：\(String(format: "%.2f", outputStarvationSeconds)) s；备用切换：\(frameOutputSwitches)；来源不匹配：\(rejectedFrames)\n\(sessionDiagnostic)\n媒体时间：\(String(format: "%.2f", mediaTime)) s；速率：\(mediaRate)；视频已显示：\(videoDisplayed ? "是" : "否")；资源：\(resourceKind)\n倒影图像：\(surface?.layer.contents != nil ? "有" : "无")\n模糊提交：\(liveBlurSurface?.presentedFrames ?? 0)；模糊输入：\(blurInputs.isEmpty ? "无" : blurInputs.joined(separator: "、"))；等待视频像素：\(blurWaitingForVideoFrame ? "是" : "否")\n\(blurLayoutDiagnostic)\n\(layoutDiagnostic)"
    }

    func makePresentation() -> ArtworkFramePresentation {
        nextPresentationOrder += 1
        return .init(order: nextPresentationOrder, id: UUID())
    }

    /// Retain a bounded history across teardown, without URLs or account data.
    func recordLifecycle(_ event: String, presentation owner: ArtworkFramePresentation) {
        lifecycleEvents.append("\(owner.id.uuidString.prefix(8))：\(event)")
        if lifecycleEvents.count > 8 { lifecycleEvents.removeFirst(lifecycleEvents.count - 8) }
    }

    /// Late updates/dismantles of an older SwiftUI surface cannot retake the
    /// session. The producer and both receiving planes share this ownership.
    func activate(_ next: ArtworkFramePresentation, reflection: ArtworkReflection.Surface,
                  blur: ImmersiveLiveBlurSurface) -> Bool {
        guard presentation.map({ next.order >= $0.order }) ?? true else { return false }
        if presentation != next {
            recordLifecycle("接管当前呈现", presentation: next)
            clear(source: source)
            resetProducerDiagnostics()
            presentation = next
        }
        attach(reflection)
        liveBlurSurface = blur
        return true
    }

    func ownsPresentation(_ owner: ArtworkFramePresentation) -> Bool { presentation == owner }

    func accepts(source token: UUID) -> Bool { source == token }

    func begin(presentation owner: ArtworkFramePresentation, resource: UUID) -> UUID? {
        guard ownsPresentation(owner) else { return nil }
        let token = begin()
        self.resource = resource
        return token
    }

    func release(_ owner: ArtworkFramePresentation) {
        guard ownsPresentation(owner) else { return }
        recordLifecycle("释放当前呈现", presentation: owner)
        clear(source: source)
        surface = nil
        transitionSurface = nil
        liveBlurSurface = nil
        resetProducerDiagnostics()
        // Retain the highest presentation order so retired views stay retired.
    }

    private func resetProducerDiagnostics() {
        producerIdentifier = nil
        producerSource = nil
        primaryFrameReady = false
        mediaTime = 0
        mediaRate = 0
        videoDisplayed = false
        resourceKind = ""
    }

    func attach(_ view: ArtworkReflection.Surface) {
        guard surface !== view else { return }
        surface = view
        if let lastBuffer { view.display(lastBuffer) }
    }

    func attach(_ view: ArtworkVideoTransition.Surface) {
        guard transitionSurface !== view else { return }
        transitionSurface = view
        if let lastBuffer { view.display(lastBuffer) }
    }

    func replayLatest() {
        guard let lastBuffer else { return }
        surface?.display(lastBuffer)
        transitionSurface?.display(lastBuffer)
    }

    func begin() -> UUID {
        let token = UUID()
        source = token
        resource = nil
        lastBuffer = nil
        receivedFrames = 0
        acquiredFrames = 0
        samplingAttempts = 0
        outputKind = "item 级（BGRA）"
        outputStarvationSeconds = 0; frameOutputSwitches = 0; rejectedFrames = 0
        rejectionReason = "无"
        blurInputs = []; blurWaitingForVideoFrame = false
        surface?.clear()
        transitionSurface?.clear()
        liveBlurSurface?.discardComposition()
        return token
    }

    @discardableResult func display(_ buffer: CVPixelBuffer, source token: UUID) -> Bool {
        acquiredFrames += 1
        guard accepts(source: token) else {
            rejectedFrames += 1
            rejectionReason = source == nil ? "当前会话已结束" : "帧来源与当前会话不匹配"
            return false
        }
        receivedFrames += 1
        lastBuffer = buffer
        surface?.display(buffer)
        transitionSurface?.display(buffer)
        return true
    }

    func clear(source token: UUID?) {
        guard token == source else { return }
        source = nil
        outputAttached = false
        lastBuffer = nil
        surface?.clear()
        transitionSurface?.clear()
        liveBlurSurface?.discardComposition()
    }
}

enum ArtworkReflectionGeometry {
    static func frame(cover: CGRect, viewportHeight: CGFloat) -> CGRect {
        CGRect(x: cover.minX, y: cover.maxY, width: cover.width,
               height: max(220, min(viewportHeight * 0.30, 340)))
    }
}

/// Same spatial mapping in the visible reflection and the blur's input composite.
/// No separate Gaussian blur is applied to this media plane.
enum ArtworkReflectionImage {
    static let opacity: Float = 0.32
    static let fadeStops: [(location: Double, alpha: Double)] = [
        (0, 0), (0.04, 0.20), (0.12, 0.78), (0.22, 0.58), (0.50, 0.34), (0.72, 0.15), (0.88, 0.045), (1, 0),
    ]

    static func image(source: CIImage, outputSize: CGSize) -> CIImage {
        let height = max(2, (source.extent.height * 0.24).rounded())
        let crop = CGRect(x: source.extent.minX, y: source.extent.minY, width: source.extent.width, height: height)
        return source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
            .transformed(by: CGAffineTransform(scaleX: outputSize.width / crop.width, y: outputSize.height / height))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    static func alphaMask(size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        var mask = CIImage(color: .clear).cropped(to: rect)
        for index in 1 ..< fadeStops.count {
            let previous = fadeStops[index - 1]
            let next = fadeStops[index]
            let lower = (1 - next.location) * size.height
            let upper = (1 - previous.location) * size.height
            guard let segment = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: lower), "inputPoint1": CIVector(x: 0, y: upper),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(next.alpha)),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(previous.alpha)),
            ])?.outputImage else { continue }
            mask = segment.cropped(to: CGRect(x: 0, y: lower, width: size.width, height: upper - lower)).composited(over: mask)
        }
        return mask.cropped(to: rect)
    }
}

struct ArtworkTransitionComposition: Equatable, Sendable {
    let video: CGRect
    let reflection: CGRect
    let transition: CGRect
    let reflectionEnabled: Bool
    let reflectionOpacity: Double
    let blurRadius: Double
}

struct ArtworkReflection: UIViewRepresentable {
    let frames: ArtworkReflectionFrames
    var opacity: Double = 0.32

    func makeUIView(context _: Context) -> Surface {
        let view = Surface()
        view.configure(opacity: opacity)
        frames.attach(view)
        return view
    }

    func updateUIView(_ view: Surface, context _: Context) {
        view.configure(opacity: opacity)
        frames.attach(view)
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
        private var lastBuffer: CVPixelBuffer?
        private(set) var presentedFrames = 0
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
                let image = ArtworkReflectionImage.image(source: CIImage(cvPixelBuffer: frame.buffer), outputSize: frame.size)
                return context.createCGImage(image, from: CGRect(origin: .zero, size: frame.size))
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            layer.opacity = ArtworkReflectionImage.opacity
            // Enter from zero at the video edge; the softening layer above
            // cannot hide a reflection that starts with a nonzero alpha step.
            fade.colors = ArtworkReflectionImage.fadeStops.map { UIColor(white: 1, alpha: CGFloat($0.alpha)).cgColor }
            fade.locations = ArtworkReflectionImage.fadeStops.map { NSNumber(value: $0.location) }
            layer.mask = fade
        }

        required init?(coder _: NSCoder) {
            nil
        }

        func configure(opacity: Double) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.opacity = Float(min(1, max(0, opacity)))
            CATransaction.commit()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let lastBuffer { display(lastBuffer) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                previousSize = bounds.size
                generation = UUID()
                pending = nil
                layer.contents = nil
                if let lastBuffer { display(lastBuffer) }
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fade.frame = bounds
            CATransaction.commit()
        }

        func display(_ buffer: CVPixelBuffer) {
            lastBuffer = buffer
            guard bounds.width > 0, bounds.height > 0, window != nil, !isHidden else { return }
            let scale = min(1.5, window?.screen.scale ?? 1)
            let size = CGSize(width: max(2, (bounds.width * scale).rounded()), height: max(2, (bounds.height * scale).rounded()))
            pending = Frame(buffer: buffer, size: size, scale: scale, generation: generation)
            renderNext()
        }

        func clear() {
            generation = UUID()
            pending = nil
            lastBuffer = nil
            presentedFrames = 0
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
            if image != nil { presentedFrames += 1 }
            CATransaction.commit()
        }
    }
}

/// Production image mapping, shared with the pixel regressions. The overlap has
/// the exact video scale; only the bottommost pixels extend beyond the frame.
enum ArtworkVideoTransitionImage {
    static func image(source: CIImage, videoSize: CGSize, surfaceSize: CGSize,
                      outputSize: CGSize, blurRadius: CGFloat = AMLLImmersiveArtworkGeometry.maximumBlur,
                      composition: ArtworkTransitionComposition? = nil) -> CIImage?
    {
        guard source.extent.width > 0, source.extent.height > 0,
              videoSize.width > 0, videoSize.height > 0,
              surfaceSize.width > 0, surfaceSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else { return nil }
        let pixelScaleX = outputSize.width / surfaceSize.width
        let pixelScaleY = outputSize.height / surfaceSize.height
        let horizontalExtension = (composition.map { $0.video.minX - $0.transition.minX }
            ?? max(0, (surfaceSize.width - videoSize.width) / 2)) * pixelScaleX
        let overlap = composition.map { $0.video.maxY - $0.transition.minY }
            ?? AMLLImmersiveArtworkGeometry.transitionHalfHeight(videoHeight: videoSize.height)
        let extensionHeight = (surfaceSize.height - overlap) * pixelScaleY
        var image = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: videoSize.width * pixelScaleX / source.extent.width,
                                               y: videoSize.height * pixelScaleY / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: horizontalExtension, y: extensionHeight))
            .clampedToExtent()
        let output = CGRect(origin: .zero, size: outputSize)
        if let composition, composition.reflectionEnabled, composition.reflection.width > 0, composition.reflection.height > 0 {
            let reflectedSize = CGSize(width: composition.reflection.width * pixelScaleX, height: composition.reflection.height * pixelScaleY)
            let reflected = ArtworkReflectionImage.image(source: source, outputSize: reflectedSize)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear),
                    kCIInputMaskImageKey: ArtworkReflectionImage.alphaMask(size: reflectedSize),
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(composition.reflectionOpacity)),
                ])
                .transformed(by: CGAffineTransform(translationX: (composition.reflection.minX - composition.transition.minX) * pixelScaleX,
                    y: (composition.transition.maxY - composition.reflection.maxY) * pixelScaleY))
            image = reflected.composited(over: image)
        }
        guard blurRadius > 0 else { return image.cropped(to: output) }
        let upperRamp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: outputSize.height),
            "inputPoint1": CIVector(x: 0, y: outputSize.height - max(1, overlap * pixelScaleY)),
            "inputColor0": CIColor.black,
            "inputColor1": CIColor.white,
        ])?.outputImage
        guard let mask = upperRamp?.cropped(to: output) else { return nil }
        return image.applyingFilter("CIMaskedVariableBlur", parameters: [
            kCIInputRadiusKey: blurRadius * outputSize.width / surfaceSize.width,
            "inputMask": mask,
        ]).cropped(to: output)
    }
}

/// Uses the same silent player's frame output as the optional reflection.
/// Above video and reflection. Its input includes the same reflection before blurring.
struct ArtworkVideoTransition: UIViewRepresentable {
    let frames: ArtworkReflectionFrames
    let videoSize: CGSize
    var composition: ArtworkTransitionComposition? = nil

    func makeUIView(context _: Context) -> Surface {
        let view = Surface()
        view.configure(videoSize: videoSize, composition: composition)
        frames.attach(view)
        return view
    }

    func updateUIView(_ view: Surface, context _: Context) {
        view.configure(videoSize: videoSize, composition: composition)
        frames.attach(view)
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
            let composition: ArtworkTransitionComposition?
        }

        private final class Renderer: @unchecked Sendable {
            let queue = DispatchQueue(label: "AMLL.artwork.transition", qos: .userInitiated)
            let context = CIContext(options: [.cacheIntermediates: false])

            func render(_ frame: Frame) -> CGImage? {
                guard let image = ArtworkVideoTransitionImage.image(source: CIImage(cvPixelBuffer: frame.buffer),
                                                                    videoSize: frame.videoSize, surfaceSize: frame.surfaceSize, outputSize: frame.size,
                                                                    blurRadius: CGFloat(frame.composition?.blurRadius ?? 32), composition: frame.composition)
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
        private var composition: ArtworkTransitionComposition?
        private var lastBuffer: CVPixelBuffer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            layer.mask = fade
        }

        required init?(coder _: NSCoder) {
            nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fade.frame = bounds
            updateFade()
            CATransaction.commit()
            if previousSize != bounds.size {
                previousSize = bounds.size
                invalidateGeometry()
            }
        }

        func configure(videoSize: CGSize, composition: ArtworkTransitionComposition? = nil) {
            guard self.videoSize != videoSize || self.composition != composition else { return }
            self.videoSize = videoSize
            self.composition = composition
            CATransaction.begin(); CATransaction.setDisableActions(true)
            updateFade()
            CATransaction.commit()
            invalidateGeometry()
        }

        private func updateFade() {
            let overlap = composition.map { $0.video.maxY - $0.transition.minY }
                ?? AMLLImmersiveArtworkGeometry.transitionHalfHeight(videoHeight: videoSize.height)
            let stops = AMLLImmersiveArtworkGeometry.transitionFadeStops(solidStart: Double(max(1, overlap) / max(1, bounds.height)))
            fade.colors = stops.map { UIColor(white: 1, alpha: CGFloat($0.alpha)).cgColor }
            fade.locations = stops.map { NSNumber(value: $0.location) }
        }

        func display(_ buffer: CVPixelBuffer) {
            lastBuffer = buffer
            guard bounds.width > 0, bounds.height > 0, window != nil, !isHidden,
                  videoSize.width > 0, videoSize.height > 0 else { return }
            let scale = min(1.5, window?.screen.scale ?? 1)
            let size = CGSize(width: max(2, (bounds.width * scale).rounded()),
                              height: max(2, (bounds.height * scale).rounded()))
            pending = Frame(buffer: buffer, size: size, surfaceSize: bounds.size,
                            videoSize: videoSize, generation: generation, composition: composition)
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
