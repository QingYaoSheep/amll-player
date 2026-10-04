import MetalKit
import MetalPerformanceShaders

/// Slot ownership is returned by the GPU, not by a display-frame counter.
private final class FlowingFlightPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free = [1, 0]
    private var gpuSamples: [Double] = []
    private var failed = false

    func acquire() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return free.popLast()
    }

    func markFailed() {
        lock.lock(); defer { lock.unlock() }
        failed = true
    }

    func release(_ slot: Int, command: (any MTLCommandBuffer)? = nil) {
        lock.lock(); defer { lock.unlock() }
        free.append(slot)
        if let command {
            failed = failed || command.status == .error
            let duration = command.gpuEndTime - command.gpuStartTime
            if duration.isFinite, duration > 0 {
                gpuSamples.append(duration)
                if gpuSamples.count > 240 { gpuSamples.removeFirst() }
            }
        }
    }

    var status: (inFlight: Int, gpuP95: Double, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        let sorted = gpuSamples.sorted()
        return (2 - free.count, sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)], failed)
    }
}

@MainActor
final class AMLLFlowingBackgroundRenderer {
    struct Statistics {
        var submittedFrames: Int
        var allocatedTargetSets: Int
        var residentTextureBytes: Int
        var inFlight: Int
        var cpuP95: Double
        var gpuP95: Double
        var drawableWait: Double
    }

    private struct Uniforms {
        var viewport: SIMD4<Float>
        var motion: SIMD4<Float>
        var covers: SIMD4<Float>
    }

    private struct Targets {
        var raw: any MTLTexture
        var blurred: any MTLTexture
    }

