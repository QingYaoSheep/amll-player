@testable import AMLLPlayer
import MetalKit
import XCTest

@MainActor
final class AMLLFlowingBackgroundRendererTests: XCTestCase {
    private func texture(_ renderer: AMLLFlowingBackgroundRenderer, width: Int = 64, height: Int = 64,
                         pixel: (Int, Int) -> [UInt8]) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        var bytes: [UInt8] = []
        for y in 0 ..< height { for x in 0 ..< width { bytes.append(contentsOf: pixel(x, y)) } }
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return texture
    }

    private func target(_ renderer: AMLLFlowingBackgroundRenderer, width: Int = 96, height: Int = 64) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        return try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
    }

    private func pixels(_ target: any MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: target.width * 4,
                                                       from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0) }
        return bytes
    }

    private func draw(_ renderer: AMLLFlowingBackgroundRenderer, _ target: any MTLTexture,
                      state: AMLLFlowingBackgroundState, scale: Double = 1) throws -> [UInt8] {
        let command = try XCTUnwrap(renderer.render(target: target,
            size: .init(width: Double(target.width) / scale, height: Double(target.height) / scale), state: state))
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        return pixels(target)
    }

    func testOpaqueCoverKeepsItsColorAtCornersForAllRatiosRotationsAndBlur() throws {
        let renderer = try XCTUnwrap(AMLLFlowingBackgroundRenderer())
        renderer.install(try texture(renderer, width: 32, height: 64) { _, _ in [210, 140, 60, 255] }, interrupting: false)
        for (width, height) in [(48, 96), (96, 48), (64, 64), (32, 96)] {
            let target = try target(renderer, width: width, height: height)
            for sigma in [0.0, 8.0, 40.0] {
                var state = AMLLFlowingBackgroundState()
                state.configure(.init(distortion: 8, blur: sigma), immediately: true)
                for _ in 0 ..< 4 {
                    state.advance(seconds: 60)
                    let bytes = try draw(renderer, target, state: state)
                    for index in [0, width - 1, width * (height - 1), width * height - 1, width * height / 2] {
                        XCTAssertEqual(Double(bytes[index * 4]), 60, accuracy: 1)
                        XCTAssertEqual(Double(bytes[index * 4 + 1]), 140, accuracy: 1)
                        XCTAssertEqual(Double(bytes[index * 4 + 2]), 210, accuracy: 1)
                        XCTAssertEqual(bytes[index * 4 + 3], 255)
                    }
                }
            }
        }
    }

    func testGaussianFiltersTheAlreadyWarpedFrameAndUsesViewportPoints() throws {
        let renderer = try XCTUnwrap(AMLLFlowingBackgroundRenderer())
        renderer.install(try texture(renderer) { x, y in
            (x / 8 + y / 8) % 2 == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }, interrupting: false)
        let target = try target(renderer)
        var state = AMLLFlowingBackgroundState()
        state.configure(.init(distortion: 8, blur: 0), immediately: true)
        state.advance(seconds: 37)
        let sharp = try draw(renderer, target, state: state)
        state.configure(.init(distortion: 8, blur: 4), immediately: true)
        let blurred = try draw(renderer, target, state: state, scale: 2)
        // Independent CPU Gaussian of the rendered (already transformed) image.
        // 4pt at 2px/pt gives sigma 8px. MPS is an image-processing approximation.
        let sigma = 8.0, radius = 24
        let weights = (-radius ... radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let normalization = weights.reduce(0, +)
        for (x, y) in [(0, 0), (30, 18), (48, 32), (70, 45), (95, 63)] {
            var expected = 0.0
            for dy in -radius ... radius {
                for dx in -radius ... radius {
                    let px = min(95, max(0, x + dx)), py = min(63, max(0, y + dy))
                    expected += Double(sharp[(py * 96 + px) * 4]) * weights[dx + radius] * weights[dy + radius]
                }
            }
            expected /= normalization * normalization
            XCTAssertEqual(Double(blurred[(y * 96 + x) * 4]), expected, accuracy: 7)
        }
        let sharpRange = (0 ..< 96 * 64).map { Int(sharp[$0 * 4]) }
        let softRange = (0 ..< 96 * 64).map { Int(blurred[$0 * 4]) }
        XCTAssertLessThan(try XCTUnwrap(softRange.max()) - XCTUnwrap(softRange.min()),
                          try XCTUnwrap(sharpRange.max()) - XCTUnwrap(sharpRange.min()))
    }

    func testInterruptedCrossfadeStartsFromTheActualCompositeWithoutDoubleWarp() throws {
        let renderer = try XCTUnwrap(AMLLFlowingBackgroundRenderer())
        let target = try target(renderer)
        var state = AMLLFlowingBackgroundState()
        state.configure(.init(distortion: 8, blur: 0), immediately: true)
        XCTAssertFalse(renderer.install(try texture(renderer) { x, _ in x < 32 ? [255, 0, 0, 255] : [0, 255, 255, 255] },
                                        interrupting: false))
        state.advance(seconds: 17)
        _ = try draw(renderer, target, state: state)
        XCTAssertTrue(renderer.install(try texture(renderer) { _, _ in [0, 0, 255, 255] }, interrupting: false))
        state.beginArtworkTransition(hasPrevious: true)
        state.advance(seconds: 0.5)
        let before = try draw(renderer, target, state: state)
        XCTAssertTrue(renderer.install(try texture(renderer) { _, _ in [0, 255, 0, 255] }, interrupting: true))
        let angle = state.angle
        state.beginArtworkTransition(hasPrevious: true)
        let after = try draw(renderer, target, state: state)
        XCTAssertEqual(state.angle, angle)
        XCTAssertEqual(before, after, "Rapid replacement must start at the visible composite, not either source cover")
        state.advance(seconds: 1)
        let finished = try draw(renderer, target, state: state)
        XCTAssertEqual(Array(finished.prefix(4)), [0, 255, 0, 255])
        let allocations = renderer.statistics.allocatedTargetSets
        for _ in 0 ..< 30 {
            state.advance(seconds: 1.0 / 60)
            _ = try draw(renderer, target, state: state)
        }
        XCTAssertEqual(renderer.statistics.allocatedTargetSets, allocations)
        XCTAssertLessThanOrEqual(renderer.statistics.inFlight, 2)
        XCTAssertLessThanOrEqual(renderer.statistics.residentTextureBytes, 96 * 64 * 4 * 4 + 64 * 64 * 4)
        let report: [String: Any] = ["frames": renderer.statistics.submittedFrames,
                                   "cpuP95Ms": renderer.statistics.cpuP95 * 1000,
                                   "gpuP95Ms": renderer.statistics.gpuP95 * 1000,
                                   "textureBytes": renderer.statistics.residentTextureBytes,
                                   "devicePerformanceAcceptance": "pending"]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted),
                                      uniformTypeIdentifier: "public.json")
        attachment.name = "flowing-background-gpu-smoke-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
