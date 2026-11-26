@testable import AMLLPlayer
import UIKit
import XCTest

final class DesktopLyricsTests: XCTestCase {
    @MainActor
    func testFocusExitRetargetsFromThePresentedOpacityAndBlur() {
        var transition = DesktopLyricsLineTransition()
        func sample(_ time: Double, focused: Bool) -> DesktopLyricsLineTransition.Appearance {
            transition.appearance(index: 3, focused: focused, opacity: 0.8, blur: 0,
                                  maximumBlur: 8, now: time, reduceMotion: false)
        }

        let clear = sample(0, focused: true)
        XCTAssertEqual(clear, .init(opacity: 0.8, blur: 0))
        XCTAssertEqual(sample(1, focused: false), clear)
        let exit = sample(1.08, focused: false)
        XCTAssertLessThan(exit.opacity, clear.opacity)
        XCTAssertGreaterThan(exit.blur, 0)
        XCTAssertTrue(transition.isAnimating)
        XCTAssertEqual(sample(1.08, focused: true), exit)
        XCTAssertEqual(sample(1.3, focused: true), clear)
        XCTAssertFalse(transition.isAnimating)
    }

    @MainActor
    func testReducedMotionAndResyncUseTheCurrentAppearance() {
        var transition = DesktopLyricsLineTransition()
        _ = transition.appearance(index: 3, focused: true, opacity: 1, blur: 0,
                                  maximumBlur: 8, now: 0, reduceMotion: false)
        _ = transition.appearance(index: 3, focused: false, opacity: 1, blur: 2,
                                  maximumBlur: 8, now: 2, reduceMotion: true)
        let faded = transition.appearance(index: 3, focused: false, opacity: 1, blur: 2,
                                          maximumBlur: 8, now: 2.1, reduceMotion: true)
        XCTAssertEqual(faded.blur, 0)
        XCTAssertLessThan(faded.opacity, 1)
        transition.reset()
        let focused = transition.appearance(index: 3, focused: true, opacity: 1, blur: 2,
                                            maximumBlur: 8, now: 2.1, reduceMotion: true)
        XCTAssertEqual(focused, .init(opacity: 1, blur: 0))
        XCTAssertFalse(transition.isAnimating)
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
