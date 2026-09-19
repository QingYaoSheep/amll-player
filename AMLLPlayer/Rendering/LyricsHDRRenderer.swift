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
        try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ])
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
            guard let drawable = layer.nextDrawable() else { return nil }
            return (drawable.texture, drawable)
        }
    }

    private func render(vertices: [Vertex], glyphs: MTLTexture,
                        acquireTarget: () -> (MTLTexture, CAMetalDrawable?)?) -> MTLCommandBuffer?
    {
        guard !vertices.isEmpty, inFlight.wait(timeout: .now()) == .success else { return nil }
        let gate = inFlight
        var submitted = false
        defer {
            if !submitted {
                gate.signal()
            }
        }
        guard let (target, drawable) = acquireTarget(), target.pixelFormat == .rgba16Float,
              let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count),
              let command = queue.makeCommandBuffer() else { return nil }
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
        command.addCompletedHandler { _ in gate.signal() }
        submitted = true
        command.commit()
        return command
    }
}
