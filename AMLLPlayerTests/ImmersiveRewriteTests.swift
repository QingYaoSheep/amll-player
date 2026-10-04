@testable import AMLLPlayer
import XCTest
import CoreImage
import MetalKit
import AVFoundation
import UIKit

@MainActor
final class ImmersiveRewriteTests: XCTestCase {
    func testLegacyFadeKeepsTheUpperTwoThirdsAndEndsAtTheVideoEdge() {
        let style = ImmersiveArtworkStyle()
        XCTAssertEqual(style.videoAlpha(at: 0.50), 1)
        XCTAssertEqual(style.videoAlpha(at: 0.66), 1)
        XCTAssertEqual(style.videoAlpha(at: 0.83), 0.5, accuracy: 0.000001)
        XCTAssertEqual(style.videoAlpha(at: 1), 0)
        for stop in AMLLImmersiveArtworkGeometry.videoFadeStops {
            XCTAssertEqual(style.videoAlpha(at: stop.location), stop.alpha, accuracy: 0.000001)
        }
    }

    func testStyleCompatibilityIgnoresOldLayerOrderingAndClampsOnlyNewParameters() throws {
        let defaults = try JSONDecoder().decode(ImmersiveArtworkStyle.self, from: Data("{\"order\":[\"video\"],\"layers\":{}}".utf8))
        XCTAssertEqual(defaults, ImmersiveArtworkStyle())
        var style = defaults
        style.blurRadius = .infinity; style.reflectionOpacity = -1
        XCTAssertEqual(style.validated().blurRadius, 32)
        XCTAssertEqual(style.validated().reflectionOpacity, 0)
        XCTAssertEqual(try JSONDecoder().decode(ImmersiveArtworkStyle.self, from: JSONEncoder().encode(defaults)), defaults)
    }

    func testPhoneControlsMatchTheReferenceAndDoNotDependOnTheVideoAspect() {
        let m = ImmersivePlayerLayoutMetrics.make(viewport: .init(width: 402, height: 874), bottomInset: 34)
        XCTAssertEqual(m.metadataTop, 497, accuracy: 0.001)
        XCTAssertEqual(m.progressCenter, 574, accuracy: 0.001)
        XCTAssertEqual(m.transportCenter, 666, accuracy: 0.001)
        XCTAssertEqual(m.volumeCenter, 756, accuracy: 0.001)
        XCTAssertEqual(m.actionsCenter, 813, accuracy: 0.001)
        XCTAssertTrue(ImmersivePlayerLayoutMetrics.make(viewport: .init(width: 320, height: 568), bottomInset: 0,
                                                       contentScale: 2).needsScrolling)
    }

    func testFadeOnlyChangesVideoAndNeverTheReflectionOrBackground() {
        var style = ImmersiveArtworkStyle(); style.blurRadius = 0
        let layout = makeLayout(style)
        let background = CIImage(color: .blue).cropped(to: .init(x: 0, y: 0, width: 128, height: 400))
        let source = CIImage(color: .red).cropped(to: .init(x: 0, y: 0, width: 128, height: 240))
        let faded = ImmersiveArtworkImage.compose(background: background, video: source, layout: layout, scale: 1)
        style.videoFadeEnabled = false
        let full = ImmersiveArtworkImage.compose(background: background, video: source, layout: makeLayout(style), scale: 1)
        XCTAssertEqual(pixel(faded, x: 64, y: 280), pixel(full, x: 64, y: 280))
        XCTAssertLessThan(pixel(faded, x: 64, y: 190)[0], pixel(full, x: 64, y: 190)[0])
        XCTAssertEqual(pixel(faded, x: 64, y: 140), pixel(full, x: 64, y: 140), "Reflection has its own fade")
        XCTAssertEqual(pixel(faded, x: 64, y: 0), pixel(full, x: 64, y: 0), "Background remains opaque")
        XCTAssertEqual(pixel(faded, x: 64, y: 0)[3], 255)
    }

    func testDimmingChangesOnlyTheUnderlyingBackground() {
        var style = ImmersiveArtworkStyle(); style.blurRadius = 0; style.videoFadeEnabled = false
        let background = CIImage(color: .white).cropped(to: .init(x: 0, y: 0, width: 128, height: 400))
        let video = CIImage(color: .red).cropped(to: .init(x: 0, y: 0, width: 128, height: 240))
        let normal = ImmersiveArtworkImage.compose(background: background, video: video, layout: makeLayout(style), scale: 1)
        let dimmed = ImmersiveArtworkImage.compose(background: background, video: video, layout: makeLayout(style, dimming: 0.8), scale: 1)
        XCTAssertEqual(pixel(normal, x: 64, y: 350), pixel(dimmed, x: 64, y: 350))
        XCTAssertGreaterThan(pixel(normal, x: 64, y: 0)[1], pixel(dimmed, x: 64, y: 0)[1] + 100)
    }

