import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

struct ImmersiveArtworkFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let presentationTime: CMTime
    let generation: UUID
    var size: CGSize { CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)) }
}

/// Immutable spatial inputs. Video opacity, reflection opacity and blur radius
/// have distinct owners, with no whole-page or duplicated media fade.
struct ImmersiveArtworkComposition: Equatable, Sendable {
    let viewport: CGSize
    let video: CGRect
    let reflection: CGRect
    let profile: ImmersiveBackgroundBlurProfile
    let style: ImmersiveArtworkStyle
    let reflectionEnabled: Bool
    let reduceTransparency: Bool
    let dimming: Double
}

enum ImmersiveArtworkImage {
    private static let videoMasks = ImmersiveVideoMaskCache()
    private static func smoothGradient(size: CGSize, top: CGFloat, bottom: CGFloat) -> CIImage {
        if top <= bottom {
            return CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        }
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: bottom), "inputPoint1": CIVector(x: 0, y: top),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white,
        ])!.outputImage!
        return ramp.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
            "inputGreenCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
            "inputBlueCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
        ]).cropped(to: CGRect(origin: .zero, size: size))
    }

    static func legacyVideoMask(size: CGSize) -> CIImage {
        videoMasks.mask(size: size)
    }

    static func compose(background: CIImage, video source: CIImage?,
                        layout: ImmersiveArtworkComposition, scale: CGFloat) -> CIImage {
        let size = CGSize(width: layout.viewport.width * scale, height: layout.viewport.height * scale)
        let extent = CGRect(origin: .zero, size: size)
        let dark = CGFloat(1 - min(1, max(0, layout.dimming)))
        var image = background.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: dark, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: dark, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: dark, w: 0),
        ]).cropped(to: extent)
        if let source, source.extent.width > 0, source.extent.height > 0,
           layout.video.width > 0, layout.video.height > 0 {
            let videoSize = CGSize(width: layout.video.width * scale, height: layout.video.height * scale)
            let origin = CGPoint(x: layout.video.minX * scale, y: (layout.viewport.height - layout.video.maxY) * scale)
            let local = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: videoSize.width / source.extent.width, y: videoSize.height / source.extent.height))
                .cropped(to: CGRect(origin: .zero, size: videoSize))
            let clear = CIImage(color: .clear)
            let video = layout.style.videoFadeEnabled && !layout.reduceTransparency
                ? local.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear,
                    kCIInputMaskImageKey: legacyVideoMask(size: videoSize)]) : local
            image = video.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).composited(over: image)
            if layout.reflectionEnabled, layout.reflection.height > 0 {
                let reflectedSize = CGSize(width: layout.reflection.width * scale, height: layout.reflection.height * scale)
                let reflected = local.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
                    .cropped(to: CGRect(x: 0, y: -reflectedSize.height, width: reflectedSize.width, height: reflectedSize.height))
                    .transformed(by: CGAffineTransform(translationX: 0, y: reflectedSize.height))
                let mask = smoothGradient(size: reflectedSize, top: reflectedSize.height, bottom: 0)
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: layout.style.reflectionOpacity, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: layout.style.reflectionOpacity, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: layout.style.reflectionOpacity, w: 0),
                    ])
                let reflection = reflected.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask,
                ]).transformed(by: CGAffineTransform(translationX: layout.reflection.minX * scale,
                    y: (layout.viewport.height - layout.reflection.maxY) * scale))
                image = reflection.composited(over: image)
            }
        }
        guard !layout.reduceTransparency, layout.style.blurRadius > 0 else { return image.cropped(to: extent) }
        let profile = layout.profile
        // White is strongest blur; invert the upward clarity gradient.
        let clarity = smoothGradient(size: size, top: (layout.viewport.height - profile.frame.minY) * scale,
                                     bottom: (layout.viewport.height - profile.fullStrengthY) * scale)
        let mask = clarity.applyingFilter("CIColorInvert")
        return image.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
            kCIInputRadiusKey: layout.style.blurRadius * Double(scale), "inputMask": mask,
        ]).cropped(to: extent)
    }
}