    let device: any MTLDevice
    var onSubmissionCompleted: (@MainActor @Sendable () -> Void)?
    private let queue: any MTLCommandQueue
    private let compose: any MTLRenderPipelineState
    private let copy: any MTLRenderPipelineState
    private let pool = FlowingFlightPool()
    private var targets: [Targets?] = [nil, nil]
    private var current: (any MTLTexture)?
    private var outgoing: (any MTLTexture)?
    private var outgoingIsSnapshot = false
    private var snapshotSource: (any MTLTexture)?
    private var lastComposite: (any MTLTexture)?
    private var hasPresentedArtwork = false
    private var gaussian: MPSImageGaussianBlur?
    private var gaussianSigma: Float = -1
    private var submittedFrames = 0
    private var allocatedTargetSets = 0
    private var cpuSamples: [Double] = []
    private var drawableWait = 0.0

    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), commandQueue: (any MTLCommandQueue)? = nil) {
        guard let device, MPSSupportsMTLDevice(device), let queue = commandQueue ?? device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "amllFlowingQuad") else { return nil }
        func pipeline(_ name: String, format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let compose = pipeline("amllFlowingCompose", format: .rgba8Unorm),
              let copy = pipeline("amllFlowingCopy", format: .bgra8Unorm) else { return nil }
        self.device = device; self.queue = queue; self.compose = compose; self.copy = copy
    }

    func texture(image: CGImage) throws -> any MTLTexture {
        try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
        ])
    }

    /// Capture the currently composed image when interrupting a crossfade.
    /// It is already in viewport coordinates and must not be warped twice.
    @discardableResult
    func install(_ texture: any MTLTexture, interrupting: Bool) -> Bool {
        let hasPrevious = hasPresentedArtwork && current != nil
        if hasPrevious {
            if interrupting, let lastComposite {
                snapshotSource = lastComposite
                outgoingIsSnapshot = true
            } else {
                outgoing = current
                snapshotSource = nil
                outgoingIsSnapshot = false
            }
        } else {
            outgoing = nil; snapshotSource = nil; outgoingIsSnapshot = false
        }
        current = texture
        return hasPrevious
    }

    func clear() {
        current = nil; outgoing = nil; snapshotSource = nil; lastComposite = nil
        outgoingIsSnapshot = false
        hasPresentedArtwork = false
    }

    var failed: Bool { pool.status.failed }

    var statistics: Statistics {
        let textures = targets.compactMap { $0 }.flatMap { [$0.raw, $0.blurred] }
            + [current, outgoing, snapshotSource, lastComposite].compactMap { $0 }
        var identities = Set<ObjectIdentifier>()
        let bytes = textures.reduce(0) { value, texture in
            identities.insert(ObjectIdentifier(texture as AnyObject)).inserted
                ? value + texture.width * texture.height * 4 : value
        }
        let sorted = cpuSamples.sorted(), status = pool.status
        return .init(submittedFrames: submittedFrames, allocatedTargetSets: allocatedTargetSets,
                     residentTextureBytes: bytes, inFlight: status.inFlight,
                     cpuP95: sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
                     gpuP95: status.gpuP95, drawableWait: drawableWait)
    }

    @discardableResult
    func draw(in view: MTKView, state: AMLLFlowingBackgroundState) -> (any MTLCommandBuffer)? {
        submit(size: view.bounds.size, state: state) {
            guard let drawable = view.currentDrawable else { return nil }
            return (drawable.texture, drawable)
        }
    }

    @discardableResult
    func render(target: any MTLTexture, size: CGSize, state: AMLLFlowingBackgroundState) -> (any MTLCommandBuffer)? {
        submit(size: size, state: state) { (target, nil) }
    }

    @discardableResult
    func encode(command: any MTLCommandBuffer, target: any MTLTexture, size: CGSize,
                state: AMLLFlowingBackgroundState) -> Bool {
        submit(size: size, state: state, externalCommand: command) { (target, nil) } != nil
    }

    private func makeTexture(width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private func encoder(_ command: any MTLCommandBuffer, target: any MTLTexture) -> (any MTLRenderCommandEncoder)? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = .init(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        return command.makeRenderCommandEncoder(descriptor: pass)
    }

    private func submit(size: CGSize, state: AMLLFlowingBackgroundState,
                        externalCommand: (any MTLCommandBuffer)? = nil,
                        targetProvider: () -> ((any MTLTexture), (any CAMetalDrawable)?)?) -> (any MTLCommandBuffer)?
    {
        guard size.width > 0, size.height > 0, let slot = pool.acquire() else { return nil }
        let started = CACurrentMediaTime()
        var committed = false
        defer { if !committed { pool.release(slot) } }
        let waiting = CACurrentMediaTime()
        guard let (target, drawable) = targetProvider() else { return nil }
        guard let command = externalCommand ?? queue.makeCommandBuffer() else { return renderFailed() }
        drawableWait = CACurrentMediaTime() - waiting
        guard target.pixelFormat == .bgra8Unorm else { return renderFailed() }
        if targets[slot]?.raw.width != target.width || targets[slot]?.raw.height != target.height {
            guard let raw = makeTexture(width: target.width, height: target.height),
                  let blurred = makeTexture(width: target.width, height: target.height) else { return renderFailed() }
            targets[slot] = .init(raw: raw, blurred: blurred)
            allocatedTargetSets += 1
        }
        guard let surfaces = targets[slot] else { return renderFailed() }
        if state.artworkProgress >= 1 {
            outgoing = nil; snapshotSource = nil; outgoingIsSnapshot = false
        } else if let source = snapshotSource {
            guard let snapshot = makeTexture(width: source.width, height: source.height),
                  let blit = command.makeBlitCommandEncoder() else { return renderFailed() }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                      sourceSize: .init(width: source.width, height: source.height, depth: 1),
                      to: snapshot, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding()
            outgoing = snapshot; snapshotSource = nil
        }
        guard let sourcePass = encoder(command, target: surfaces.raw) else { return renderFailed() }
        if let current {
            let previous = outgoing ?? current
            var uniforms = Uniforms(
                viewport: .init(Float(size.width), Float(size.height), Float(state.angle), Float(state.distortion / 100)),
                motion: .init(Float(state.phase18), Float(state.phase27), Float(state.artworkProgress), outgoingIsSnapshot ? 1 : 0),
                covers: .init(Float(current.width) / Float(current.height), Float(previous.width) / Float(previous.height), 0, 0))
            sourcePass.setRenderPipelineState(compose)
            sourcePass.setFragmentTexture(current, index: 0)
            sourcePass.setFragmentTexture(previous, index: 1)
            sourcePass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            sourcePass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        sourcePass.endEncoding()
        // Sigma is in pixels of the post-transform image. Cache the current
        // kernel; quarter-pixel quantization bounds recreation during sliders.
        let sigma = Float((state.blur * Double(target.width) / Double(size.width) * 4).rounded() / 4)
        var output = surfaces.raw
        if sigma > 0 {
            if gaussianSigma != sigma {
                gaussian = MPSImageGaussianBlur(device: device, sigma: sigma)
                gaussian?.edgeMode = .clamp
                gaussianSigma = sigma
            }
            guard let gaussian else { return renderFailed() }
            gaussian.encode(commandBuffer: command, sourceTexture: surfaces.raw, destinationTexture: surfaces.blurred)
            output = surfaces.blurred
        }
        guard let finalPass = encoder(command, target: target) else { return renderFailed() }
        finalPass.setRenderPipelineState(copy)
        finalPass.setFragmentTexture(output, index: 0)
        finalPass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        finalPass.endEncoding()
        if let drawable { command.present(drawable) }
        let pool = pool, completion = onSubmissionCompleted
        command.addCompletedHandler { buffer in
            pool.release(slot, command: buffer)
            if let completion { Task { @MainActor in completion() } }
        }
        if externalCommand == nil { command.commit() }
        committed = true
        lastComposite = surfaces.raw
        if current != nil { hasPresentedArtwork = true }
        submittedFrames += 1
        cpuSamples.append(CACurrentMediaTime() - started)
        if cpuSamples.count > 240 { cpuSamples.removeFirst() }
        return command
    }

    private func renderFailed() -> (any MTLCommandBuffer)? {
        pool.markFailed()
        onSubmissionCompleted?()
        return nil
    }
}
