@testable import AMLLPlayer
import MetalKit
import XCTest

@MainActor
final class LyricsHDRRendererTests: XCTestCase {
    func testFloatOutputBoostsOnlyFilledGlyphAndKeepsTransparentBackground() throws {
        let renderer = try XCTUnwrap(LyricsHDRRenderer(), "Metal shader library must be packaged in the test host")
        let glyphDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 1, mipmapped: false)
        glyphDescriptor.usage = .shaderRead
        glyphDescriptor.storageMode = .shared
        let glyphs = try XCTUnwrap(renderer.device.makeTexture(descriptor: glyphDescriptor))
        let pixels: [UInt8] = [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0]
        pixels.withUnsafeBytes {
            glyphs.replace(region: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 4, height: 1, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        // First two texels are sung; third is unsung; fourth has no glyph.
        let positions: [(Float, Float)] = [(-1, 1), (-1, -1), (1, 1), (1, 1), (-1, -1), (1, -1)]
        let vertices = positions.map { x, y in
            LyricsHDRRenderer.Vertex(position: .init(x, y), uv: .init((x + 1) / 2, (1 - y) / 2),
                                     mask: .init((x + 1) * 2, 2), appearance: .init(0.0001, 0.3, 1, 1.5))
        }
        let command = try XCTUnwrap(renderer.render(vertices: vertices, glyphs: glyphs, target: target))
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var output = [UInt16](repeating: 0, count: 16)
        output.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0)
        }
        let values = output.map { Float(Float16(bitPattern: $0)) }
        XCTAssertEqual(values[0], 1.5, accuracy: 0.002)
        XCTAssertEqual(values[4], 1.5, accuracy: 0.002)
        XCTAssertEqual(values[8], 0.3, accuracy: 0.002)
        XCTAssertEqual(values[11], 0.3, accuracy: 0.002)
        XCTAssertEqual(values[12], 0, accuracy: 0.002)
        XCTAssertEqual(values[15], 0, accuracy: 0.002)
    }

    func testLayerExplicitlyUsesExtendedLinearFloatOutput() throws {
        let renderer = try XCTUnwrap(LyricsHDRRenderer())
        let layer = renderer.makeLayer(size: .init(width: 120, height: 40), scale: 3)
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
        XCTAssertFalse(layer.isOpaque)
        XCTAssertEqual(layer.drawableSize, CGSize(width: 360, height: 120))
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.extendedLinearSRGB)
    }
}
