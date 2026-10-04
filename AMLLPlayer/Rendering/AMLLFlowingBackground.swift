import CoreImage
import ImageIO
import MetalKit
import SwiftUI

struct FlowingDecodedImage: @unchecked Sendable {
    // CGImage is immutable; ownership can safely move from the decode actor.
    let image: CGImage
}

/// Serializes decode/fallback filtering. Cancelled waiting requests check
/// cancellation before doing any image work; they never accumulate CI jobs.
actor FlowingImageWorker {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func decode(_ data: Data) throws -> FlowingDecodedImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        return .init(image: image)
    }

    func fallback(_ decoded: FlowingDecodedImage, blur: Double, viewport: CGSize) throws -> FlowingDecodedImage {
        try Task.checkCancellation()
        guard blur > 0, viewport.width > 0, viewport.height > 0 else { return decoded }
        let image = decoded.image
        let scale = min(Double(image.width) / Double(viewport.width), Double(image.height) / Double(viewport.height))
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * scale])
        guard let output = context.createCGImage(blurred, from: input.extent) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        return .init(image: output)
    }
}

@MainActor
final class AMLLFlowingBackgroundSurface: UIView {
    let metal: MTKView
    let fallback = UIImageView()
    var resized: (() -> Void)?
    private var previousSize = CGSize.zero

    init(device: (any MTLDevice)?) {
        metal = MTKView(frame: .zero, device: device)
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        clipsToBounds = true
        fallback.contentMode = .scaleAspectFill
        fallback.clipsToBounds = true
        metal.isOpaque = true
        metal.colorPixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.preferredFramesPerSecond = 60
        metal.isPaused = true
        (metal.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        addSubview(fallback)
        addSubview(metal)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        metal.frame = bounds
        fallback.frame = bounds
        if previousSize != bounds.size {
            previousSize = bounds.size
            resized?()
        }
    }
}

struct AMLLFlowingBackground: UIViewRepresentable {
    var artworkURL: URL?
    var active: Bool
    var configuration: FlowingBackgroundConfiguration
    var suppressBlur = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AMLLFlowingBackgroundSurface {
        let surface = AMLLFlowingBackgroundSurface(device: context.coordinator.renderer?.device)
        context.coordinator.attach(surface)
        return surface
    }

    func updateUIView(_ surface: AMLLFlowingBackgroundSurface, context: Context) {
        context.coordinator.configure(url: artworkURL, configuration: configuration, active: active,
                                      reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
                                      suppressBlur: suppressBlur)
    }

