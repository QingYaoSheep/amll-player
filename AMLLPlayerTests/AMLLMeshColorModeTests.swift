@testable import AMLLPlayer
import MetalKit
import UIKit
import XCTest

@MainActor
final class AMLLMeshColorModeTests: XCTestCase {
    private func cover(side: Int = 64, pixel: (Int, Int) -> [UInt8]) throws -> Data {
        var bytes: [UInt8] = []
        for y in 0 ..< side {
            for x in 0 ..< side { bytes.append(contentsOf: pixel(x, y)) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return try XCTUnwrap(UIImage(cgImage: image).pngData())
    }

    private func texture(_ data: Data, mode: AMLLMeshBackground.ColorMode, radius: Int) throws -> any MTLTexture {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try XCTUnwrap(AMLLMeshBackground.Coordinator.albumTexture(
            data: data, device: device, blurRadius: radius, colorMode: mode
        ))
    }

    private func pixels(_ texture: any MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    func testColorMode2Uploads64PixelCoverWithoutColorAdjustments() throws {
        let data = try cover { _, _ in [96, 144, 192, 255] }
        for radius in [0, 2, 4] {
            let texture = try texture(data, mode: .colorMode2, radius: radius)
            XCTAssertEqual(texture.width, 64)
            XCTAssertEqual(texture.height, 64)
            let bytes = pixels(texture)
            for (x, y) in [(0, 0), (63, 0), (32, 32), (0, 63), (63, 63)] {
                XCTAssertEqual(Array(bytes[(y * 64 + x) * 4 ..< (y * 64 + x) * 4 + 4]), [96, 144, 192, 255])
            }
        }
    }

    func testColorMode2UsesExactlyTwoBoxBlurPasses() throws {
        // A one-pixel white vertical stripe, averaged twice over radius 1,
        // has the independently known triangular profile 28, 57, 85, 57, 28.
        let data = try cover { x, _ in x == 32 ? [255, 255, 255, 255] : [0, 0, 0, 255] }
        let blurred = pixels(try texture(data, mode: .colorMode2, radius: 1))
        let expected: [UInt8] = [0, 28, 57, 85, 57, 28, 0]
        for (offset, value) in expected.enumerated() {
            let index = (32 * 64 + 29 + offset) * 4
            XCTAssertEqual(Array(blurred[index ..< index + 4]), [value, value, value, 255])
        }
        let sharp = pixels(try texture(data, mode: .colorMode2, radius: 0))
        XCTAssertEqual(sharp[(32 * 64 + 32) * 4], 255)
        XCTAssertEqual(sharp[(32 * 64 + 31) * 4], 0)
    }

    func testOriginalMeshRetains32PixelColorMatrix() throws {
        let data = try cover { _, _ in [96, 144, 192, 255] }
        let original = try texture(data, mode: .original, radius: 2)
        XCTAssertEqual(original.width, 32)
        XCTAssertEqual(original.height, 32)
        XCTAssertEqual(Array(pixels(original).prefix(4)), [40, 113, 187, 255])
    }

    func testBackgroundSelectionPersistsWithoutChangingOtherAppearanceSettings() throws {
        let name = "mesh-color-mode-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        XCTAssertNil(preferences.configuration.backgroundMode)
        preferences.configuration.backgroundBlur = 55
        preferences.configuration.fontSize = 41
        preferences.configuration.hdr = .init(enabled: true)
        for mode in [LyricsRenderConfiguration.BackgroundMode.meshColorMode2, .mesh, .pixi, .flowing, .solid, .gradient] {
            preferences.configuration.backgroundMode = mode
            let restored = LyricsRenderPreferences(defaults: defaults)
            XCTAssertEqual(restored.configuration, preferences.configuration)
            XCTAssertEqual(restored.configuration.backgroundBlur, 55)
            XCTAssertEqual(restored.configuration.fontSize, 41)
            XCTAssertTrue(restored.configuration.hdr?.enabled == true)
        }
    }

    func testBothMeshModesUseTheSameBackgroundAndImmersiveBlurPolicy() {
        for mode in [LyricsRenderConfiguration.BackgroundMode.mesh, .meshColorMode2] {
            XCTAssertTrue(mode.isMesh)
            var background = AMLLBackground(artworkURL: nil, active: true, blur: 55, mode: mode)
            XCTAssertEqual(background.effectiveMeshBlur, 55)
            background.suppressBlur = true
            XCTAssertEqual(background.effectiveMeshBlur, 0)
        }
        XCTAssertFalse(LyricsRenderConfiguration.BackgroundMode.pixi.isMesh)
    }
}
