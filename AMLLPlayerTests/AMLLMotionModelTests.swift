@testable import AMLLPlayer
import Foundation
import XCTest

final class AMLLMotionModelTests: XCTestCase {
    func testVerticalSpringMatchesAMLLAnalyticSolver() {
        var spring = AMLLSpring(value: 0)
        spring.parameters = .verticalDefault
        let value = spring.step(target: 100, delta: 1.0 / 60.0)

        XCTAssertEqual(value, 1.265865921164803, accuracy: 0.000_000_1)
        XCTAssertEqual(spring.velocity, 144.84901316301875, accuracy: 0.000_000_1)
    }

    func testScaleSpringRetargetsWithoutDiscardingVelocity() {
        var spring = AMLLSpring(value: 97)
        spring.parameters = .scale
        _ = spring.step(target: 100, delta: 1.0 / 120.0)
        let firstVelocity = spring.velocity
        _ = spring.step(target: 97, delta: 1.0 / 120.0)

        XCTAssertGreaterThan(firstVelocity, 0)
        XCTAssertTrue(spring.velocity.isFinite)
        XCTAssertTrue(spring.value.isFinite)
    }

    func testAMLLDynamicVerticalSpringUsesSourceIntervals() {
        let fastest = AMLLMotionMetrics.verticalSpring(lineInterval: 0.1, seeking: false, interlude: false)
        XCTAssertEqual(fastest.stiffness, 220, accuracy: 0.000_001)
        XCTAssertEqual(fastest.damping, sqrt(220) * 2.2, accuracy: 0.000_001)

        let slowest = AMLLMotionMetrics.verticalSpring(lineInterval: 0.8, seeking: false, interlude: false)
        XCTAssertEqual(slowest.stiffness, 170, accuracy: 0.000_001)
        XCTAssertEqual(slowest.damping, sqrt(170) * 2.2, accuracy: 0.000_001)

        XCTAssertEqual(AMLLMotionMetrics.verticalSpring(lineInterval: 0.2, seeking: true, interlude: false), .verticalDefault)
    }

    func testInterludeDotsMatchAMLLStaggerAndBreathing() throws {
        let middle = try XCTUnwrap(AMLLInterludeMotion.presentation(time: 2.5, start: 0, end: 5, playing: true))
        XCTAssertEqual(middle.scale, 0.7228775267302263, accuracy: 0.000_000_1)
        XCTAssertEqual(middle.dotOpacities[0], 1, accuracy: 0.000_000_1)
        XCTAssertEqual(middle.dotOpacities[1], 0.5735294117647058, accuracy: 0.000_000_1)
        XCTAssertEqual(middle.dotOpacities[2], 0.25, accuracy: 0.000_000_1)

        let entering = try XCTUnwrap(AMLLInterludeMotion.presentation(time: 0.75, start: 0, end: 5, playing: true))
        XCTAssertEqual(entering.dotOpacities[0], 0.1985294117647059, accuracy: 0.000_000_1)
        XCTAssertEqual(entering.dotOpacities[1], 0.125, accuracy: 0.000_000_1)
        XCTAssertEqual(entering.dotOpacities[2], 0.125, accuracy: 0.000_000_1)
        XCTAssertNotNil(AMLLInterludeMotion.presentation(time: 2.5, start: 0, end: 5, playing: false))
    }

    func testInteractionStateKeepsBrowseAndSeekSeparate() {
        var model = LyricsMotionModel()
        model.handle(.beginBrowsing, at: 10)
        XCTAssertEqual(model.mode, .browsing)
        model.handle(.seek(to: 42), at: 11)
        XCTAssertEqual(model.mode, .seeking)
        XCTAssertEqual(model.pendingSeek, 42)
        model.handle(.resumeFollowing, at: 12)
        XCTAssertEqual(model.mode, .returning)
        model.settledFollowing()
        XCTAssertEqual(model.mode, .following)
    }

    func testShortWordsUseAMLLFloatInsteadOfLongWordEmphasis() {
        XCTAssertFalse(AMLLMotionMetrics.shouldEmphasize(text: "short", duration: 0.4))
        XCTAssertTrue(AMLLMotionMetrics.shouldEmphasize(text: "short", duration: 1))
        XCTAssertTrue(AMLLMotionMetrics.shouldEmphasize(text: "唱", duration: 1))

        let presentation = AMLLWordMotion.presentation(
            time: 0.2, wordStart: 0, wordEnd: 0.4, characterIndex: 0, characterCount: 5,
            text: "short", isLastWord: false, isBackground: false, enabled: true
        )
        XCTAssertEqual(presentation.scale, 1)
        XCTAssertEqual(presentation.glowOpacity, 0)
        XCTAssertLessThan(presentation.offsetY, 0)
    }

    func testBrowsingReturnsAfterAMLLFiveSecondTimeout() {
        var model = LyricsMotionModel()
        model.handle(.beginBrowsing, at: 10)
        XCTAssertFalse(model.resumeIfBrowseTimedOut(at: 14.999))
        XCTAssertTrue(model.resumeIfBrowseTimedOut(at: 15))
        XCTAssertEqual(model.mode, .returning)
    }
}
