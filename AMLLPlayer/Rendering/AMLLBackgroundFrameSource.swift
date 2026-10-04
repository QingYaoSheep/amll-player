import CoreImage
import MetalKit

/// The immersive compositor owns scheduling and submission. Existing background
/// algorithms only encode into its command buffer; no hosting-view snapshots.
@MainActor
final class AMLLBackgroundFrameSource {
    private let mesh: AMLLMeshBackground.Coordinator
    private let pixi: AMLLPixiBackground.Coordinator
    private let meshView: MTKView
    private let pixiView: MTKView
    private let flowing: AMLLFlowingBackgroundRenderer?
    private var flowingState = AMLLFlowingBackgroundState()
    private let worker = FlowingImageWorker()
    private var flowingURL: URL?
    private var flowTask: Task<Void, Never>?
    private var revision = UUID()
    private var lastTime: CFTimeInterval?
    private var background: AMLLBackground?
    private var reduceMotion = false
    private var reduceTransparency = false

    init(device: any MTLDevice, queue: any MTLCommandQueue, seed: UInt32 = 42) {
        meshView = MTKView(frame: .zero, device: device)
        pixiView = MTKView(frame: .zero, device: device)
        mesh = AMLLMeshBackground.Coordinator(seed: seed)
        pixi = AMLLPixiBackground.Coordinator(seed: seed)
        flowing = AMLLFlowingBackgroundRenderer(device: device, commandQueue: queue)
        mesh.attach(to: meshView)
        pixi.attach(pixiView)
        for view in [meshView, pixiView] { view.isPaused = true; view.enableSetNeedsDisplay = false }
    }

    func configure(_ value: AMLLBackground, reduceMotion: Bool, reduceTransparency: Bool) {
        if background?.active != value.active || self.reduceMotion != reduceMotion || self.reduceTransparency != reduceTransparency {
            lastTime = nil
        }
        background = value
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        let staticMode = reduceMotion || reduceTransparency
        mesh.setBlur(0)
        mesh.setRunning(value.active && value.mode == .mesh && !staticMode, staticMode: staticMode)
        pixi.setBlurEnabled(false)
        pixi.setRunning(value.active && value.mode == .pixi && !staticMode, staticMode: staticMode)
        // setRunning normally configures standalone MTKView scheduling.
        for view in [meshView, pixiView] { view.isPaused = true; view.enableSetNeedsDisplay = false }
        if value.mode == .mesh { mesh.setArtwork(value.artworkURL) }
        if value.mode == .pixi { pixi.setArtwork(value.artworkURL) }
        var configuration = value.flowing
        configuration.blur = 0
        flowingState.configure(configuration, immediately: staticMode)
        if value.mode == .flowing, flowingURL != value.artworkURL {
            flowingURL = value.artworkURL
            revision = UUID()
            flowTask?.cancel()
            guard let url = flowingURL else { flowing?.clear(); return }
            let revision = revision, worker = worker
            flowTask = Task { [weak self] in
                do {
                    let data = try await ArtworkImageData.load(url)
                    let decoded = try await worker.decode(data)
                    try Task.checkCancellation()
                    guard let self, self.revision == revision, let flowing = self.flowing else { return }
                    let texture = try flowing.texture(image: decoded.image)
                    let hadPrevious = flowing.install(texture, interrupting: self.flowingState.artworkProgress < 1)
                    self.flowingState.beginArtworkTransition(hasPrevious: hadPrevious, immediately: self.reduceMotion)
                } catch { /* Retain the last usable background. */ }
            }
        }
    }

    func image(command: any MTLCommandBuffer, target: any MTLTexture,
               viewport: CGSize, at timestamp: CFTimeInterval) -> CIImage? {
        guard let background else { return nil }
        let extent = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        func color(_ value: LyricsRenderConfiguration.BackgroundColor) -> CIColor {
            CIColor(red: CGFloat(value.red), green: CGFloat(value.green), blue: CGFloat(value.blue))
        }
        switch background.mode {
        case .solid:
            return CIImage(color: color(background.color)).cropped(to: extent)
        case .gradient:
            return CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: extent.midX, y: extent.maxY),
                "inputPoint1": CIVector(x: extent.midX, y: 0),
                "inputColor0": color(background.color), "inputColor1": color(background.gradientEnd),
            ])?.outputImage?.cropped(to: extent)
        case .mesh:
            guard mesh.encode(command: command, target: target, at: timestamp) else { return nil }
        case .pixi:
            guard pixi.encode(command: command, target: target, at: timestamp) else { return nil }
        case .flowing:
            let running = background.active && !reduceMotion && !reduceTransparency
            let delta = running ? max(0, timestamp - (lastTime ?? timestamp)) : 0
            lastTime = running ? timestamp : nil
            flowingState.advance(seconds: delta, running: running)
            guard flowing?.encode(command: command, target: target, size: viewport, state: flowingState) == true else { return nil }
        }
        return CIImage(mtlTexture: target, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])?
            .oriented(.downMirrored)
    }

    func stop() {
        revision = UUID(); flowTask?.cancel(); flowTask = nil
        mesh.stop(); pixi.stop(); flowing?.clear()
        lastTime = nil
    }
}
