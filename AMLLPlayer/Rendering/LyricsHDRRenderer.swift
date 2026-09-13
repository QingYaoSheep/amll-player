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
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

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
        guard target.pixelFormat == .rgba16Float, !vertices.isEmpty,
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
        command.commit()
        return command
    }
}
