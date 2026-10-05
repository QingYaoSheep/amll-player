@testable import AMLLPlayer
import CoreImage
import Metal
import UIKit
import XCTest

@MainActor
final class AMLLBackgroundFrameSourceTests: XCTestCase {
    func testCompletedTexturePreservesOrientationAndColorThroughTheActualBlurDrawable() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = AMLLBackgroundFrameSource()
        source.setEnabled(true)
        let texture = try makeTexture(device, top: [0, 0, 255, 255], bottom: [255, 0, 0, 255])
        let viewport = CGSize(width: 100, height: 120)
        try copy(texture, through: source, viewport: viewport)
        let frame = try XCTUnwrap(source.current(viewport: viewport))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let surface = ImmersiveLiveBlurSurface()
        surface.frame = CGRect(origin: .zero, size: viewport)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true; source.setEnabled(false) }
        let scale = min(1.5, window.screen.scale)
        surface.capture = {
            .init(region: surface.frame, profile: .init(frame: surface.frame, fullStrengthY: 120),
                scale: scale, planes: [.background(frame, frame: surface.frame, opacity: 1)])
        }
        surface.configure(amount: 1 / 80.0, mask: nil)
        surface.layoutIfNeeded()
        surface.requestOutputSnapshot()
        let deadline = Date().addingTimeInterval(5)
        while surface.capturedOutput == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let image = try XCTUnwrap(surface.capturedOutput, "Export the actual submitted drawable")
        let context = CIContext()
        func pixel(topY: CGFloat) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes {
                context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 4,
                    bounds: CGRect(x: CGFloat(image.width) / 2, y: CGFloat(image.height) - topY * scale - 1,
                        width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return bytes
        }
        XCTAssertGreaterThan(pixel(topY: 10)[0], 240)
        XCTAssertLessThan(pixel(topY: 10)[2], 10)
        XCTAssertGreaterThan(pixel(topY: 110)[2], 240)
        XCTAssertLessThan(pixel(topY: 110)[0], 10)
        XCTAssertLessThanOrEqual(surface.maximumInFlight, 2)
    }

    func testRetainedFramesStayImmutableAndPoolRemainsBounded() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = AMLLBackgroundFrameSource()
        source.setEnabled(true)
        let viewport = CGSize(width: 8, height: 8)
        var retained: [AMLLBackgroundTextureFrame] = []
        for index in 0 ..< 4 {
            let color: [UInt8] = index == 0 ? [0, 0, 255, 255] : [0, 255, 0, 255]
            let texture = try makeTexture(device, top: color, bottom: color)
            try copy(texture, through: source, viewport: viewport)
            retained.append(try XCTUnwrap(source.current(viewport: viewport)))
        }
        let first = try XCTUnwrap(retained.first)
        let latest = try XCTUnwrap(retained.last)
        let blue = try makeTexture(device, top: [255, 0, 0, 255], bottom: [255, 0, 0, 255])
        try copy(blue, through: source, viewport: viewport)
        XCTAssertEqual(source.current(viewport: viewport)?.sequence, latest.sequence,
            "An occupied texture must never be overwritten to publish a new frame")
        XCTAssertLessThanOrEqual(source.statistics.textures, 4)
        XCTAssertEqual(source.statistics.skipped, 1)
        let image = try XCTUnwrap(CIImage(mtlTexture: first.texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]))
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            CIContext(mtlDevice: device).render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        XCTAssertGreaterThan(bytes[0], 240, "The first reader must still see red after newer green and blue submissions")
        XCTAssertLessThan(bytes[1], 10)
        source.setEnabled(false)
        XCTAssertNil(source.current(viewport: viewport))
        XCTAssertEqual(source.statistics.textures, 0)
        retained.removeAll()
    }

    func testResizeAndRetiredCommandsCannotPublishAnOldViewport() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = AMLLBackgroundFrameSource()
        source.setEnabled(true)
        let texture = try makeTexture(device, top: [0, 0, 255, 255], bottom: [0, 0, 255, 255])
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let oldCommand = try XCTUnwrap(queue.makeCommandBuffer())
        source.encodeCopy(texture: texture, viewport: CGSize(width: 8, height: 8), timestamp: 0, command: oldCommand)
        source.setEnabled(false)
        source.setEnabled(true)
        oldCommand.commit(); oldCommand.waitUntilCompleted()
        XCTAssertNil(source.current(viewport: CGSize(width: 8, height: 8)))
        try copy(texture, through: source, viewport: CGSize(width: 12, height: 8))
        XCTAssertNotNil(source.current(viewport: CGSize(width: 12, height: 8)))
        XCTAssertNil(source.current(viewport: CGSize(width: 8, height: 8)))
        source.setEnabled(false)
    }

    private func makeTexture(_ device: any MTLDevice, top: [UInt8], bottom: [UInt8]) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes: [UInt8] = []
        for y in 0 ..< 8 { for _ in 0 ..< 8 { bytes.append(contentsOf: y < 4 ? top : bottom) } }
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 32) }
        return texture
    }

    private func copy(_ texture: any MTLTexture, through source: AMLLBackgroundFrameSource, viewport: CGSize) throws {
        let queue = try XCTUnwrap(texture.device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        source.encodeCopy(texture: texture, viewport: viewport, timestamp: CACurrentMediaTime(), command: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
    }
}
