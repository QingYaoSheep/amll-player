import MetalKit
import SwiftUI
import UIKit

struct AMLLMeshBackground: UIViewRepresentable {
    var artworkURL: URL?
    var active: Bool
    var blur: Double
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
        context.coordinator.setBlur(blur)
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
            var aspect: Float
        }

        private weak var view: MTKView?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var vertices: MTLBuffer?
        private var indices: MTLBuffer?
        private var indexCount = 0
        private var texture: MTLTexture?
        private var artworkURL: URL?
        private var artworkData: Data?
        private var blurRadius = 2
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
            let mesh = Self.makeMesh()
            vertices = device.makeBuffer(bytes: mesh.vertices, length: MemoryLayout<Vertex>.stride * mesh.vertices.count)
            indices = device.makeBuffer(bytes: mesh.indices, length: MemoryLayout<UInt32>.stride * mesh.indices.count)
            indexCount = mesh.indices.count
            texture = Self.fallbackTexture(device: device)
            view.delegate = self
        }

        func setArtwork(_ url: URL?) {
            guard artworkURL != url else { return }
            artworkURL = url
            loadTask?.cancel()
            guard let url, let device = view?.device else {
                artworkData = nil
                texture = view?.device.flatMap { Self.fallbackTexture(device: $0) }
                view?.setNeedsDisplay()
                return
            }
            texture = Self.fallbackTexture(device: device)
            view?.setNeedsDisplay()
            loadTask = Task { [weak self] in
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    try Task.checkCancellation()
                    guard let loaded = Self.albumTexture(data: data, device: device, blurRadius: self?.blurRadius ?? 2)
                    else { throw URLError(.cannotDecodeContentData) }
                    guard self?.artworkURL == url else { return }
                    self?.artworkData = data
                    self?.texture = loaded
                    self?.startedAt = CACurrentMediaTime()
                    self?.view?.setNeedsDisplay()
                } catch is CancellationError {
                    return
                } catch {
                    guard self?.artworkURL == url else { return }
                    self?.texture = Self.fallbackTexture(device: device)
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
            texture = rebuilt
            view?.setNeedsDisplay()
        }

        func stop() {
            loadTask?.cancel(); loadTask = nil
        }

        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let vertices, let indices, let texture, let queue,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            let height = max(1, view.drawableSize.height)
            var uniforms = Uniforms(
                time: Float((CACurrentMediaTime() - startedAt) / 10), volume: 0, alpha: 1,
                aspect: Float(view.drawableSize.width / height)
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: indexCount, indexType: .uint32,
                indexBuffer: indices, indexBufferOffset: 0
            )
            encoder.endEncoding()
            command.present(drawable)
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
            UInt8(clamping: Int(value.rounded()))
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

        private static func makeMesh() -> (vertices: [Vertex], indices: [UInt32]) {
            let points = amllControlPoints
            let controlSide = 5
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
                            let uvX = Float(controlX) / 4 + Float(horizontal) / Float((subdivisions - 1) * 4)
                            let uvY = 1 - Float(controlY) / 4 - Float(vertical) / Float((subdivisions - 1) * 4)
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
