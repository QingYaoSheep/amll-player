@testable import AMLLPlayer
import UIKit
import XCTest

final class DesktopLyricsTests: XCTestCase {
    func testSettingsDefaultAndDecodeInvalidFieldsIndependently() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(DesktopLyricsSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(defaults, DesktopLyricsSettings())
        let partial = Data(#"{"fontSize":90,"blurStrength":-1,"wordHighlight":false,"aspect":"tall","transition":"unknown"}"#.utf8)
        let settings = try decoder.decode(DesktopLyricsSettings.self, from: partial)
        XCTAssertEqual(settings.fontSize, 36)
        XCTAssertEqual(settings.blurStrength, 0)
        XCTAssertEqual(settings.aspect, .tall)
        XCTAssertEqual(settings.transition, .blur)
        XCTAssertFalse(settings.wordHighlight)
    }

    @MainActor
    func testAppearancePersistsAndCanResetWithoutChangingLegacyAutoStart() throws {
        let suite = "desktop-lyrics-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DesktopLyricsController.autoStartKey)
        let preferences = DesktopLyricsPreferences(defaults: defaults)
        preferences.settings.aspect = .tall
        preferences.settings.blurStrength = 3.2
        preferences.settings.transition = .fade
        XCTAssertEqual(DesktopLyricsPreferences(defaults: defaults).settings, preferences.settings)
        XCTAssertEqual(preferences.settings.blurStrength, 3)
        preferences.settings = .init()
        XCTAssertEqual(DesktopLyricsPreferences(defaults: defaults).settings, DesktopLyricsSettings())
        XCTAssertTrue(defaults.bool(forKey: DesktopLyricsController.autoStartKey))
    }

    @MainActor
    func testFirstFrameDimensionsAndTierLimitsForEachAspect() {
        typealias Aspect = DesktopLyricsSettings.Aspect
        XCTAssertEqual(DesktopLyricsFrames(aspect: .wide).pixelSize, CGSize(width: 960, height: 480))
        XCTAssertEqual(DesktopLyricsFrames(aspect: .standard).pixelSize, CGSize(width: 960, height: 540))
        XCTAssertEqual(DesktopLyricsFrames(aspect: .tall).pixelSize, CGSize(width: 960, height: 720))
        XCTAssertEqual(Aspect.wide.outputSize(for: CGSize(width: 1000, height: 500)), CGSize(width: 1152, height: 576))
        XCTAssertEqual(Aspect.standard.outputSize(for: CGSize(width: 1080, height: 400)), CGSize(width: 960, height: 540))
        XCTAssertEqual(Aspect.tall.outputSize(for: CGSize(width: 2000, height: 1500)), CGSize(width: 1104, height: 828))
        for aspect in Aspect.allCases {
            for size in aspect.pixelSizes {
                XCTAssertEqual(size.width / size.height, aspect.ratio, accuracy: 0.001)
                XCTAssertLessThanOrEqual(size.width * size.height, 1280 * 720)
            }
        }
    }

    func testDesktopPoliciesKeepTheSourcePresetAndSeparateBlurFromWordHighlighting() {
        var source = LyricsRenderConfiguration()
        source.blurInactive = false
        source.fontSize = 32
        var settings = DesktopLyricsSettings()
        settings.fontSize = 28
        settings.wordHighlight = false
        XCTAssertEqual(settings.blurMaximum, 1)
        XCTAssertTrue(settings.rendererConfiguration(source).blurInactive)
        XCTAssertEqual(settings.rendererConfiguration(source).fontSize, 28)
        XCTAssertEqual(settings.rendererConfiguration(source).animationStyle, source.animationStyle)
        settings.transition = .fade
        XCTAssertFalse(settings.rendererConfiguration(source).blurInactive)
        XCTAssertFalse(settings.snapsLines)
        XCTAssertFalse(settings.wordHighlight)
        settings.transition = .instant
        XCTAssertTrue(settings.snapsLines)
        XCTAssertEqual(settings.blurStrength, 1)
        XCTAssertEqual(source.fontSize, 32)
    }

    @MainActor
    func testOffscreenLayerRenderingRespectsTheWordGradientAlphaMask() throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 8)
        let text = CALayer()
        text.bounds = bounds
        text.backgroundColor = UIColor.white.cgColor
        let mask = CAGradientLayer()
        mask.frame = bounds
        mask.colors = [UIColor.white.cgColor, UIColor.clear.cgColor]
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        text.mask = mask

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: bounds.size, format: format).image {
            text.render(in: $0.cgContext)
        }.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo:
                CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: bounds)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let leftAlpha = data[(4 * 32 + 2) * 4 + 3]
        let rightAlpha = data[(4 * 32 + 29) * 4 + 3]
        XCTAssertGreaterThan(leftAlpha, 185)
        XCTAssertLessThan(rightAlpha, 75)
    }
}
