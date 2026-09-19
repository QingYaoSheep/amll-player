@testable import AMLLPlayer
import MetalKit
import XCTest

@MainActor
final class LyricsHDRRendererTests: XCTestCase {
    func testPortraitFadeBelongsToNativeCanvasAndClearsForLandscape() throws {
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        canvas.fadeTop = 167
        canvas.layoutSubviews()
        let mask = try XCTUnwrap(canvas.layer.mask as? CAGradientLayer)
        XCTAssertEqual(mask.frame, canvas.bounds)
        XCTAssertEqual(try XCTUnwrap(mask.locations?[1]).doubleValue, 167.0 / 874, accuracy: 0.0001)
        XCTAssertFalse(canvas.isOpaque)
        canvas.bounds.size.height = 600
        canvas.layoutSubviews()
        XCTAssertEqual(mask.frame, canvas.bounds)
        XCTAssertEqual(try XCTUnwrap(mask.locations?[1]).doubleValue, 167.0 / 600, accuracy: 0.0001)
        canvas.fadeTop = nil
        canvas.layoutSubviews()
        XCTAssertNil(canvas.layer.mask)
    }

    func testBusyRendererDoesNotAcquireDrawableAndFailedAcquisitionReleasesCapacity() throws {
        let renderer = try XCTUnwrap(LyricsHDRRenderer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let glyphs = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let vertices = [LyricsHDRRenderer.Vertex(position: .zero, uv: .zero, mask: .zero, appearance: .zero)]
        let layer = DrawableProbeLayer()
        var acquisitions = 0
        layer.acquire = {
            acquisitions += 1
            // Hold each reservation inside drawable acquisition. The fourth
            // request must be rejected before calling nextDrawable again.
            if acquisitions < 4 {
                XCTAssertNil(renderer.render(vertices: vertices, glyphs: glyphs, layer: layer))
            }
        }
        XCTAssertNil(renderer.render(vertices: vertices, glyphs: glyphs, layer: layer))
        XCTAssertEqual(acquisitions, 3)
        layer.acquire = { acquisitions += 1 }
        XCTAssertNil(renderer.render(vertices: vertices, glyphs: glyphs, layer: layer))
        XCTAssertEqual(acquisitions, 4, "Failed acquisition must release the reservation")
        XCTAssertNil(renderer.render(vertices: [], glyphs: glyphs, layer: layer))
        XCTAssertEqual(acquisitions, 4, "Empty frames must not acquire a drawable")
        layer.acquire = nil
    }

    func testRealCanvasCreatesAndRemovesReplacementLayersWithHDRSetting() throws {
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        canvas.hdrCapabilitiesOverride = .init(supportsEDR: true, headroom: 2)
        defer { canvas.stop(); canvas.removeFromSuperview(); window.isHidden = true }
        let line = LyricLine(id: "hdr", text: "Held", start: 1, end: 10,
                             words: [.init(text: "Held", start: 1, end: 10)], precision: .word)
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "hdr", title: "HDR", artists: []),
                                      lines: [line], language: "en", selectionReason: "HDR wiring test")
        canvas.position = { 3 }
        var configuration = LyricsRenderConfiguration()
        configuration.hdr = .init(enabled: true)
        configuration.blurInactive = false
        canvas.configure(document: document, configuration: configuration, input: .init(position: 3, playing: false),
                         active: false, reduceMotion: false)
        canvas.advanceFrame(delta: 0)
        XCTAssertTrue(canvas.window === window, "HDR rows need the hosting window")
        let frame = try XCTUnwrap(canvas.frameState, "Canvas must lay out before HDR sampling")
        XCTAssertEqual(frame.lyricTime, 3, accuracy: 0.0001)
        XCTAssertFalse(frame.rows.isEmpty, "Initial frame must contain the source line")
        let renderer = try XCTUnwrap(LyricsHDRRenderer())
        let layout = AMLLCoreTextLayout(line: line, width: 362, font: .systemFont(ofSize: 32), configuration: configuration)
        let glyphs = try XCTUnwrap(layout.raster(scale: window.screen.scale, auxiliary: false, ruby: false).cgImage)
        XCTAssertNotNil(renderer.glyphTexture(glyphs), "Production Core Text atlas must upload to Metal")
        func metalLayers(_ layer: CALayer) -> [CAMetalLayer] {
            if let metal = layer as? CAMetalLayer {
                return [metal]
            }
            var result: [CAMetalLayer] = []
            for child in layer.sublayers ?? [] {
                result.append(contentsOf: metalLayers(child))
            }
            return result
        }
        XCTAssertFalse(metalLayers(canvas.layer).isEmpty, "Production canvas must consume the HDR renderer")
        XCTAssertTrue(metalLayers(canvas.layer).allSatisfy { $0.pixelFormat == .rgba16Float })
        configuration.hdr = .init(enabled: false)
        canvas.configure(document: document, configuration: configuration, input: .init(position: 3, playing: false),
                         active: false, reduceMotion: false)
        canvas.advanceFrame(delta: 0)
        XCTAssertTrue(metalLayers(canvas.layer).isEmpty)
    }

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

private final class DrawableProbeLayer: CAMetalLayer {
    var acquire: (() -> Void)?

    override func nextDrawable() -> CAMetalDrawable? {
        acquire?()
        return nil
    }
}
