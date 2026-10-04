@testable import AMLLPlayer
import CoreVideo
import XCTest

@MainActor
final class ArtworkFrameSessionTests: XCTestCase {
    func testOldProducerCannotClearOrRetakeReplacementSession() throws {
        let frames = ArtworkReflectionFrames()
        let first = frames.makePresentation()
        let second = frames.makePresentation()
        let oldReflection = ArtworkReflection.Surface()
        let currentReflection = ArtworkReflection.Surface()
        let oldBlur = ImmersiveLiveBlurSurface()
        let currentBlur = ImmersiveLiveBlurSurface()
        XCTAssertTrue(frames.activate(first, reflection: oldReflection, blur: oldBlur))
        let oldSource = try XCTUnwrap(frames.begin(presentation: first, resource: UUID()))
        let buffer = try pixelBuffer()
        XCTAssertTrue(frames.display(buffer, source: oldSource))
        XCTAssertTrue(frames.activate(second, reflection: currentReflection, blur: currentBlur))
        let currentSource = try XCTUnwrap(frames.begin(presentation: second, resource: UUID()))
        frames.outputAttached = true
        XCTAssertTrue(frames.display(buffer, source: currentSource))

        XCTAssertFalse(frames.display(buffer, source: oldSource))
        frames.clear(source: oldSource)
        frames.release(first)
        XCTAssertFalse(frames.activate(first, reflection: oldReflection, blur: oldBlur))
        XCTAssertNil(frames.begin(presentation: first, resource: UUID()))
        XCTAssertTrue(frames.accepts(source: currentSource))
        XCTAssertTrue(frames.hasFrame)
        XCTAssertTrue(frames.outputAttached)
        XCTAssertTrue(frames.surface === currentReflection)
        XCTAssertTrue(frames.liveBlurSurface === currentBlur)
        XCTAssertEqual(frames.acquiredFrames, 2)
        XCTAssertEqual(frames.receivedFrames, 1)
        XCTAssertEqual(frames.rejectedFrames, 1)
        XCTAssertEqual(frames.rejectionReason, "帧来源与当前会话不匹配")
    }

    func testRepeatedActivationPreservesPausedPixelsAndResourceSession() throws {
        let frames = ArtworkReflectionFrames()
        let owner = frames.makePresentation()
        let reflection = ArtworkReflection.Surface()
        let blur = ImmersiveLiveBlurSurface()
        XCTAssertTrue(frames.activate(owner, reflection: reflection, blur: blur))
        let source = try XCTUnwrap(frames.begin(presentation: owner, resource: UUID()))
        let buffer = try pixelBuffer()
        XCTAssertTrue(frames.display(buffer, source: source))
        let diagnostic = frames.sessionDiagnostic
        for _ in 0 ..< 20 {
            XCTAssertTrue(frames.activate(owner, reflection: reflection, blur: blur))
            frames.replayLatest()
        }
        XCTAssertTrue(frames.accepts(source: source))
        XCTAssertTrue(frames.currentBuffer === buffer)
        XCTAssertEqual(frames.receivedFrames, 1, "Replaying a paused frame is not decoding another frame")
        XCTAssertEqual(frames.sessionDiagnostic, diagnostic)
    }

    func testEndedSessionRejectsOldPixelsAndOlderPresentationsStayRetired() throws {
        let frames = ArtworkReflectionFrames()
        let old = frames.makePresentation()
        let owner = frames.makePresentation()
        let reflection = ArtworkReflection.Surface()
        let blur = ImmersiveLiveBlurSurface()
        XCTAssertTrue(frames.activate(owner, reflection: reflection, blur: blur))
        let source = try XCTUnwrap(frames.begin(presentation: owner, resource: UUID()))
        frames.release(owner)
        XCTAssertFalse(frames.display(try pixelBuffer(), source: source))
        XCTAssertEqual(frames.acquiredFrames, 1)
        XCTAssertEqual(frames.receivedFrames, 0)
        XCTAssertEqual(frames.rejectionReason, "当前会话已结束")
        XCTAssertFalse(frames.activate(old, reflection: reflection, blur: blur))
        XCTAssertNil(frames.surface)
        XCTAssertNil(frames.liveBlurSurface)
        XCTAssertFalse(frames.hasFrame)
        let replacement = frames.makePresentation()
        XCTAssertTrue(frames.activate(replacement, reflection: reflection, blur: blur))
        XCTAssertNotNil(frames.begin(presentation: replacement, resource: UUID()))
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 8,
            kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