    static func dismantleUIView(_ surface: AMLLFlowingBackgroundSurface, coordinator: Coordinator) {
        coordinator.stop()
        surface.metal.delegate = nil
        surface.resized = nil
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private(set) var renderer: AMLLFlowingBackgroundRenderer?
        private(set) var state = AMLLFlowingBackgroundState()
        private(set) var loadedURL: URL?
        var performanceRecorder: AMLLFramePerformanceRecorder?
        private weak var surface: AMLLFlowingBackgroundSurface?
        private let worker = FlowingImageWorker()
        private let load: @Sendable (URL) async throws -> Data
        private var artworkTask: Task<Void, Never>?
        private var fallbackTask: Task<Void, Never>?
        private var requestedURL: URL?
        private var loadingURL: URL?
        private(set) var failedURL: URL?
        private var decoded: FlowingDecodedImage?
        private var generation: UInt64 = 0
        private var fallbackRevision: UInt64 = 0
        private var active = false
        private var running = false
        private var staticMode = false
        private var reduceTransparency = false
        private var lastTimestamp: CFTimeInterval?
        private var needsStaticFrame = false

        init(renderer: AMLLFlowingBackgroundRenderer? = AMLLFlowingBackgroundRenderer(),
             load: @escaping @Sendable (URL) async throws -> Data = { try await ArtworkImageData.load($0) }) {
            self.renderer = renderer
            self.load = load
            super.init()
        }

        func attach(_ surface: AMLLFlowingBackgroundSurface) {
            self.surface = surface
            surface.metal.delegate = self
            renderer?.onSubmissionCompleted = { [weak self] in self?.submissionCompleted() }
            surface.metal.isHidden = renderer == nil
            surface.resized = { [weak self] in self?.resized() }
        }

        func configure(url: URL?, configuration: FlowingBackgroundConfiguration, active: Bool,
                       reduceMotion: Bool, reduceTransparency: Bool, suppressBlur: Bool = false) {
            var effective = configuration
            if suppressBlur { effective.blur = 0 }
            let changedParameters = state.configuration != effective.validated()
            state.configure(effective, immediately: reduceMotion || suppressBlur)
            let becameActive = active && !self.active
            let becameVisible = active && !reduceTransparency && (!self.active || self.reduceTransparency)
            self.active = active
            if becameActive { failedURL = nil }
            self.staticMode = reduceMotion
            self.reduceTransparency = reduceTransparency
            let nextRunning = active && !reduceMotion && !reduceTransparency
            if running != nextRunning { lastTimestamp = nil }
            running = nextRunning
            surface?.alpha = reduceTransparency ? 0 : 1
            surface?.metal.isPaused = !nextRunning || renderer == nil
            surface?.metal.enableSetNeedsDisplay = active && !reduceTransparency && !nextRunning && renderer != nil
            if url != requestedURL {
                generation &+= 1
                requestedURL = url
                failedURL = nil
                artworkTask?.cancel(); artworkTask = nil; loadingURL = nil
                if url == nil {
                    decoded = nil; loadedURL = nil
                    fallbackTask?.cancel(); fallbackRevision &+= 1
                    surface?.fallback.image = nil
                    renderer?.clear()
                    state.beginArtworkTransition(hasPrevious: false)
                }
            }
            if !active || reduceTransparency {
                artworkTask?.cancel(); artworkTask = nil; loadingURL = nil
                fallbackTask?.cancel(); fallbackRevision &+= 1
                return
            }
            if let url, url != loadedURL, url != loadingURL, url != failedURL { request(url) }
            if renderer == nil, changedParameters || becameVisible { updateFallback() }
            if reduceMotion { state.beginArtworkTransition(hasPrevious: false, immediately: true) }
            if !nextRunning { surface?.metal.setNeedsDisplay() }
        }

        private func request(_ url: URL) {
            generation &+= 1
            let revision = generation, load = load, worker = worker
            loadingURL = url
            artworkTask?.cancel()
            artworkTask = Task { [weak self] in
                do {
                    let data = try await load(url)
                    let image = try await worker.decode(data)
                    try Task.checkCancellation()
                    guard let self, self.generation == revision, self.requestedURL == url, self.active else { return }
                    let hadPrevious: Bool
                    if let renderer = self.renderer, let texture = try? renderer.texture(image: image.image) {
                        hadPrevious = renderer.install(texture, interrupting: self.state.artworkProgress < 1)
                    } else {
                        self.renderer = nil
                        self.surface?.metal.isHidden = true
                        self.surface?.metal.isPaused = true
                        hadPrevious = false
                    }
                    self.decoded = image
                    self.loadedURL = url; self.loadingURL = nil
                    self.state.beginArtworkTransition(hasPrevious: hadPrevious, immediately: self.staticMode)
                    if self.renderer == nil { self.updateFallback() }
                    self.surface?.metal.setNeedsDisplay()
                } catch {
                    guard let self, self.generation == revision else { return }
                    self.loadingURL = nil
                    if !Task.isCancelled { self.failedURL = url }
                    // Retain the last valid cover, or the surface's neutral background.
                }
            }
        }

        private func updateFallback() {
            guard active, !reduceTransparency, let decoded, let surface else { return }
            fallbackRevision &+= 1
            let revision = fallbackRevision, generation = generation
            let blur = state.configuration.blur, viewport = surface.bounds.size, worker = worker
            fallbackTask?.cancel()
            fallbackTask = Task { [weak self] in
                do {
                    let image = try await worker.fallback(decoded, blur: blur, viewport: viewport)
                    try Task.checkCancellation()
                    guard let self, self.generation == generation, self.fallbackRevision == revision, self.active else { return }
                    self.surface?.fallback.image = UIImage(cgImage: image.image)
                } catch { /* Keep a previously filtered image on failure. */ }
            }
        }

        private func resized() {
            guard active, !reduceTransparency else { return }
            if renderer == nil { updateFallback() }
            surface?.metal.setNeedsDisplay()
        }

        func advanceClock(at timestamp: CFTimeInterval) -> Double {
            guard timestamp.isFinite else { return 0 }
            let delta = running ? max(0, timestamp - (lastTimestamp ?? timestamp)) : 0
            lastTimestamp = running ? timestamp : nil
            state.advance(seconds: delta, running: running)
            return delta
        }

        func draw(in view: MTKView) {
            guard active, !reduceTransparency, let renderer else { return }
            if renderer.failed {
                submissionCompleted()
                return
            }
            let start = CACurrentMediaTime()
            let interval = advanceClock(at: start)
            needsStaticFrame = renderer.draw(in: view, state: state) == nil && !running
            if let performanceRecorder {
                let stats = renderer.statistics
                performanceRecorder.append(.init(interval: interval * 1000, cpu: (CACurrentMediaTime() - start) * 1000,
                    layout: 0, raster: 0, engine: 0, layers: 0, drawableWait: stats.drawableWait * 1000,
                    gpuSubmission: stats.cpuP95 * 1000, gpu: stats.gpuP95 * 1000, cacheBytes: stats.residentTextureBytes))
            }
        }

        private func submissionCompleted() {
            guard active, !reduceTransparency, let renderer else { return }
            if renderer.failed {
                renderer.onSubmissionCompleted = nil
                self.renderer = nil
                surface?.metal.isPaused = true
                surface?.metal.isHidden = true
                needsStaticFrame = false
                updateFallback()
            } else if needsStaticFrame, !running {
                surface?.metal.setNeedsDisplay()
            }
        }

        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

        func stop() {
            generation &+= 1; fallbackRevision &+= 1
            artworkTask?.cancel(); artworkTask = nil
            fallbackTask?.cancel(); fallbackTask = nil
            surface?.metal.isPaused = true
            surface?.metal.enableSetNeedsDisplay = false
            running = false; active = false; lastTimestamp = nil
            renderer?.onSubmissionCompleted = nil
            decoded = nil; renderer = nil; needsStaticFrame = false
            surface?.fallback.image = nil
        }
    }
}