/// A one-column float alpha LUT keeps the old piecewise-linear samples without
/// compiling a nested seventeen-composite shader for every video frame.
private final class ImmersiveVideoMaskCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(CGSize, CIImage)] = []
    func mask(size: CGSize) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries.first(where: { $0.0 == size }) { return entry.1 }
        let height = max(1, Int(ceil(size.height)))
        let style = ImmersiveArtworkStyle()
        var pixels = [Float](repeating: 0, count: height * 4)
        for row in 0 ..< height {
            let alpha = Float(style.videoAlpha(at: 1 - (Double(row) + 0.5) / Double(height)))
            for channel in 0 ..< 4 { pixels[row * 4 + channel] = alpha }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 4 * MemoryLayout<Float>.stride,
            size: CGSize(width: 1, height: height), format: .RGBAf, colorSpace: nil)
            .clampedToExtent().transformed(by: CGAffineTransform(scaleX: size.width, y: size.height / CGFloat(height)))
            .cropped(to: CGRect(origin: .zero, size: size))
        entries.append((size, image))
        if entries.count > 2 { entries.removeFirst() }
        return image
    }
}

/// Metal objects and immutable image inputs cross the serial encoding boundary
/// once. The main thread never mutates a command after transferring ownership.
private struct ImmersiveGPUJob: @unchecked Sendable {
    let command: any MTLCommandBuffer
    let drawable: any CAMetalDrawable
    let background: CIImage
    let frame: ImmersiveArtworkFrame?
    let layout: ImmersiveArtworkComposition
    let scale: CGFloat
    let validity: ImmersiveGPUValidity
}

private final class ImmersiveGPUValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func presentIfValid(_ job: ImmersiveGPUJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid else { return false }
        job.command.present(job.drawable)
        return true
    }
}

private final class ImmersiveGPUWorker: @unchecked Sendable {
    private let work = DispatchQueue(label: "AMLL.immersive.gpu", qos: .userInitiated)
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    init(queue: any MTLCommandQueue) {
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    }
    func submit(_ job: ImmersiveGPUJob, completion: @escaping @Sendable (Bool, Double) -> Void) {
        work.async { [self] in
            autoreleasepool {
                var encoded = false
                if job.validity.isValid {
                    let image = ImmersiveArtworkImage.compose(background: job.background,
                        video: job.frame.map { CIImage(cvPixelBuffer: $0.pixels) }, layout: job.layout, scale: job.scale)
                    let destination = CIRenderDestination(mtlTexture: job.drawable.texture, commandBuffer: job.command)
                    destination.colorSpace = colorSpace; destination.isFlipped = true
                    do { _ = try context.startTask(toRender: image, to: destination); encoded = true }
                    catch { /* Commit background work to release its in-flight buffers. */ }
                }
                let succeeded = encoded && job.validity.presentIfValid(job)
                job.command.addCompletedHandler { command in
                    completion(succeeded && command.status == .completed,
                               (command.gpuEndTime - command.gpuStartTime) * 1000)
                }
                job.command.commit()
            }
        }
    }
}

private final class ImmersiveFlightPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free = [1, 0]
    func acquire() -> Int? { lock.lock(); defer { lock.unlock() }; return free.popLast() }
    func release(_ slot: Int) { lock.lock(); free.append(slot); lock.unlock() }
}

struct ImmersiveArtworkCompositor: UIViewRepresentable {
    let video: AnimatedArtwork
    let frames: ArtworkReflectionFrames
    let background: AMLLBackground
    let style: ImmersiveArtworkStyle
    let metadataTop: CGFloat
    let reflects: Bool
    let reduceTransparency: Bool
    let cornerRadius: CGFloat
    let opacity: Double
    var onSafeArea: ((UIEdgeInsets) -> Void)? = nil

