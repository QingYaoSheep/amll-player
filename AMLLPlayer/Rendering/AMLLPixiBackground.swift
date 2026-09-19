import MetalKit
import SwiftUI

/// Independent native implementation of the pinned Pixi sprite/filter pipeline.
struct AMLLPixiBackground: UIViewRepresentable {
    var artworkURL: URL?
    var active: Bool
    var seed: UInt32? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeCoordinator() -> Coordinator {
        Coordinator(seed: seed ?? UInt32.random(in: 1 ... .max))
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = true
        view.backgroundColor = .black
        view.preferredFramesPerSecond = 30 // Source default; independent of lyric display link.
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        if active {
            context.coordinator.setArtwork(artworkURL)
        }
        context.coordinator.setRunning(active && !reduceMotion && !reduceTransparency, staticMode: reduceMotion || reduceTransparency)
        view.alpha = reduceTransparency ? 0 : 1
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.stop()
        view.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, MTKViewDelegate {
        private struct Layer {
            var texture: MTLTexture
            var state: AMLLPixiState
            var sprites: [SIMD4<Float>]
        }

        private weak var view: MTKView?
        private var queue: MTLCommandQueue?
        private var pipelines: [String: MTLRenderPipelineState] = [:]
        private var layers: [Layer] = []
        private var textures: [MTLTexture] = []
        private var random: AMLLMeshPreset.Random
        private var centers: [SIMD2<Float>] = []
        private var lastFrame: CFTimeInterval?
        private var running = false
        private var staticMode = false
        private var url: URL?
        private var task: Task<Void, Never>?
        private let inFlight = DispatchSemaphore(value: 3)

        init(seed: UInt32) {
            random = .init(state: seed); super.init()
        }

        func attach(_ view: MTKView) {
            self.view = view
            guard let device = view.device, let library = device.makeDefaultLibrary() else { return }
            queue = device.makeCommandQueue()
            for name in ["Sprites", "Blur", "Color", "Bulge", "Copy"] {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "amllPixiQuad")
                descriptor.fragmentFunction = library.makeFunction(name: "amllPixi" + name)
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                if name == "Sprites" {
                    let attachment = descriptor.colorAttachments[0]!
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                pipelines[name] = try? device.makeRenderPipelineState(descriptor: descriptor)
            }
            view.delegate = self
        }

        func setRunning(_ value: Bool, staticMode: Bool) {
            if running != value {
                lastFrame = nil
            }
            running = value
            self.staticMode = staticMode
            view?.isPaused = !value
            view?.enableSetNeedsDisplay = !value
            if !value {
                view?.setNeedsDisplay()
            }
        }

        func setArtwork(_ value: URL?) {
            guard value != url else { return }
            url = value
            task?.cancel()
            guard let value else { layers.removeAll(); view?.setNeedsDisplay(); return }
            task = Task { [weak self] in
                do {
                    let (data, _) = try await URLSession.shared.data(from: value)
                    try Task.checkCancellation()
                    guard let self, self.url == value, let device = self.view?.device,
                          let image = UIImage(data: data)?.cgImage else { return }
                    let texture = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false])
                    let rotations = (0 ..< 4).map { _ in self.random.next() * .pi * 2 }
                    let state = AMLLPixiState(rotations: rotations)
                    let size = self.textures.first.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
                    self.layers.removeAll { $0.state.alpha <= 0 }
                    self.layers.append(.init(texture: texture, state: state,
                                             sprites: state.sprites(width: size.width, height: size.height)))
                    self.view?.setNeedsDisplay()
                } catch { /* Keep the previous cover until a usable replacement is available. */ }
            }
        }

        func stop() {
            task?.cancel(); task = nil; view?.isPaused = true
        }

        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

