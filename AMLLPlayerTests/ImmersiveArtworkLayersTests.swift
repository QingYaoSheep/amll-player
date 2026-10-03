@testable import AMLLPlayer
import CoreImage
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ImmersiveArtworkLayersTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func testBlurFadesUpwardButRemainsStrongAtTheScreenBottom() throws {
        let source = try XCTUnwrap(CIFilter(name: "CIStripesGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputColor0": CIColor.white,
            "inputColor1": CIColor.black, "inputWidth": 8, "inputSharpness": 1,
        ])?.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 400))
        let image = try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source,
            videoSize: CGSize(width: 128, height: 400), surfaceSize: CGSize(width: 128, height: 300),
            outputSize: CGSize(width: 128, height: 300)))
        func variance(y: Int) -> Double {
            let values = (24 ..< 104).map { Double(pixel(image, x: $0, y: y)[0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        }
        let top = variance(y: 298)
        XCTAssertGreaterThan(top, 1000)
        XCTAssertGreaterThan(top, variance(y: 2) * 2)
        XCTAssertGreaterThan(top, variance(y: 150) * 2)
    }

    func testTransitionMaskKeepsItsLowerExtensionOpaqueWithReflectionOnOrOff() throws {
        let video = CGRect(x: 0, y: 0, width: 128, height: 400)
        let tail = AMLLImmersiveArtworkGeometry.transitionFrame(video: video, viewportHeight: 650)
        let reflected = ArtworkReflectionGeometry.frame(cover: video, viewportHeight: 650)
        for enabled in [false, true] {
            let surface = ArtworkVideoTransition.Surface(frame: CGRect(origin: .zero, size: tail.size))
            surface.configure(videoSize: video.size, composition: .init(video: video, reflection: reflected,
                transition: tail, reflectionEnabled: enabled, reflectionOpacity: 1, blurRadius: 32))
            surface.layoutSubviews()
            let mask = try maskImage(XCTUnwrap(surface.layer.mask as? CAGradientLayer), size: tail.size)
            XCTAssertLessThanOrEqual(pixel(mask, x: 64, y: Int(tail.height) - 1)[3], 1)
            XCTAssertEqual(pixel(mask, x: 64, y: 0)[3], 255)
            XCTAssertEqual(pixel(mask, x: 64, y: 100)[3], 255)
            XCTAssertEqual(tail.maxY, 650, accuracy: 0.001)
        }
    }

    func testUnblurredReflectionFeedsTheTransitionComposite() throws {
        let size = CGSize(width: 128, height: 400)
        let source = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 96),
            "inputColor0": CIColor.blue, "inputColor1": CIColor.red,
        ])?.outputImage).cropped(to: CGRect(origin: .zero, size: size))
        let video = CGRect(origin: .zero, size: size)
        let reflection = CGRect(x: 0, y: 400, width: 128, height: 220)
        let tail = AMLLImmersiveArtworkGeometry.transitionFrame(video: video, viewportHeight: 650)
        let raw = ArtworkReflectionImage.image(source: source, outputSize: reflection.size)
        let expected = pixel(source, x: 64, y: 48)
        let actual = pixel(raw, x: 64, y: 110)
        for channel in 0 ..< 3 { XCTAssertLessThanOrEqual(abs(expected[channel] - actual[channel]), 3) }
        func composite(reflects: Bool) throws -> CIImage {
            try XCTUnwrap(ArtworkVideoTransitionImage.image(source: source, videoSize: size,
                surfaceSize: tail.size, outputSize: tail.size, blurRadius: 0,
                composition: .init(video: video, reflection: reflection, transition: tail,
                    reflectionEnabled: reflects, reflectionOpacity: 1, blurRadius: 0)))
        }
        let without = try composite(reflects: false)
        let with = try composite(reflects: true)
        let y = Int(tail.maxY - (reflection.minY + 44))
        XCTAssertGreaterThan(pixel(with, x: 64, y: y)[0], pixel(without, x: 64, y: y)[0] + 3,
                             "The blur input must contain reflection pixels, not only a repeated video edge")
    }

    func testFinalFadeMasksMediaWithoutMaskingTheLiveBlurParent() throws {
        let size = CGSize(width: 128, height: 650)
        let video = CGRect(x: 0, y: 0, width: 128, height: 400)
        let fade = AMLLImmersiveArtworkGeometry.bottomFadeFrame(video: video, viewport: size)
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = CGRect(origin: .zero, size: size)
        defer { surface.stop() }
        surface.configure(video: AnimatedArtwork(url: URL(fileURLWithPath: "/missing-layer-fixture.mp4"), active: false),
            layout: .init(video: video, reflection: ArtworkReflectionGeometry.frame(cover: video, viewportHeight: size.height),
                transition: AMLLImmersiveArtworkGeometry.transitionFrame(video: video, viewportHeight: size.height),
                bottomFade: fade, tuning: .init(), presentsFrame: false, reflectionEnabled: false, reduceTransparency: false))
        surface.layoutIfNeeded()
        XCTAssertNil(surface.layer.mask, "UIKit live effects must not have a masked parent")
        XCTAssertNil(surface.backgroundSurface.mask)
        XCTAssertNil(surface.dimmingSurface.mask)
        let maskView = try XCTUnwrap(ImmersiveArtworkVisibility.mask(frame: CGRect(origin: .zero, size: size),
            fade: fade, strength: 1))
        let mask = try nativeMaskImage(maskView.layer, size: size)
        let rendered = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: size))
            .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .blue), kCIInputMaskImageKey: mask])
            .cropped(to: CGRect(origin: .zero, size: size))
        XCTAssertGreaterThan(pixel(rendered, x: 64, y: 649)[0], 250)
        XCTAssertLessThan(pixel(rendered, x: 64, y: 649)[2], 5)
        XCTAssertGreaterThan(pixel(rendered, x: 64, y: 0)[2], 250)
        XCTAssertLessThan(pixel(rendered, x: 64, y: 0)[0], 5)
        let attachment = XCTAttachment(image: UIImage(cgImage: try XCTUnwrap(context.createCGImage(rendered, from: rendered.extent))))
        attachment.name = "Final media fade reveals the background"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTemporaryLayerTuningRoundTripAndFrameAdjustments() throws {
        var settings = ImmersiveArtworkDebugConfiguration()
        for layer in ImmersiveArtworkLayer.allCases {
            XCTAssertTrue(settings[layer].enabled)
            XCTAssertEqual(settings[layer].opacity, layer == .reflection ? 0.32 : layer == .dimming ? 0.16 : 1)
        }
        settings[.transition].y = 20
        settings[.transition].width = 1.25
        settings[.reflection].enabled = false
        let decoded = try JSONDecoder().decode(ImmersiveArtworkDebugConfiguration.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        let frame = decoded[.transition].frame(CGRect(x: 0, y: 200, width: 200, height: 100))
        XCTAssertEqual(frame.midY, 270)
        XCTAssertEqual(frame.width, 250)
        XCTAssertFalse(decoded[.reflection].enabled)
        var invalid = ImmersiveArtworkLayerAdjustment()
        invalid.opacity = .nan
        invalid.height = -1
        XCTAssertEqual(invalid.validated().opacity, 1)
        XCTAssertEqual(invalid.validated().height, 0.1)
        let restored = ImmersiveArtworkDebugConfiguration()
        XCTAssertEqual(restored[.transition].y, 0)
        XCTAssertTrue(restored[.reflection].enabled)
    }

    func testLayerOrderIsCompatibleCompleteAndMovesLikeLyricsSourcePriority() throws {
        let old = Data(#"{"layers":{},"blurRadius":32}"#.utf8)
        var settings = try JSONDecoder().decode(ImmersiveArtworkDebugConfiguration.self, from: old)
        XCTAssertEqual(settings.orderedLayers, Array(ImmersiveArtworkLayer.allCases.reversed()))
        settings.moveLayers(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(settings.orderedLayers[1], .reflection)
        XCTAssertTrue(settings.isBelow(.transition, .reflection))
        let decoded = try JSONDecoder().decode(ImmersiveArtworkDebugConfiguration.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.orderedLayers, settings.orderedLayers)
        settings.order = [.video, .video, .transition]
        XCTAssertEqual(Set(settings.orderedLayers), Set(ImmersiveArtworkLayer.allCases))
        XCTAssertEqual(settings.orderedLayers.count, ImmersiveArtworkLayer.allCases.count)
        XCTAssertEqual(settings.orderedLayers.first, .video)
    }

    func testImmersiveOverrideRemovesBackgroundBlurWithoutChangingSavedConfiguration() {
        let flowing = FlowingBackgroundConfiguration(rotationSpeed: 2, distortion: 5, blur: 55)
        var background = AMLLBackground(artworkURL: nil, active: true, blur: 60, mode: .flowing, flowing: flowing)
        XCTAssertEqual(background.effectiveMeshBlur, 60)
        XCTAssertEqual(background.effectiveFlowingConfiguration, flowing)
        background.suppressBlur = true
        XCTAssertEqual(background.effectiveMeshBlur, 0)
        XCTAssertEqual(background.effectiveFlowingConfiguration.blur, 0)
        XCTAssertEqual(background.effectiveFlowingConfiguration.distortion, 5)
        XCTAssertEqual(background.effectiveFlowingConfiguration.rotationSpeed, 2)
        XCTAssertEqual(background.flowing, flowing)
        background.suppressBlur = false
        XCTAssertEqual(background.effectiveFlowingConfiguration, flowing)
        let pixi = AMLLPixiBackground.Coordinator(seed: 42)
        pixi.setBlurEnabled(false)
        XCTAssertFalse(pixi.blurEnabled)
        pixi.setBlurEnabled(true)
        XCTAssertTrue(pixi.blurEnabled)
    }

    func testIndependentContainerSlidersKeepVideoAndReflectionAlignedWithoutStretching() {
        let container = CGRect(x: 10, y: 30, width: 360, height: 400)
        let video = AMLLImmersiveArtworkGeometry.fittedFrame(container: container, source: CGSize(width: 9, height: 16))
        XCTAssertEqual(video.width / video.height, 9.0 / 16, accuracy: 0.0001)
        XCTAssertTrue(container.contains(video))
        let reflection = ArtworkReflectionGeometry.frame(cover: video, viewportHeight: 874)
        let transition = AMLLImmersiveArtworkGeometry.transitionFrame(video: video, viewportHeight: 874)
        XCTAssertEqual(reflection.minY, video.maxY)
        XCTAssertEqual(reflection.width, video.width)
        XCTAssertEqual(transition.width, video.width)
        XCTAssertEqual(transition.maxY, 874)
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
        try nativeMaskImage(mask, size: size)
    }

    private func nativeMaskImage(_ mask: CALayer, size: CGSize) throws -> CIImage {
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
