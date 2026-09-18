import MetalKit
import SwiftUI
import UIKit

struct AMLLMeshBackground: UIViewRepresentable {
    var artworkURL: URL?
    var active: Bool
    var blur: Double
    /// Debug/reference playback can inject a seed; production seeds once per context.
    var seed: UInt32? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeCoordinator() -> Coordinator {
        Coordinator(seed: seed ?? UInt32.random(in: 1 ... UInt32.max))
    }

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
        context.coordinator.setBlur(blur)
        context.coordinator.setArtwork(artworkURL)
        view.preferredFramesPerSecond = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        let shouldAnimate = active && !reduceMotion && !reduceTransparency
        context.coordinator.setRunning(shouldAnimate)
        view.isPaused = !shouldAnimate
        view.enableSetNeedsDisplay = !shouldAnimate
        view.alpha = reduceTransparency ? 0 : 1
        if !shouldAnimate {
            view.setNeedsDisplay()
        }
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
            var aspect: Float
        }

        private weak var view: MTKView?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private struct MeshState {
            var texture: MTLTexture
            var vertices: MTLBuffer
            var indices: MTLBuffer
            var count: Int
            var alpha: Double
        }

        private var states: [MeshState] = []
        private var compositePipeline: MTLRenderPipelineState?
        private var intermediate: MTLTexture?
        private var random: AMLLMeshPreset.Random
        private var lastFrame: CFTimeInterval?
        private var hasCover = false
        private var running = false
        private var animationTime: TimeInterval = 0
        private let inFlight = DispatchSemaphore(value: 3)
        private var artworkURL: URL?
        private var artworkData: Data?
        private var blurRadius = 2
        private var loadTask: Task<Void, Never>?

        init(seed: UInt32) {
            random = AMLLMeshPreset.Random(state: seed)
            super.init()
        }

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
            let composite = MTLRenderPipelineDescriptor()
            composite.vertexFunction = library.makeFunction(name: "amllBackgroundQuad")
            composite.fragmentFunction = library.makeFunction(name: "amllBackgroundComposite")
            let attachment = composite.colorAttachments[0]!
            attachment.pixelFormat = view.colorPixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            compositePipeline = try? device.makeRenderPipelineState(descriptor: composite)
            queue = device.makeCommandQueue()
            view.delegate = self
        }

        func setArtwork(_ url: URL?) {
            guard artworkURL != url else { return }
            artworkURL = url
            loadTask?.cancel()
            guard let url, let device = view?.device else {
                artworkData = nil
                hasCover = false
                view?.setNeedsDisplay()
                return
            }
            // Keep the previous cover until the replacement has decoded. A
            // network request is not a visual state, and must not flash gray.
            loadTask = Task { [weak self] in
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    try Task.checkCancellation()
                    guard let loaded = Self.albumTexture(data: data, device: device, blurRadius: self?.blurRadius ?? 2)
                    else { throw URLError(.cannotDecodeContentData) }
                    guard self?.artworkURL == url else { return }
                    self?.artworkData = data
                    self?.install(loaded, device: device)
                    // The mesh clock belongs to the page, not to the artwork
                    // request. Reloading a cover after a cache miss must not
                    // reset the animation phase during a track change,
                    // rotation, or foreground transition.
                    self?.view?.setNeedsDisplay()
                } catch is CancellationError {
                    return
                } catch {
                    guard self?.artworkURL == url else { return }
                    // An unavailable replacement leaves the last valid frame.
                    // Empty canvases retain the neutral clear color.
                    self?.view?.setNeedsDisplay()
                }
            }
        }

        func setBlur(_ value: Double) {
            let next = min(4, max(0, Int((value / 20).rounded())))
            guard next != blurRadius else { return }
            blurRadius = next
            guard let artworkData, let device = view?.device,
                  let rebuilt = Self.albumTexture(data: artworkData, device: device, blurRadius: next)
            else { return }
            if !states.isEmpty {
                states[states.count - 1].texture = rebuilt
            }
            view?.setNeedsDisplay()
        }

        func stop() {
            loadTask?.cancel(); loadTask = nil
        }

        func setRunning(_ value: Bool) {
            guard running != value else { return }
            running = value
            lastFrame = nil
        }

        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {
            intermediate = nil
        }

        private func install(_ texture: MTLTexture, device: MTLDevice) {
            let presets = (try? AMLLMeshPreset.loadPresets()) ?? []
            let preset: AMLLMeshPreset?
            if random.next() > 0.8 || presets.isEmpty {
                preset = AMLLMeshPreset.generate(random: &random)
            } else {
                preset = presets[Int(random.next() * Double(presets.count))]
            }
            let mesh = Self.makeMesh(preset: preset)
            guard let vertices = device.makeBuffer(bytes: mesh.vertices, length: MemoryLayout<Vertex>.stride * mesh.vertices.count),
                  let indices = device.makeBuffer(bytes: mesh.indices, length: MemoryLayout<UInt32>.stride * mesh.indices.count) else { return }
            hasCover = true
            states.append(MeshState(texture: texture, vertices: vertices, indices: indices, count: mesh.indices.count, alpha: 0))
        }

        func draw(in view: MTKView) {
            guard inFlight.wait(timeout: .now()) == .success else { return }
            var submitted = false
            defer {
                if !submitted {
                    inFlight.signal()
                }
            }
            guard let pipeline, let compositePipeline, let queue, let device = view.device,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer() else { return }
            let now = CACurrentMediaTime()
            let delta = lastFrame.map { max(0, now - $0) } ?? 0
            lastFrame = now
            if running {
                animationTime += delta
            }
            if view.isPaused {
                if hasCover, let latest = states.last {
                    states = [latest]; states[0].alpha = 1.1
                } else {
                    states.removeAll()
                }
            } else if !hasCover {
                states.removeAll { $0.alpha <= -0.1 }
                for index in states.indices {
                    states[index].alpha = max(-0.1, states[index].alpha - delta / 0.5)
                }
            } else if let latest = states.last {
                if latest.alpha >= 1.1 {
                    states = [latest]
                } else {
                    states[states.count - 1].alpha = min(1.1, latest.alpha + delta / 0.5)
                }
            }
            if intermediate == nil {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.colorPixelFormat,
                                                                          width: max(1, drawable.texture.width), height: max(1, drawable.texture.height), mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                intermediate = device.makeTexture(descriptor: descriptor)
            }
            guard let intermediate else { return }
            let height = max(1, view.drawableSize.height)
            var uniforms = Uniforms(
                time: Float(animationTime / 10), volume: 0, alpha: 1,
                aspect: Float(view.drawableSize.width / height)
            )
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.08, 0.08, 0.08, 1)
            pass.colorAttachments[0].storeAction = .store
            // Composite only completed mesh images; blending triangles directly
            // would double-blend folded/overlapping cells.
            for state in states {
                let offscreen = MTLRenderPassDescriptor()
                offscreen.colorAttachments[0].texture = intermediate
                offscreen.colorAttachments[0].loadAction = .clear
                offscreen.colorAttachments[0].storeAction = .store
                guard let encoder = command.makeRenderCommandEncoder(descriptor: offscreen) else { return }
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(state.vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentTexture(state.texture, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: state.count, indexType: .uint32,
                                              indexBuffer: state.indices, indexBufferOffset: 0)
                encoder.endEncoding()
                guard let composite = command.makeRenderCommandEncoder(descriptor: pass) else { return }
                var alpha = Float((1 - cos(Double.pi * min(1, max(0, state.alpha)))) / 2)
                composite.setRenderPipelineState(compositePipeline)
                composite.setFragmentTexture(intermediate, index: 0)
                composite.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
                composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                composite.endEncoding()
                pass.colorAttachments[0].loadAction = .load
            }
            if states.isEmpty {
                command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            command.present(drawable)
            let semaphore = inFlight
            command.addCompletedHandler { _ in semaphore.signal() }
            submitted = true
            command.commit()
        }

        /// Reproduces AMLL's 32×32 low-quality resize, color matrix, and four-pass box blur.
        private static func albumTexture(data: Data, device: MTLDevice, blurRadius: Int) -> MTLTexture? {
            guard let image = UIImage(data: data)?.cgImage else { return nil }
            let side = 32
            let bytesPerRow = side * 4
            var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress,
                      let context = CGContext(
                          data: baseAddress, width: side, height: side, bitsPerComponent: 8,
                          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard rendered else { return nil }
            for index in stride(from: 0, to: pixels.count, by: 4) {
                var red = (Double(pixels[index]) - 128) * 0.4 + 128
                var green = (Double(pixels[index + 1]) - 128) * 0.4 + 128
                var blue = (Double(pixels[index + 2]) - 128) * 0.4 + 128
                let gray = red * 0.3 + green * 0.59 + blue * 0.11
                red = ((gray * -2 + red * 3 - 128) * 1.7 + 128) * 0.75
                green = ((gray * -2 + green * 3 - 128) * 1.7 + 128) * 0.75
                blue = ((gray * -2 + blue * 3 - 128) * 1.7 + 128) * 0.75
                pixels[index] = clampedByte(red)
                pixels[index + 1] = clampedByte(green)
                pixels[index + 2] = clampedByte(blue)
            }
            if blurRadius > 0 {
                blur(&pixels, width: side, height: side, radius: blurRadius, quality: 4)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            pixels.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                        withBytes: baseAddress, bytesPerRow: bytesPerRow
                    )
                }
            }
            return texture
        }

        private static func clampedByte(_ value: Double) -> UInt8 {
            UInt8(clamping: Int(value.rounded(.toNearestOrEven)))
        }

        private static func blur(_ pixels: inout [UInt8], width: Int, height: Int, radius: Int, quality: Int) {
            let maximumX = width - 1
            let maximumY = height - 1
            let radiusPlusOne = radius + 1
            let divisor = Double((radius + radiusPlusOne) * (radius + radiusPlusOne))
            var red = [Int](repeating: 0, count: width * height)
            var green = red
            var blue = red
            var alpha = red
            var minimum = [Int](repeating: 0, count: max(width, height))
            var maximum = minimum

            for _ in 0 ..< quality {
                var sourceRow = 0
                var outputIndex = 0
                for y in 0 ..< height {
                    var redSum = Int(pixels[sourceRow]) * radiusPlusOne
                    var greenSum = Int(pixels[sourceRow + 1]) * radiusPlusOne
                    var blueSum = Int(pixels[sourceRow + 2]) * radiusPlusOne
                    var alphaSum = Int(pixels[sourceRow + 3]) * radiusPlusOne
                    for offset in 1 ... radius {
                        var source = sourceRow + min(offset, maximumX) * 4
                        redSum += Int(pixels[source]); source += 1
                        greenSum += Int(pixels[source]); source += 1
                        blueSum += Int(pixels[source]); source += 1
                        alphaSum += Int(pixels[source])
                    }
                    for x in 0 ..< width {
                        red[outputIndex] = redSum
                        green[outputIndex] = greenSum
                        blue[outputIndex] = blueSum
                        alpha[outputIndex] = alphaSum
                        if y == 0 {
                            minimum[x] = min(x + radiusPlusOne, maximumX) * 4
                            maximum[x] = max(x - radius, 0) * 4
                        }
                        var incoming = sourceRow + minimum[x]
                        var outgoing = sourceRow + maximum[x]
                        redSum += Int(pixels[incoming]) - Int(pixels[outgoing]); incoming += 1; outgoing += 1
                        greenSum += Int(pixels[incoming]) - Int(pixels[outgoing]); incoming += 1; outgoing += 1
                        blueSum += Int(pixels[incoming]) - Int(pixels[outgoing]); incoming += 1; outgoing += 1
                        alphaSum += Int(pixels[incoming]) - Int(pixels[outgoing])
                        outputIndex += 1
                    }
                    sourceRow += bytesPerRow(width: width)
                }

                for x in 0 ..< width {
                    var source = x
                    var redSum = red[source] * radiusPlusOne
                    var greenSum = green[source] * radiusPlusOne
                    var blueSum = blue[source] * radiusPlusOne
                    var alphaSum = alpha[source] * radiusPlusOne
                    if radius > 0 {
                        for offset in 1 ... radius {
                            source += offset > maximumY ? 0 : width
                            redSum += red[source]
                            greenSum += green[source]
                            blueSum += blue[source]
                            alphaSum += alpha[source]
                        }
                    }
                    var destination = x * 4
                    for y in 0 ..< height {
                        pixels[destination] = clampedByte(Double(redSum) / divisor)
                        pixels[destination + 1] = clampedByte(Double(greenSum) / divisor)
                        pixels[destination + 2] = clampedByte(Double(blueSum) / divisor)
                        pixels[destination + 3] = clampedByte(Double(alphaSum) / divisor)
                        if x == 0 {
                            minimum[y] = min(y + radiusPlusOne, maximumY) * width
                            maximum[y] = max(y - radius, 0) * width
                        }
                        let incoming = x + minimum[y]
                        let outgoing = x + maximum[y]
                        redSum += red[incoming] - red[outgoing]
                        greenSum += green[incoming] - green[outgoing]
                        blueSum += blue[incoming] - blue[outgoing]
                        alphaSum += alpha[incoming] - alpha[outgoing]
                        destination += bytesPerRow(width: width)
                    }
                }
            }
        }

        private static func bytesPerRow(width: Int) -> Int {
            width * 4
        }

        private struct ControlPoint {
            var position: SIMD2<Float>
            var uTangent: SIMD2<Float>
            var vTangent: SIMD2<Float>

            init(_ x: Float, _ y: Float, _ uRotation: Float = 0, _ vRotation: Float = 0,
                 _ uScale: Float = 1, _ vScale: Float = 1)
            {
                let radians = Float.pi / 180
                position = [x, y]
                uTangent = [cos(uRotation * radians) * uScale * 0.5, sin(uRotation * radians) * uScale * 0.5]
                vTangent = [-sin(vRotation * radians) * vScale * 0.5, cos(vRotation * radians) * vScale * 0.5]
            }
        }

        private static func makeMesh(preset: AMLLMeshPreset? = nil) -> (vertices: [Vertex], indices: [UInt32]) {
            // Source presets and generated grids use the same tangent powers.
            let source = preset ?? (try? AMLLMeshPreset.loadPresets())?.first
            let points: [ControlPoint]
            let controlSide: Int
            if let source, source.width == source.height, source.width >= 2, source.conf.count == source.width * source.height {
                controlSide = source.width
                let power = Float(4) / Float(controlSide - 1)
                points = source.conf.sorted { $0.cy * controlSide + $0.cx < $1.cy * controlSide + $1.cx }.map {
                    ControlPoint(Float($0.x), Float($0.y), Float($0.ur), Float($0.vr), Float($0.up) * power, Float($0.vp) * power)
                }
            } else {
                controlSide = 5
                points = amllControlPoints
            }
            let subdivisions = 50
            let meshSide = (controlSide - 1) * subdivisions
            var vertices = [Vertex](repeating: Vertex(position: .zero, uv: .zero), count: meshSide * meshSide)
            for controlY in 0 ..< controlSide - 1 {
                for controlX in 0 ..< controlSide - 1 {
                    let point00 = points[controlX + controlY * controlSide]
                    let point01 = points[controlX + (controlY + 1) * controlSide]
                    let point10 = points[controlX + 1 + controlY * controlSide]
                    let point11 = points[controlX + 1 + (controlY + 1) * controlSide]
                    for vertical in 0 ..< subdivisions {
                        let u = Float(vertical) / Float(subdivisions - 1)
                        for horizontal in 0 ..< subdivisions {
                            let v = Float(horizontal) / Float(subdivisions - 1)
                            let position = bicubic(point00, point01, point10, point11, u: u, v: v)
                            let meshX = controlY * subdivisions + vertical
                            let meshY = controlX * subdivisions + horizontal
                            let uvX = Float(controlX) / Float(controlSide - 1) + Float(horizontal) / Float((subdivisions - 1) * (controlSide - 1))
                            let uvY = 1 - Float(controlY) / Float(controlSide - 1) - Float(vertical) / Float((subdivisions - 1) * (controlSide - 1))
                            vertices[meshX + meshY * meshSide] = Vertex(position: position, uv: [uvX, uvY])
                        }
                    }
                }
            }
            var indices: [UInt32] = []
            indices.reserveCapacity((meshSide - 1) * (meshSide - 1) * 6)
            for y in 0 ..< meshSide - 1 {
                for x in 0 ..< meshSide - 1 {
                    let topLeft = UInt32(x + y * meshSide)
                    let topRight = topLeft + 1
                    let bottomLeft = topLeft + UInt32(meshSide)
                    let bottomRight = bottomLeft + 1
                    indices.append(contentsOf: [topLeft, topRight, bottomLeft, topRight, bottomRight, bottomLeft])
                }
            }
            return (vertices, indices)
        }

        private static func bicubic(_ point00: ControlPoint, _ point01: ControlPoint,
                                    _ point10: ControlPoint, _ point11: ControlPoint,
                                    u: Float, v: Float) -> SIMD2<Float>
        {
            let left = hermite(point00.position, point01.position, point00.vTangent, point01.vTangent, u)
            let right = hermite(point10.position, point11.position, point10.vTangent, point11.vTangent, u)
            let leftTangent = hermite(point00.uTangent, point01.uTangent, .zero, .zero, u)
            let rightTangent = hermite(point10.uTangent, point11.uTangent, .zero, .zero, u)
            return hermite(left, right, leftTangent, rightTangent, v)
        }

        private static func hermite(_ start: SIMD2<Float>, _ end: SIMD2<Float>,
                                    _ startTangent: SIMD2<Float>, _ endTangent: SIMD2<Float>,
                                    _ value: Float) -> SIMD2<Float>
        {
            let squared = value * value
            let cubed = squared * value
            return start * (2 * cubed - 3 * squared + 1)
                + startTangent * (cubed - 2 * squared + value)
                + end * (-2 * cubed + 3 * squared)
                + endTangent * (cubed - squared)
        }

        /// First immutable control-point preset from AMLL core 0.5.2.
        private static let amllControlPoints: [ControlPoint] = [
            .init(-1, -1), .init(-0.5, -1), .init(0, -1), .init(0.5, -1), .init(1, -1),
            .init(-1, -0.5), .init(-0.5, -0.5), .init(-0.005_202_968_4, -0.613_142_1),
            .init(0.588_422_7, -0.399_080_5), .init(1, -0.5),
            .init(-1, 0), .init(-0.421_002_48, -0.118_950_58),
            .init(-0.101_961_34, -0.023_812_119, 0, -47, 0.629, 0.849),
            .init(0.402_751_27, -0.063_453_145), .init(1, 0),
            .init(-1, 0.5), .init(0.068_019_584, 0.520_591_3, -31, -45),
            .init(0.214_464_7, 0.293_316_1, 6, -56, 0.566, 1.321),
            .init(0.5, 0.5), .init(1, 0.5),
            .init(-1, 1), .init(-0.313_783_74, 1), .init(0.261_536_33, 1), .init(0.5, 1), .init(1, 1),
        ]
    }
}