        private func prepareTextures(width: Int, height: Int, device: MTLDevice) -> Bool {
            if textures.first?.width == width, textures.first?.height == height {
                return true
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            let replacements = (0 ..< 2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard replacements.count == 2 else { return false }
            textures = replacements
            let left: Float = random.next() > 0.5 ? 0.25 : 0.75
            centers = [SIMD2(left, 1), SIMD2(1 - left, 0)]
            return true
        }

        func draw(in view: MTKView) {
            guard pipelines.count == 5, let device = view.device, let queue,
                  view.drawableSize.width > 0, view.drawableSize.height > 0,
                  inFlight.wait(timeout: .now()) == .success else { return }
            var submitted = false
            defer {
                if !submitted {
                    inFlight.signal()
                }
            }
            guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
            // BaseRenderer's actual default is .75, despite older interface comments saying .5.
            let width = max(1, Int(view.drawableSize.width * 0.75))
            let height = max(1, Int(view.drawableSize.height * 0.75))
            guard prepareTextures(width: width, height: height, device: device) else { return }
            let now = CACurrentMediaTime()
            // Pinned Pixi Ticker caps elapsedMS at 100 before producing deltaTime.
            let elapsed = running ? min(0.1, max(0, now - (lastFrame ?? now))) : 0
            lastFrame = now
            if staticMode, let latest = layers.last {
                layers = [latest]; layers[0].state.alpha = 1
            }
            if !layers.isEmpty {
                for index in layers.indices {
                    if index == layers.count - 1 {
                        layers[index].state.advance(seconds: elapsed)
                        layers[index].sprites = layers[index].state.sprites(width: Double(width), height: Double(height))
                    } else {
                        layers[index].state.alpha = max(0, layers[index].state.alpha - elapsed)
                    }
                }
                // Old containers retain their transforms and are destroyed once faded out.
                let latest = layers.removeLast()
                layers.removeAll { $0.state.alpha <= 0 }
                layers.append(latest)
            }
            let initial = MTLRenderPassDescriptor()
            initial.colorAttachments[0].texture = textures[0]
            initial.colorAttachments[0].loadAction = .clear
            initial.colorAttachments[0].storeAction = .store
            initial.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: initial), let spritesPipeline = pipelines["Sprites"] else { return }
            encoder.setRenderPipelineState(spritesPipeline)
            for layer in layers {
                var uniforms = [SIMD4(Float(width), Float(height), Float(layer.state.alpha), 0)] + layer.sprites
                uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                encoder.setFragmentTexture(layer.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            var current = 0
            func filter(_ name: String, _ value: SIMD4<Float>) -> Bool {
                let next = 1 - current
                guard pass(command, name: name, source: textures[current], target: textures[next], value: value) else { return false }
                current = next
                return true
            }
            func blur(_ strength: Float, quality: Int) -> Bool {
                for axis in 0 ..< 2 {
                    for _ in 0 ..< quality {
                        let step = strength / Float(quality)
                        guard filter("Blur", SIMD4(axis == 0 ? step / Float(width) : 0,
                                                   axis == 1 ? step / Float(height) : 0, 0, 0)) else { return false }
                    }
                }
                return true
            }
            for item in AMLLPixiState.blurPasses(minimumBorder: Double(min(width, height))) {
                guard blur(item.strength, quality: item.quality) else { return }
            }
            for operation in 0 ..< 3 {
                guard filter("Color", SIMD4(Float(operation), 0, 0, 0)) else { return }
            }
            guard blur(5, quality: 1) else { return }
            for center in centers {
                guard filter("Bulge", SIMD4(Float(width), Float(height), center.x, center.y)) else { return }
            }
            guard pass(command, name: "Copy", source: textures[current], target: drawable.texture, value: .zero) else { return }
            command.present(drawable)
            let semaphore = inFlight
            command.addCompletedHandler { _ in semaphore.signal() }
            command.commit()
            submitted = true
        }

        private func pass(_ command: MTLCommandBuffer, name: String, source: MTLTexture, target: MTLTexture, value: SIMD4<Float>) -> Bool {
            guard let pipeline = pipelines[name] else { return false }
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            var value = value
            encoder.setFragmentBytes(&value, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        }
    }
}
