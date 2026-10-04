@testable import AMLLPlayer
import AVFoundation
import CoreImage
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ArtworkTransitionTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func testReflectionKeepsSquareFeaturesSquareAcrossContainerHeights() throws {
        // An actual image feature catches anisotropic stretching, rather than
        // only checking the destination rectangle's dimensions.
        for sourceSize in [CGSize(width: 200, height: 400), CGSize(width: 400, height: 200)] {
            let origin = CGPoint(x: 17, y: 23)
            let sourceRect = CGRect(origin: origin, size: sourceSize)
            let marker = CGRect(x: origin.x + sourceSize.width / 2 - 20, y: origin.y + 4, width: 40, height: 40)
            let source = CIImage(color: .red).cropped(to: marker)
                .composited(over: CIImage(color: .blue).cropped(to: sourceRect))
            for height in [60, 150, 240] {
                let output = ArtworkReflectionImage.image(source: source,
                    outputSize: CGSize(width: 100, height: CGFloat(height)))
                var bytes = [UInt8](repeating: 0, count: 100 * height * 4)
                bytes.withUnsafeMutableBytes {
                    context.render(output, toBitmap: $0.baseAddress!, rowBytes: 400,
                        bounds: CGRect(x: 0, y: 0, width: 100, height: CGFloat(height)),
                        format: .RGBA8, colorSpace: colorSpace)
                }
                var left = 100, right = -1, bottom = height, top = -1
                for y in 0 ..< height {
                    for x in 0 ..< 100 {
                        let offset = (y * 100 + x) * 4
                        guard bytes[offset] > 240, bytes[offset + 1] < 10,
                              bytes[offset + 2] < 10, bytes[offset + 3] > 240 else { continue }
                        left = min(left, x); right = max(right, x)
                        bottom = min(bottom, y); top = max(top, y)
                    }
                }
                XCTAssertGreaterThanOrEqual(right, left, "The bottom-edge marker must remain visible")
                let expected = 40 * 100 / sourceSize.width
                XCTAssertEqual(Double(right - left + 1), Double(expected), accuracy: 1)
                XCTAssertEqual(Double(top - bottom + 1), Double(expected), accuracy: 1,
                    "Reflection height must crop the same-scale mirror, not stretch a small source strip")
                let distanceFromTop = height - 1 - top
                XCTAssertEqual(Double(distanceFromTop), Double(4 * 100 / sourceSize.width), accuracy: 1,
                    "The source bottom must meet the reflection top at every container height")
                let naturalHeight = sourceSize.height * 100 / sourceSize.width
                if CGFloat(height) > naturalHeight {
                    XCTAssertEqual(pixel(output, x: 50, y: 0)[3], 0,
                        "Area beyond the full mirrored frame must stay transparent")
                }
            }
        }
    }

    func testReflectionBeginsOpaqueAndOnlyFadesDownward() throws {
        let mask = ArtworkReflectionImage.alphaMask(size: CGSize(width: 128, height: 240))
        XCTAssertGreaterThanOrEqual(pixel(mask, x: 64, y: 239)[3], 250,
            "The reflected video must connect at its top without a second fade-in")
        XCTAssertGreaterThan(pixel(mask, x: 64, y: 210)[3], pixel(mask, x: 64, y: 120)[3])
        XCTAssertLessThanOrEqual(pixel(mask, x: 64, y: 0)[3], 2)
        let surface = ArtworkReflection.Surface(frame: CGRect(x: 0, y: 0, width: 128, height: 240))
        let fade = try XCTUnwrap(surface.layer.mask as? CAGradientLayer)
        let visibleMask = try maskImage(fade, size: surface.bounds.size)
        XCTAssertGreaterThanOrEqual(pixel(visibleMask, x: 64, y: 239)[3], 250,
            "The visible mask and the compositor must use the same descending stops")
    }

    func testReflectionToggleRemovesTheVideoFadeAndDisablingItRestoresTheFade() throws {
        let surface = AnimatedArtwork.Surface(frame: CGRect(x: 0, y: 0, width: 128, height: 400))
        defer { surface.stop() }
        let url = URL(fileURLWithPath: "/missing-artwork-transition-fixture.mp4")
        for reflection in [false, true, false] {
            let fades = AMLLArtworkDisplayPolicy.fadesImmersiveBottom(reflectionEnabled: reflection, reduceTransparency: false)
            surface.configure(url: url, active: false, gravity: .resizeAspect, fadesBottom: fades)
            surface.layoutSubviews()
            XCTAssertEqual(surface.layer.mask != nil, !reflection)
            XCTAssertEqual((surface.layer as? AVPlayerLayer)?.videoGravity, .resizeAspect)
        }
        for reflection in [false, true] {
            XCTAssertFalse(AMLLArtworkDisplayPolicy.fadesImmersiveBottom(reflectionEnabled: reflection, reduceTransparency: true))
        }
    }

    func testBackgroundDimmingLeavesTheArtworkAboveItUnchanged() throws {
        func render(dimming: Double) throws -> CIImage {
            let content = ZStack(alignment: .topLeading) {
                AMLLBackground(artworkURL: nil, active: false, blur: 0, mode: .solid,
                               color: .init(red: 1, green: 1, blue: 1), dimming: dimming)
                Color.red.frame(width: 64, height: 100)
            }.frame(width: 128, height: 200)
            let image = try XCTUnwrap(ImageRenderer(content: content).cgImage)
            return CIImage(cgImage: image)
        }
        let original = try render(dimming: 0)
        let dimmed = try render(dimming: 0.75)
        XCTAssertEqual(pixel(original, x: 32, y: 150), pixel(dimmed, x: 32, y: 150),
                       "The artwork above the production background must keep its brightness")
        XCTAssertGreaterThan(pixel(original, x: 100, y: 150)[0] - pixel(dimmed, x: 100, y: 150)[0], 100)
    }

    func testCenteredTransitionKeepsVideoPixelsAlignedAndExtendsItsBottomEdge() throws {
        let video = CGRect(x: 22, y: 0, width: 200, height: 400)
        let tail = AMLLImmersiveArtworkGeometry.transitionFrame(video: video)
        XCTAssertEqual(tail.minX, video.minX)
        XCTAssertEqual(tail.width, video.width)
        XCTAssertEqual(tail.midY, video.maxY, accuracy: 0.001)
        XCTAssertEqual(tail.height, 231.2, accuracy: 0.001)
        let source = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 400),
            "inputColor0": CIColor.blue, "inputColor1": CIColor.red,
        ])?.outputImage).cropped(to: CGRect(origin: .zero, size: video.size))
        let image = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                    videoSize: video.size, surfaceSize: tail.size,
                                                                    outputSize: tail.size, blurRadius: 0))
        let expectedImage = source.transformed(by: CGAffineTransform(translationX: 0, y: tail.maxY - video.maxY))
            .clampedToExtent()
        for y in [0, 40, 110, 120, 160, 220] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(expectedImage, x: 100, y: y)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
    }

    func testImmersiveVideoHasAnActualBottomMaskButSquareCoverDoesNot() throws {
        let surface = AnimatedArtwork.Surface(frame: CGRect(x: 0, y: 0, width: 128, height: 400))
        defer { surface.stop() }
        let url = URL(fileURLWithPath: "/missing-artwork-transition-fixture.mp4")
        surface.configure(url: url, active: false, gravity: .resizeAspect, fadesBottom: true)
        surface.layoutSubviews()
        let fade = try XCTUnwrap(surface.layer.mask as? CAGradientLayer)
        let mask = try maskImage(fade, size: surface.bounds.size)
        XCTAssertEqual(pixel(mask, x: 64, y: 399)[3], 255)
        XCTAssertLessThanOrEqual(pixel(mask, x: 64, y: 0)[3], 1)
        XCTAssertLessThan(pixel(mask, x: 64, y: 40)[3], pixel(mask, x: 64, y: 90)[3])
        XCTAssertEqual((surface.layer as? AVPlayerLayer)?.videoGravity, .resizeAspect)
        surface.configure(url: url, active: false, gravity: .resizeAspectFill, fadesBottom: false)
        XCTAssertNil(surface.layer.mask)
    }

    func testOverlapUsesTheVideoScaleAndExtensionRepeatsItsBottomEdge() throws {
        let source = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 400),
            "inputColor0": CIColor.blue, "inputColor1": CIColor.red,
        ])?.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
        let image = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                    videoSize: CGSize(width: 200, height: 400), surfaceSize: CGSize(width: 200, height: 200),
                                                                    outputSize: CGSize(width: 200, height: 200), blurRadius: 0))
        // The shortened upper region is 115.6 pt; 84.4 pt extends below it.
        let expectedImage = source.transformed(by: CGAffineTransform(translationX: 0, y: 84.4)).clampedToExtent()
        for y in [100, 140, 180] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(expectedImage, x: 100, y: y)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
        for y in [0, 20, 60] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(expectedImage, x: 100, y: y)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
    }

    func testWiderTransitionKeepsVideoPixelsAlignedAndExtendsOnlyTheEdges() throws {
        let source = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 200, y: 0),
            "inputColor0": CIColor.blue, "inputColor1": CIColor.red,
        ])?.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
        let image = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                    videoSize: CGSize(width: 200, height: 400),
                                                                    surfaceSize: CGSize(width: 264, height: 200),
                                                                    outputSize: CGSize(width: 264, height: 200), blurRadius: 0))
        for x in [0, 50, 100, 150, 199] {
            let actual = pixel(image, x: x + 32, y: 100)
            let expected = pixel(source, x: x, y: 16)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
        for (x, edge) in [(0, 0), (263, 199)] {
            let actual = pixel(image, x: x, y: 100)
            let expected = pixel(source, x: edge, y: 16)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
        let surface = ArtworkReflection.Surface(frame: CGRect(x: 0, y: 0, width: 200, height: 240))
        XCTAssertEqual(surface.layer.opacity, 0.32, accuracy: 0.001)
        XCTAssertGreaterThan(surface.layer.opacity, 0.24)
    }

    func testPausedTransitionRebuildsOnResizeAndClearDiscardsItsOldFrame() async throws {
        let surface = ArtworkVideoTransition.Surface(frame: CGRect(x: 0, y: 0, width: 128, height: 229))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        window.addSubview(surface)
        defer { surface.clear(); surface.removeFromSuperview() }
        surface.configure(videoSize: CGSize(width: 128, height: 400))
        surface.layoutSubviews()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 400, kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            _ = base.initializeMemory(as: UInt8.self, repeating: 255,
                                      count: CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        surface.display(pixels)
        try await waitForImage(surface)
        let original = try presentedImage(surface)
        surface.frame.size = CGSize(width: 160, height: 240)
        surface.configure(videoSize: CGSize(width: 160, height: 500))
        surface.layoutSubviews()
        try await waitForImage(surface)
        let resized = try presentedImage(surface)
        XCTAssertGreaterThan(resized.width, original.width)
        try surface.display(XCTUnwrap(buffer))
        surface.clear()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(surface.layer.contents)
        surface.layoutSubviews()
        XCTAssertNil(surface.layer.contents)
    }

    func testInvalidGeometryDoesNotProduceAnOldTransition() {
        XCTAssertNil(ArtworkVideoTransitionImage.image(source: CIImage(color: .red).cropped(to: .zero),
                                                       videoSize: .zero, surfaceSize: CGSize(width: 100, height: 100), outputSize: CGSize(width: 100, height: 100)))
    }

    private func presentedImage(_ surface: ArtworkVideoTransition.Surface) throws -> CGImage {
        let contents = try XCTUnwrap(surface.layer.contents)
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            XCTFail("The transition must present a Core Graphics image")
            throw NSError(domain: "ArtworkTransitionTests", code: 1)
        }
        return contents as! CGImage
    }

    private func waitForImage(_ surface: ArtworkVideoTransition.Surface) async throws {
        for _ in 0 ..< 200 {
            if surface.layer.contents != nil {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The bounded background renderer did not present its frame")
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { storage in
            context.render(image, toBitmap: storage.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
        }
        return bytes.map(Int.init)
    }

    private func maskImage(_ mask: CAGradientLayer, size: CGSize) throws -> CIImage {
        mask.frame = CGRect(origin: .zero, size: size)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                             bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.translateBy(x: 0, y: size.height)
        bitmap.scaleBy(x: 1, y: -1)
        mask.render(in: bitmap)
        return try CIImage(cgImage: XCTUnwrap(bitmap.makeImage()))
    }
}
