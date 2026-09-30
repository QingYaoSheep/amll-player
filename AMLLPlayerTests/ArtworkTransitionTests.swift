@testable import AMLLPlayer
import AVFoundation
import CoreImage
import UIKit
import XCTest

@MainActor
final class ArtworkTransitionTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

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
        // 112 pt overlaps the real video and 88 pt extends below it.
        for y in [100, 140, 180] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(source, x: 100, y: y - 88)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
        for y in [0, 20, 80] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(source, x: 100, y: 0)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
    }

    func testBlurProgressivelyRemovesDetailTowardsTheBottom() throws {
        let source = try XCTUnwrap(CIFilter(name: "CIStripesGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputColor0": CIColor.white,
            "inputColor1": CIColor.black, "inputWidth": 8, "inputSharpness": 1,
        ])?.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 400))
        let image = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                    videoSize: CGSize(width: 128, height: 400), surfaceSize: CGSize(width: 128, height: 200),
                                                                    outputSize: CGSize(width: 128, height: 200)))
        func variance(y: Int) -> Double {
            var bytes = [UInt8](repeating: 0, count: 80 * 4)
            bytes.withUnsafeMutableBytes { storage in
                context.render(image, toBitmap: storage.baseAddress!, rowBytes: 80 * 4,
                               bounds: CGRect(x: 24, y: y, width: 80, height: 1), format: .RGBA8, colorSpace: colorSpace)
            }
            let values = stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        }
        let top = variance(y: 198)
        let bottom = variance(y: 4)
        XCTAssertGreaterThan(top, 1000)
        XCTAssertGreaterThan(top, bottom * 2)
    }

    func testProductionMasksAndTransitionHaveNoStepAtTheVideoBottom() throws {
        let videoSize = CGSize(width: 128, height: 400)
        let viewport = CGSize(width: 128, height: 650)
        let frame = CGRect(origin: .zero, size: videoSize)
        let tail = AMLLImmersiveArtworkGeometry.transitionFrame(video: frame, viewportHeight: viewport.height)
        let source = CIImage(color: .red).cropped(to: frame)
        let surface = AnimatedArtwork.Surface(frame: frame)
        defer { surface.stop() }
        surface.configure(url: URL(fileURLWithPath: "/missing-artwork-transition-fixture.mp4"),
                          active: false, gravity: .resizeAspect, fadesBottom: true)
        surface.layoutSubviews()
        let mainMask = try maskImage(XCTUnwrap(surface.layer.mask as? CAGradientLayer), size: videoSize)
        let transitionSurface = ArtworkVideoTransition.Surface(frame: CGRect(origin: .zero, size: tail.size))
        transitionSurface.layoutSubviews()
        let tailMask = try maskImage(XCTUnwrap(transitionSurface.layer.mask as? CAGradientLayer), size: tail.size)
        let transition = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                         videoSize: videoSize, surfaceSize: tail.size, outputSize: tail.size))
        func masked(_ image: CIImage, _ mask: CIImage) -> CIImage {
            image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
                kCIInputMaskImageKey: mask,
            ])
        }
        let result = masked(source, mainMask)
            .transformed(by: CGAffineTransform(translationX: 0, y: viewport.height - frame.maxY))
            .composited(over: masked(transition, tailMask)
                .transformed(by: CGAffineTransform(translationX: 0, y: viewport.height - tail.maxY)))
            .composited(over: CIImage(color: .blue))
            .cropped(to: CGRect(origin: .zero, size: viewport))
        let boundary = Int(viewport.height - frame.maxY)
        for y in (boundary - 3) ... (boundary + 3) {
            let above = pixel(result, x: 64, y: y)
            let below = pixel(result, x: 64, y: y - 1)
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(above[channel] - below[channel]), 3,
                                         "A fully opaque rectangular video would leave a large step here")
            }
        }
        let image = try XCTUnwrap(context.createCGImage(result, from: result.extent))
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "Immersive video bottom continuity"
        attachment.lifetime = .keepAlways
        add(attachment)
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
        guard CFGetTypeID(contents as CFTypeRef) == CGImageGetTypeID() else {
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