    func testMirrorUsesTheVideoBottomWithoutStretchingTheBottomStrip() {
        var style = ImmersiveArtworkStyle(); style.blurRadius = 0; style.videoFadeEnabled = false
        let video = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 240),
            "inputColor0": CIColor.red, "inputColor1": CIColor.green,
        ])!.outputImage!.cropped(to: .init(x: 0, y: 0, width: 128, height: 240))
        let image = ImmersiveArtworkImage.compose(background: CIImage(color: .black), video: video,
                                                 layout: makeLayout(style), scale: 1)
        XCTAssertGreaterThan(pixel(image, x: 64, y: 155)[0], 200)
        XCTAssertLessThan(pixel(image, x: 64, y: 155)[1], 20)
        XCTAssertGreaterThan(pixel(image, x: 64, y: 80)[1], 20, "The mirror samples farther up the original, not a stretched 24% crop")
    }

    func testVariableBlurSoftensBothMediaAndBackgroundAtTheJunction() {
        var style = ImmersiveArtworkStyle(); style.videoFadeEnabled = false; style.blurRadius = 24
        let stripe = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputColor0": CIColor.red,
            "inputColor1": CIColor.black, "inputWidth": 4, "inputSharpness": 1,
        ])!.outputImage!.cropped(to: .init(x: 0, y: 0, width: 128, height: 240))
        let image = ImmersiveArtworkImage.compose(background: CIImage(color: .blue), video: stripe,
                                                 layout: makeLayout(style, reflects: false), scale: 1)
        let seam = pixel(image, x: 12, y: 158)
        XCTAssertGreaterThan(seam[0], 5)
        XCTAssertGreaterThan(seam[2], 5)
        let topDifference = abs(pixel(image, x: 0, y: 380)[0] - pixel(image, x: 4, y: 380)[0])
        let lowerDifference = abs(pixel(image, x: 0, y: 180)[0] - pixel(image, x: 4, y: 180)[0])
        XCTAssertGreaterThan(topDifference, lowerDifference + 30)
    }

    func testRealPlayerOnlyReportsFirstFrameAfterUnifiedGPUCommit() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkCompositor.Surface(frames: frames)
        surface.frame = .init(x: 0, y: 0, width: 128, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true; previous?.makeKey() }
        var firstFrame = false
        let video = AnimatedArtwork(url: url, active: true, onFirstFrame: { _, _ in firstFrame = true })
        let background = AMLLBackground(artworkURL: nil, active: true, blur: 0, mode: .solid,
                                       color: .init(red: 0, green: 0, blue: 1))
        surface.configure(.init(video: video, frames: frames, background: background, style: .init(),
            metadataTop: 400, reflects: true, reduceTransparency: false, cornerRadius: 0, opacity: 1))
        surface.layoutIfNeeded()
        let deadline = CACurrentMediaTime() + 12
        while !firstFrame && CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(firstFrame, frames.diagnosticText)
        XCTAssertGreaterThan(frames.receivedFrames, 0)
        XCTAssertGreaterThan(surface.presentedFrames, 0)
        XCTAssertEqual((surface.videoSource.layer as? AVPlayerLayer)?.opacity, 0,
                       "There is no separately presented video above the compositor")
        let before = surface.presentedFrames
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(surface.presentedFrames, before)
        XCTAssertEqual(surface.metal.isPaused, true, "Only the compositor display link schedules frames")
    }

    func testSharedBackgroundExcludesOtherModesAndSuspendedTime() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let source = AMLLBackgroundFrameSource(device: device, queue: queue)
        defer { source.stop() }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var background = AMLLBackground(artworkURL: nil, active: true, blur: 40, mode: .flowing)
        func render(_ time: Double) throws {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertNotNil(source.image(command: command, target: target, viewport: .init(width: 16, height: 16), at: time))
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
        }
        source.configure(background, reduceMotion: false, reduceTransparency: false)
        try render(0); try render(1)
        let angle = source.flowingState.angle
        XCTAssertGreaterThan(angle, 0)
        background.mode = .solid
        source.configure(background, reduceMotion: false, reduceTransparency: false)
        try render(30)
        background.mode = .flowing
        source.configure(background, reduceMotion: false, reduceTransparency: false)
        try render(60)
        XCTAssertEqual(source.flowingState.angle, angle, accuracy: 0.000001)
        source.suspendClock(); try render(120)
        XCTAssertEqual(source.flowingState.angle, angle, accuracy: 0.000001)
        try render(121)
        XCTAssertEqual(source.flowingState.angle, angle * 2, accuracy: 0.000001)
    }

    private func makeLayout(_ style: ImmersiveArtworkStyle, dimming: Double = 0, reflects: Bool = true) -> ImmersiveArtworkComposition {
        .init(viewport: .init(width: 128, height: 400), video: .init(x: 0, y: 0, width: 128, height: 240),
            reflection: .init(x: 0, y: 240, width: 128, height: 160),
            profile: .init(frame: .init(x: 0, y: 120, width: 128, height: 280), fullStrengthY: 240),
            style: style, reflectionEnabled: reflects, reduceTransparency: false, dimming: dimming)
    }

    private func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { storage in
            CIContext().render(image, toBitmap: storage.baseAddress!, rowBytes: 4,
                bounds: .init(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return bytes.map(Int.init)
    }
}