    func makeUIView(context: Context) -> Surface { Surface(frames: frames) }
    func updateUIView(_ view: Surface, context: Context) { view.configure(self) }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.stop() }

    @MainActor final class Surface: UIView, MTKViewDelegate {
        let videoSource = AnimatedArtwork.Surface()
        let metal: MTKView
        private let frames: ArtworkReflectionFrames
        private let queue: (any MTLCommandQueue)?
        private let worker: ImmersiveGPUWorker?
        private let backgrounds: AMLLBackgroundFrameSource?
        private let pool = ImmersiveFlightPool()
        private var targets: [(any MTLTexture)?] = [nil, nil]
        private var configuration: ImmersiveArtworkCompositor?
        private var displayLink: CADisplayLink?
        private var validity = ImmersiveGPUValidity()
        private var revision = UUID() {
            didSet { validity.invalidate(); validity = ImmersiveGPUValidity() }
        }
        private(set) var submittedFrames = 0
        private(set) var presentedFrames = 0
        private(set) var coalescedFrames = 0
        private(set) var repeatedDrawableCount = 0
        private var previousDrawableID: UInt64?
        private var tickTime: (CFTimeInterval, CFTimeInterval)?
        private var intervals: [Double] = []
        private var gpuTimes: [Double] = []
        private var lastTick: CFTimeInterval?
        private var gpuFailures = 0
        private var lastVideoTime: CMTime = .invalid
        private var reportedGPUFailure = false
        private var reportedInsets: UIEdgeInsets?

        @MainActor private final class Target: NSObject {
            weak var view: Surface?
            @objc func tick(_ link: CADisplayLink) {
                guard let view else { return }
                view.tickTime = (link.timestamp, link.targetTimestamp)
                view.metal.draw()
            }
        }

        init(frames: ArtworkReflectionFrames) {
            self.frames = frames
            let device = MTLCreateSystemDefaultDevice()
            let queue = device?.makeCommandQueue()
            self.queue = queue
            metal = MTKView(frame: .zero, device: device)
            worker = queue.map { ImmersiveGPUWorker(queue: $0) }
            backgrounds = device.flatMap { device in queue.map { AMLLBackgroundFrameSource(device: device, queue: $0) } }
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            clipsToBounds = true
            metal.isPaused = true; metal.enableSetNeedsDisplay = false
            metal.delegate = self
            metal.framebufferOnly = false; metal.colorPixelFormat = .bgra8Unorm
            metal.isOpaque = true; metal.backgroundColor = UIColor(white: 0.08, alpha: 1)
            addSubview(videoSource); addSubview(metal)
            frames.compositor = self
            for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(applicationChanged), name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { nil }
        deinit { NotificationCenter.default.removeObserver(self) }

        var diagnostic: String {
            func p95(_ values: [Double]) -> Double {
                let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
            }
            return "统一提交：\(submittedFrames)；已呈现：\(presentedFrames)；合并：\(coalescedFrames)；GPU 错误：\(gpuFailures)\n视频时间：\(lastVideoTime.seconds.isFinite ? String(format: "%.3f", lastVideoTime.seconds) : "等待") s；帧间隔 P95：\(String(format: "%.2f", p95(intervals))) ms；GPU P95：\(String(format: "%.2f", p95(gpuTimes))) ms\n背景纹理：\(targets.compactMap { $0 }.count)；重复 drawable：\(repeatedDrawableCount)；统一处理：背景、视频、倒影"
        }

        func configure(_ value: ImmersiveArtworkCompositor) {
            if configuration?.video.url != value.video.url { revision = UUID() }
            configuration = value
            videoSource.onFailure = value.video.onFailure
            videoSource.onState = value.video.onState
            videoSource.onFirstFrame = value.video.onFirstFrame
            videoSource.configure(url: value.video.url, active: value.video.active, allowCellular: value.video.allowCellular,
                reflectionFrames: frames, gravity: .resizeAspect, fadesBottom: false, externallyDriven: true)
            backgrounds?.configure(value.background, reduceMotion: false, reduceTransparency: value.reduceTransparency)
            layer.cornerRadius = value.cornerRadius
            alpha = value.opacity
            updateScheduler()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if metal.frame.size != bounds.size { revision = UUID() }
            videoSource.frame = bounds; metal.frame = bounds
            if let insets = window?.safeAreaInsets, reportedInsets != insets {
                reportedInsets = insets
                let callback = configuration?.onSafeArea
                Task { @MainActor in callback?(insets) }
            }
        }
        override func didMoveToWindow() { super.didMoveToWindow(); lastTick = nil; updateScheduler() }
        @objc private func applicationChanged() { lastTick = nil; updateScheduler() }
        private func updateScheduler() {
            let active = window != nil && configuration?.background.active == true && UIApplication.shared.applicationState == .active
            if active, displayLink == nil {
                let target = Target(); target.view = self
                let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
                link.preferredFrameRateRange = .init(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common); displayLink = link
            } else if !active {
                displayLink?.invalidate(); displayLink = nil
                backgrounds?.suspendClock()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { revision = UUID() }

        func draw(in view: MTKView) {
            guard let (timestamp, targetTime) = tickTime else { return }
            tickTime = nil
            draw(at: timestamp, targetTime: targetTime)
        }

        private func draw(at timestamp: CFTimeInterval, targetTime: CFTimeInterval) {
            guard let configuration, bounds.width > 0, bounds.height > 0 else { return }
            videoSource.sampleVideoFrame(at: timestamp, targetTime: targetTime)
            guard let queue, let worker, let backgrounds, let device = metal.device else {
                if !reportedGPUFailure { reportedGPUFailure = true; videoSource.failComposition() }
                return
            }
            guard let slot = pool.acquire() else { coalescedFrames += 1; return }
            var submitted = false
            defer { if !submitted { pool.release(slot) } }
            guard let drawable = metal.currentDrawable, let command = queue.makeCommandBuffer() else { return }
            if previousDrawableID == drawable.drawableID { repeatedDrawableCount += 1 }
            previousDrawableID = drawable.drawableID
            let width = drawable.texture.width, height = drawable.texture.height
            if targets[slot]?.width != width || targets[slot]?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
                targets[slot] = device.makeTexture(descriptor: descriptor)
            }
            guard let target = targets[slot] else { return }
            let frame = frames.currentFrame
            let video = AMLLImmersiveArtworkGeometry.frame(viewport: bounds.size, video: frame?.size ?? .zero)
            let style = configuration.style.validated()
            let available = min(video.height, max(0, bounds.height - video.maxY))
            let reflection = CGRect(x: video.minX, y: video.maxY, width: video.width,
                                    height: available * style.reflectionLength)
            let profile = ImmersivePlayerLayoutMetrics(metadataTop: configuration.metadataTop, progressCenter: 0,
                transportCenter: 0, volumeCenter: 0, actionsCenter: 0, inset: 0, needsScrolling: false)
                .blurProfile(style: style, viewport: bounds.size)
            let layout = ImmersiveArtworkComposition(viewport: bounds.size, video: video, reflection: reflection,
                profile: profile, style: style, reflectionEnabled: configuration.reflects,
                reduceTransparency: configuration.reduceTransparency, dimming: configuration.background.dimming)
            let scale = CGFloat(width) / bounds.width
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let background = backgrounds.image(command: command, target: target, viewport: bounds.size, at: timestamp)
                ?? CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: extent)
            let revision = revision, pool = pool
            worker.submit(.init(command: command, drawable: drawable, background: background,
                frame: frame, layout: layout, scale: scale, validity: validity)) { [weak self] succeeded, duration in
                pool.release(slot)
                Task { @MainActor [weak self] in
                    guard let self, self.revision == revision, self.window != nil else { return }
                    if succeeded {
                        self.presentedFrames += 1
                        if duration.isFinite, duration > 0 {
                            self.gpuTimes.append(duration)
                            if self.gpuTimes.count > 240 { self.gpuTimes.removeFirst() }
                        }
                        if let frame { self.lastVideoTime = frame.presentationTime; self.videoSource.compositionDidPresent(frame) }
                    } else { self.gpuFailures += 1; self.videoSource.failComposition() }
                }
            }
            submitted = true; submittedFrames += 1
            if let lastTick {
                intervals.append((timestamp - lastTick) * 1000)
                if intervals.count > 240 { intervals.removeFirst() }
            }
            lastTick = timestamp
        }

        func stop() {
            revision = UUID(); displayLink?.invalidate(); displayLink = nil
            videoSource.stop(); backgrounds?.stop(); targets = [nil, nil]
            configuration = nil
        }
    }
}
