@testable import AMLLPlayer
import UIKit
import MetalKit
import XCTest

private actor FlowingArtworkRequests {
    private var waiters: [URL: CheckedContinuation<Data, any Error>] = [:]
    private var counts: [URL: Int] = [:]

    func load(_ url: URL) async throws -> Data {
        counts[url, default: 0] += 1
        return try await withCheckedThrowingContinuation { waiters[url] = $0 }
    }

    func count(_ url: URL) -> Int { counts[url, default: 0] }
    func finish(_ url: URL, data: Data) { waiters.removeValue(forKey: url)?.resume(returning: data) }
}

@MainActor
final class AMLLFlowingArtworkTests: XCTestCase {
    private func png() throws -> Data {
        let image = UIGraphicsImageRenderer(size: .init(width: 16, height: 16)).image { context in
            UIColor.orange.setFill(); context.fill(.init(x: 0, y: 0, width: 16, height: 16))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0 ..< 400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Artwork state did not become ready")
    }

    func testLateOldSongCannotReplaceTheNewCoverOrRestartItsTransition() async throws {
        let requests = FlowingArtworkRequests()
        let coordinator = AMLLFlowingBackground.Coordinator(load: { try await requests.load($0) })
        let surface = AMLLFlowingBackgroundSurface(device: coordinator.renderer?.device)
        surface.frame = .init(x: 0, y: 0, width: 100, height: 200)
        coordinator.attach(surface)
        defer { coordinator.stop() }
        let old = try XCTUnwrap(URL(string: "https://example.invalid/old.png"))
        let new = try XCTUnwrap(URL(string: "https://example.invalid/new.png"))
        coordinator.configure(url: old, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: false)
        try await waitFor { await requests.count(old) == 1 }
        coordinator.configure(url: new, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: false)
        try await waitFor { await requests.count(new) == 1 }
        await requests.finish(new, data: try png())
        try await waitFor { coordinator.loadedURL == new }
        let progress = coordinator.state.artworkProgress
        await requests.finish(old, data: try png())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.loadedURL, new)
        XCTAssertEqual(coordinator.state.artworkProgress, progress)
    }

    func testFailedCoverDoesNotRetryEveryInputUpdate() async throws {
        let requests = FlowingArtworkRequests()
        let coordinator = AMLLFlowingBackground.Coordinator(renderer: nil, load: { try await requests.load($0) })
        defer { coordinator.stop() }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/broken.png"))
        coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: false)
        try await waitFor { await requests.count(url) == 1 }
        await requests.finish(url, data: Data([1, 2, 3]))
        try await waitFor { coordinator.failedURL == url }
        for _ in 0 ..< 30 {
            coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: false)
        }
        let count = await requests.count(url)
        XCTAssertEqual(count, 1)
        XCTAssertNil(coordinator.loadedURL)
    }

    func testLocalArtworkAndMissingGPUUseStaticBlurAndTheVisibilityClockDoesNotCatchUp() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = AMLLFlowingBackground.Coordinator(renderer: nil)
        let surface = AMLLFlowingBackgroundSurface(device: nil)
        surface.frame = .init(x: 0, y: 0, width: 100, height: 200)
        coordinator.attach(surface)
        surface.layoutIfNeeded()
        defer { coordinator.stop() }
        coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: false)
        try await waitFor { surface.fallback.image != nil }
        XCTAssertEqual(coordinator.loadedURL, url)
        XCTAssertTrue(surface.metal.isHidden)
        _ = coordinator.advanceClock(at: 1)
        _ = coordinator.advanceClock(at: 2)
        let angle = coordinator.state.angle
        coordinator.configure(url: url, configuration: .init(), active: false, reduceMotion: false, reduceTransparency: false)
        // Model a fallback whose pending filter result was discarded on hide.
        surface.fallback.image = nil
        _ = coordinator.advanceClock(at: 500)
        XCTAssertEqual(coordinator.state.angle, angle)
        coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: false)
        try await waitFor { surface.fallback.image != nil }
        _ = coordinator.advanceClock(at: 900)
        XCTAssertEqual(coordinator.state.angle, angle)
        _ = coordinator.advanceClock(at: 901)
        XCTAssertGreaterThan(coordinator.state.angle, angle)
        coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: true, reduceTransparency: false)
        _ = coordinator.advanceClock(at: 950)
        XCTAssertTrue(surface.metal.isPaused)
        XCTAssertEqual(surface.alpha, 1)
        coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: true)
        XCTAssertEqual(surface.alpha, 0)
        surface.fallback.image = nil
        coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: false, reduceTransparency: false)
        try await waitFor { surface.fallback.image != nil }
        XCTAssertEqual(surface.alpha, 1)
    }

    func testStaticRenderingFailureImmediatelyRestoresDecodedFallback() async throws {
        let renderer = try XCTUnwrap(AMLLFlowingBackgroundRenderer())
        let data = try png()
        let coordinator = AMLLFlowingBackground.Coordinator(renderer: renderer, load: { _ in data })
        let surface = AMLLFlowingBackgroundSurface(device: renderer.device)
        surface.frame = .init(x: 0, y: 0, width: 100, height: 200)
        coordinator.attach(surface)
        surface.layoutIfNeeded()
        defer { coordinator.stop() }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/static.png"))
        coordinator.configure(url: url, configuration: .init(), active: true, reduceMotion: true, reduceTransparency: false)
        try await waitFor { coordinator.loadedURL == url }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                 width: 16, height: 16, mipmapped: false)
        descriptor.usage = .renderTarget
        let invalidOutput = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        XCTAssertNil(renderer.render(target: invalidOutput, size: .init(width: 100, height: 200), state: coordinator.state))
        XCTAssertTrue(renderer.failed)
        XCTAssertNil(coordinator.renderer, "A static failure must not wait for another display frame")
        try await waitFor { surface.fallback.image != nil }
        XCTAssertTrue(surface.metal.isHidden)
        XCTAssertEqual(coordinator.loadedURL, url)
    }
}
