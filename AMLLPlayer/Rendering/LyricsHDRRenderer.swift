import MetalKit
import UIKit

/// Shared immutable GPU resources. The caller retains ownership of the glyph
/// atlas, frame clock and geometry; this renderer never lays text out.
@MainActor
final class LyricsHDRRenderer {
    struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var mask: SIMD2<Float>
        var appearance: SIMD4<Float>
        /// Atlas crop and optional shadow sampling, in normalized texture units.
        var crop: SIMD4<Float> = .init(0, 0, 1, 1)
        var glow: SIMD2<Float> = .zero
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let inFlight = DispatchSemaphore(value: 3)
    private let vertexBuffers = VertexBufferPool()
    private let timings = SubmissionTimings()

    private final class VertexBufferLease: @unchecked Sendable {
        let buffer: MTLBuffer
        init(_ buffer: MTLBuffer) { self.buffer = buffer }
    }

    private final class VertexBufferPool: @unchecked Sendable {
        private let lock = NSLock()
        private var available: [VertexBufferLease] = []
        private var created = 0

        func take(device: MTLDevice, bytes: Int) -> VertexBufferLease? {
            lock.lock()
            if let index = available.firstIndex(where: { $0.buffer.length >= bytes }) {
                let lease = available.remove(at: index)
                lock.unlock()
                return lease
            }
            lock.unlock()
            let capacity = max(4_096, 1 << (Int.bitWidth - (max(1, bytes - 1)).leadingZeroBitCount))
            guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
            lock.lock(); created += 1; lock.unlock()
            return VertexBufferLease(buffer)
        }

        func put(_ lease: VertexBufferLease) {
            lock.lock()
            if available.count < 3 {
                available.append(lease)
            } else if let smallest = available.indices.min(by: { available[$0].buffer.length < available[$1].buffer.length }),
                      lease.buffer.length > available[smallest].buffer.length {
                available[smallest] = lease
            }
            lock.unlock()
        }

        var createdCount: Int {
            lock.lock(); defer { lock.unlock() }
            return created
        }
    }

    private final class SubmissionTimings: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting = 0.0
        private var submitting = 0.0
        private var gpu = 0.0

        func add(wait: Double, submit: Double) {
            lock.lock(); waiting += wait; submitting += submit; lock.unlock()
        }

        func add(gpu duration: Double) {
            lock.lock(); gpu += duration; lock.unlock()
        }

        func drain() -> (wait: Double, submit: Double, gpu: Double) {
            lock.lock(); defer { lock.unlock() }
            let value = (waiting, submitting, gpu)
            waiting = 0; submitting = 0; gpu = 0
            return value
        }
    }

    var createdVertexBufferCount: Int { vertexBuffers.createdCount }

    func drainTimings() -> (wait: Double, submit: Double, gpu: Double) {
        timings.drain()
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "lyricsHDRVertex"),
              let fragment = library.makeFunction(name: "lyricsHDRFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .rgba16Float
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func glyphTexture(_ image: CGImage) -> MTLTexture? {
        // UIKit may choose a grayscale or extended-range backing for white
        // glyphs. Normalize explicitly rather than relying on MTKTextureLoader's
        // supported CGImage formats. The shader consumes coverage from alpha.
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: context.bytesPerRow)
        return texture
    }

    func makeLayer(size: CGSize, scale: CGFloat) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.backgroundColor = UIColor.clear.cgColor
        layer.framebufferOnly = true
        layer.contentsScale = scale
        layer.frame = CGRect(origin: .zero, size: size)
        layer.drawableSize = CGSize(width: max(1, ceil(size.width * scale)), height: max(1, ceil(size.height * scale)))
        return layer
    }

    /// Also accepts a private floating target for deterministic GPU tests.
    /// Each command owns its vertex buffer until completion; no mutable shared
    /// buffer can be overwritten by the next display-link callback.
    func render(vertices: [Vertex], glyphs: MTLTexture, target: MTLTexture,
                drawable: CAMetalDrawable? = nil) -> MTLCommandBuffer?
    {
        render(vertices: vertices, glyphs: glyphs) { (target, drawable) }
    }

    /// Reserve GPU capacity before asking Core Animation for a drawable.
    /// A busy frame falls back to the existing SDR glyphs without waiting for
    /// one of the renderer's outstanding commands to finish.
    func render(vertices: [Vertex], glyphs: MTLTexture, layer: CAMetalLayer) -> MTLCommandBuffer? {
        render(vertices: vertices, glyphs: glyphs) {
            let started = CACurrentMediaTime()
            let drawable = layer.nextDrawable()
            timings.add(wait: (CACurrentMediaTime() - started) * 1_000, submit: 0)
            guard let drawable else { return nil }
            return (drawable.texture, drawable)
        }
    }

    private func render(vertices: [Vertex], glyphs: MTLTexture,
                        acquireTarget: () -> (MTLTexture, CAMetalDrawable?)?) -> MTLCommandBuffer?
    {
        guard !vertices.isEmpty, inFlight.wait(timeout: .now()) == .success else { return nil }
        let gate = inFlight
        var submitted = false
        var lease: VertexBufferLease?
        defer {
            if !submitted {
                if let lease { vertexBuffers.put(lease) }
                gate.signal()
            }
        }
        guard let (target, drawable) = acquireTarget(), target.pixelFormat == .rgba16Float else { return nil }
        let started = CACurrentMediaTime()
        guard let bufferLease = vertexBuffers.take(device: device,
                                                   bytes: MemoryLayout<Vertex>.stride * vertices.count) else { return nil }
        lease = bufferLease
        guard let command = queue.makeCommandBuffer() else { return nil }
        let buffer = bufferLease.buffer
        vertices.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                buffer.contents().copyMemory(from: base, byteCount: bytes.count)
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(glyphs, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        if let drawable {
            command.present(drawable)
        }
        let pool = vertexBuffers
        let metrics = timings
        command.addCompletedHandler { completed in
            let gpuTime = max(0, (completed.gpuEndTime - completed.gpuStartTime) * 1_000)
            if gpuTime.isFinite { metrics.add(gpu: gpuTime) }
            pool.put(bufferLease)
            gate.signal()
        }
        submitted = true
        command.commit()
        timings.add(wait: 0, submit: (CACurrentMediaTime() - started) * 1_000)
        return command
    }
}
