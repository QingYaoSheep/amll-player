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

    func testShortenedTransitionSamplesTheSameVideoPixelsWithoutStretching() throws {
        let video = CGRect(x: 22, y: 0, width: 200, height: 400)
        let tail = AMLLImmersiveArtworkGeometry.transitionFrame(video: video)
        XCTAssertEqual(tail.minX, video.minX)
        XCTAssertEqual(tail.width, video.width)
        XCTAssertEqual(tail.maxY, video.maxY, accuracy: 0.001)
        XCTAssertEqual(tail.height, 115.6, accuracy: 0.001)
        let source = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 400),
            "inputColor0": CIColor.blue, "inputColor1": CIColor.red,
        ])?.outputImage).cropped(to: CGRect(origin: .zero, size: video.size))
        let image = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                    videoSize: video.size, surfaceSize: tail.size,
                                                                    outputSize: tail.size, blurRadius: 0))
        for y in [0, 40, 80, 114] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(source, x: 100, y: y)
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
        // 136 pt overlaps the real video and 64 pt extends below it.
        for y in [100, 140, 180] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(source, x: 100, y: y - 64)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
        for y in [0, 20, 60] {
            let actual = pixel(image, x: 100, y: y)
            let expected = pixel(source, x: 100, y: 0)
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
            let expected = pixel(source, x: x, y: 36)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
        for (x, edge) in [(0, 0), (263, 199)] {
            let actual = pixel(image, x: x, y: 100)
            let expected = pixel(source, x: edge, y: 36)
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1)
            }
        }
        let surface = ArtworkReflection.Surface(frame: CGRect(x: 0, y: 0, width: 200, height: 240))
        XCTAssertEqual(surface.layer.opacity, 0.32, accuracy: 0.001)
        XCTAssertGreaterThan(surface.layer.opacity, 0.24)
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

    func testProductionTransitionFadesUpWhileTheVideoFadesDown() throws {
        let videoSize = CGSize(width: 128, height: 400)
        let viewport = CGSize(width: 128, height: 650)
        let frame = CGRect(origin: .zero, size: videoSize)
        let tail = AMLLImmersiveArtworkGeometry.transitionFrame(video: frame)
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
        XCTAssertLessThanOrEqual(pixel(tailMask, x: 64, y: Int(tail.height) - 1)[3], 1)
        XCTAssertGreaterThanOrEqual(pixel(tailMask, x: 64, y: 0)[3], 254)
        XCTAssertGreaterThan(pixel(tailMask, x: 64, y: 20)[3], pixel(tailMask, x: 64, y: 80)[3])
        XCTAssertLessThanOrEqual(pixel(mainMask, x: 64, y: 0)[3], 1)
        XCTAssertEqual(pixel(mainMask, x: 64, y: 399)[3], 255)
        let transition = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                         videoSize: videoSize, surfaceSize: tail.size, outputSize: tail.size))
        func masked(_ image: CIImage, _ mask: CIImage) -> CIImage {
            image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
                kCIInputMaskImageKey: mask,
            ])
        }
        let baseline = masked(source, mainMask)
            .transformed(by: CGAffineTransform(translationX: 0, y: viewport.height - frame.maxY))
            .composited(over: CIImage(color: .blue))
        let result = masked(transition, tailMask)
            .transformed(by: CGAffineTransform(translationX: tail.minX, y: viewport.height - tail.maxY))
            .composited(over: baseline)
            .cropped(to: CGRect(origin: .zero, size: viewport))
        let boundary = Int(viewport.height - tail.minY)
        for y in (boundary - 3) ... (boundary + 3) {
            let above = pixel(result, x: 64, y: y)
            let below = pixel(result, x: 64, y: y - 1)
            let baselineAbove = pixel(baseline, x: 64, y: y)
            let baselineBelow = pixel(baseline, x: 64, y: y - 1)
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs((above[channel] - below[channel])
                    - (baselineAbove[channel] - baselineBelow[channel])), 2,
                                         "The upward fade must not introduce a step at the transition's top")
            }
        }
        let image = try XCTUnwrap(context.createCGImage(result, from: result.extent))
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "Upward blur fade and downward video fade"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReflectionRemainsBelowTheUpwardFadingTransitionOnWhiteOrDarkBackground() throws {
        let videoSize = CGSize(width: 128, height: 400)
        let viewport = CGSize(width: 128, height: 650)
        let video = CGRect(origin: .zero, size: videoSize)
        let tail = AMLLImmersiveArtworkGeometry.transitionFrame(video: video)
        let reflection = ArtworkReflectionGeometry.frame(cover: video, viewportHeight: viewport.height)
        let reflectionSurface = ArtworkReflection.Surface(frame: CGRect(origin: .zero, size: reflection.size))
        reflectionSurface.layoutSubviews()
        let reflectionMask = try maskImage(XCTUnwrap(reflectionSurface.layer.mask as? CAGradientLayer), size: reflection.size)
        let tailSurface = ArtworkVideoTransition.Surface(frame: CGRect(origin: .zero, size: tail.size))
        tailSurface.layoutSubviews()
        let tailMask = try maskImage(XCTUnwrap(tailSurface.layer.mask as? CAGradientLayer), size: tail.size)
        let source = CIImage(color: .blue).cropped(to: video)
        let transition = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
                                                                         videoSize: videoSize, surfaceSize: tail.size, outputSize: tail.size))
        let reflected = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: CGFloat(reflectionSurface.layer.opacity)))
            .cropped(to: CGRect(origin: .zero, size: reflection.size))
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear), kCIInputMaskImageKey: reflectionMask,
            ])
            .transformed(by: CGAffineTransform(translationX: reflection.minX, y: viewport.height - reflection.maxY))
        let softened = transition.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear), kCIInputMaskImageKey: tailMask,
        ]).transformed(by: CGAffineTransform(translationX: tail.minX, y: viewport.height - tail.maxY))
        for (name, background) in [("white", CIColor.white), ("dark", CIColor.black)] {
            let result = softened.composited(over: reflected)
                .composited(over: CIImage(color: background))
                .cropped(to: CGRect(origin: .zero, size: viewport))
            let boundary = Int(viewport.height - video.maxY)
            // The revised overlay remains visible at the video bottom. Capture
            // that boundary for device review instead of asserting the former
            // downward-fading overlay's zero-alpha bottom.
            let overlayWithoutReflection = softened.composited(over: CIImage(color: background))
            XCTAssertEqual(pixel(result, x: 64, y: boundary),
                           pixel(overlayWithoutReflection, x: 64, y: boundary),
                           "The reflection must not draw over the transition at the video bottom")
            XCTAssertEqual(pixel(result, x: 64, y: boundary - 1),
                           pixel(reflected.composited(over: CIImage(color: background)), x: 64, y: boundary - 1))
            let image = try XCTUnwrap(context.createCGImage(result, from: result.extent))
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Reflection below upward blur fade on \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThan(reflectionSurface.layer.opacity, 0.24)
        XCTAssertEqual(reflection.minY, video.maxY)
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
