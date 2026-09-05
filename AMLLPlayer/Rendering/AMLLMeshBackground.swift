import MetalKit
import SwiftUI

struct AMLLMeshBackground: UIViewRepresentable {
    var artworkURL: URL?
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = true
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.setArtwork(artworkURL)
        view.preferredFramesPerSecond = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        let shouldAnimate = active && !reduceMotion && !reduceTransparency
        view.isPaused = !shouldAnimate
        view.enableSetNeedsDisplay = !shouldAnimate
        view.alpha = reduceTransparency ? 0 : 1
        if !shouldAnimate { view.setNeedsDisplay() }
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private struct Vertex {
            var position: SIMD2<Float>
            var uv: SIMD2<Float>
        }

        private struct Uniforms {
            var time: Float
            var volume: Float
            var alpha: Float
            var padding: Float = 0
        }

        private weak var view: MTKView?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var vertices: MTLBuffer?
        private var texture: MTLTexture?
        private var artworkURL: URL?
        private var loadTask: Task<Void, Never>?
        private var startedAt = CACurrentMediaTime()

        func attach(to view: MTKView) {
            self.view = view
            guard let device = view.device,
                  let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "amllMeshVertex"),
                  let fragment = library.makeFunction(name: "amllMeshFragment") else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            queue = device.makeCommandQueue()
            let values: [Vertex] = [
                Vertex(position: [-1, -1], uv: [0, 1]), Vertex(position: [1, -1], uv: [1, 1]),
                Vertex(position: [-1, 1], uv: [0, 0]), Vertex(position: [-1, 1], uv: [0, 0]),
                Vertex(position: [1, -1], uv: [1, 1]), Vertex(position: [1, 1], uv: [1, 0]),
            ]
            vertices = device.makeBuffer(bytes: values, length: MemoryLayout<Vertex>.stride * values.count)
            texture = Self.fallbackTexture(device: device)
            view.delegate = self
        }

        func setArtwork(_ url: URL?) {
            guard artworkURL != url else { return }
            artworkURL = url
            loadTask?.cancel()
            guard let url, let device = view?.device else {
                texture = view?.device.flatMap { Self.fallbackTexture(device: $0) }
                return
            }
            loadTask = Task { [weak self] in
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    try Task.checkCancellation()
                    let loaded = try MTKTextureLoader(device: device).newTexture(
                        data: data,
                        options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]
                    )
                    guard self?.artworkURL == url else { return }
                    self?.texture = loaded
                    self?.startedAt = CACurrentMediaTime()
                    self?.view?.setNeedsDisplay()
                } catch is CancellationError {
                    return
                } catch {
                    guard self?.artworkURL == url else { return }
                    self?.texture = Self.fallbackTexture(device: device)
                }
            }
        }

        func stop() {
            loadTask?.cancel(); loadTask = nil
        }

        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let vertices, let texture, let queue,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            var uniforms = Uniforms(time: Float((CACurrentMediaTime() - startedAt) / 10), volume: 0, alpha: 1)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }

        private static func fallbackTexture(device: MTLDevice) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let pixel: [UInt8] = [28, 28, 28, 255]
            pixel.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: 4)
                }
            }
            return texture
        }
    }
}
