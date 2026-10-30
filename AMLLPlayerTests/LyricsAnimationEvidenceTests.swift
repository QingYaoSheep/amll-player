@testable import AMLLPlayer
import XCTest

@MainActor
final class LyricsAnimationEvidenceTests: XCTestCase {
    func testAdaptiveResponseClampsAndUsesGapRatherThanStartInterval() {
        let policy = LyricsAnimationMotion(style: .appleMusic164)
        for (gap, response, damping) in [(-1.0, 0.48, 0.90), (0.2, 0.48, 0.90),
                                         (0.475, 0.615, 0.84), (0.75, 0.75, 0.78), (4, 0.75, 0.78)] {
            let value = policy.vertical(lineInterval: 30, gap: gap, seeking: false, interlude: false)
            XCTAssertEqual(2 * .pi / sqrt(value.stiffness), response, accuracy: 1e-10)
            XCTAssertEqual(value.damping / (2 * sqrt(value.stiffness)), damping, accuracy: 1e-10)
        }
        XCTAssertEqual(policy.vertical(lineInterval: 1, gap: .nan, seeking: false, interlude: false), policy.initialVertical)
        XCTAssertEqual(policy.mainScale(focused: true), policy.mainScale(focused: false))
    }

    func testDecodedSpringVelocityIsDerivativeIncludingNonzeroInitialVelocity() {
        for parameters in [AMLLSpringParameters(mass: 1, damping: 18, stiffness: 100),
                           .init(mass: 1, damping: 9, stiffness: 30),
                           .init(mass: 1, damping: 25, stiffness: 100)] {
            for time in [0.0, 0.01, 0.1, 0.4] {
                let sample = LyricsBlossomSpring.sample(from: 97, to: 100, velocity: -2, time: time, parameters: parameters)
                if time == 0 { XCTAssertEqual(sample.velocity, -2); continue }
                let h = 0.00001
                let lower = LyricsBlossomSpring.sample(from: 97, to: 100, velocity: -2, time: time - h, parameters: parameters)
                let upper = LyricsBlossomSpring.sample(from: 97, to: 100, velocity: -2, time: time + h, parameters: parameters)
                XCTAssertEqual(sample.velocity, (upper.position - lower.position) / (2 * h), accuracy: 1e-6)
            }
        }
    }

    func testTemplateSamplingAndSchedulingAcrossRefreshRates() {
        for deltas in [Array(repeating: 1.0 / 60, count: 6), Array(repeating: 1.0 / 120, count: 12), [0.013, 0.027, 0.06]] {
            var spring = AMLLScheduledSpring(97)
            spring.selectStyle(.appleMusic164)
            spring.updateParameters(LyricsAnimationMotion(style: .appleMusic164).mainScale.sourceParameters)
            spring.setTarget(100, startTime: 0.05, at: 0, revision: 1)
            var time = 0.0
            for delta in deltas {
                time += delta
                // Repeated layout cannot postpone or restart the deadline.
                spring.setTarget(100, startTime: time + 1, at: time, revision: 2)
                spring.advance(to: time)
            }
            let expected = LyricsBlossomSpring.sample(from: 97, to: 100, velocity: 0, time: 0.05,
                                                       parameters: .init(mass: 1, damping: 18, stiffness: 100))
            XCTAssertEqual(spring.position, expected.position, accuracy: 1e-8)
            XCTAssertEqual(spring.velocity, expected.velocity, accuracy: 1e-8)
            XCTAssertEqual(spring.schedule.startedAt, 0.05)
        }
    }

    func testAMLLWrapperMatchesPinnedSolverAndStyleSwitchPreservesVelocity() {
        var source = AMLLSourceSpring(5), wrapper = LyricsAnimationSpring(5)
        let p = AMLLSpringParameters.scale.sourceParameters
        source.updateParameters(p); wrapper.updateParameters(p)
        for target in [100.0, -10, 40] {
            source.setTarget(target); wrapper.setTarget(target)
            for delta in [0.0, 0.01, 0.04, 0.2] {
                source.update(delta); wrapper.update(delta)
                XCTAssertEqual(source.position, wrapper.position)
                XCTAssertEqual(source.velocity, wrapper.velocity)
            }
        }
        let position = wrapper.position, velocity = wrapper.velocity, target = wrapper.target
        wrapper.selectStyle(.appleMusic164)
        XCTAssertEqual(wrapper.position, position)
        XCTAssertEqual(wrapper.velocity, velocity)
        XCTAssertEqual(wrapper.target, target)
        wrapper.selectStyle(.amll)
        XCTAssertEqual(wrapper.position, position)
        // AMLL's centered finite derivative is intentionally not exact at zero.
        XCTAssertEqual(wrapper.velocity, velocity, accuracy: 0.1)
    }

    func testFocusOpacityUsesTemplateWithoutScaleAndSettles() {
        var alpha = LyricsBlossomFocusAlpha()
        alpha.update(focused: false, delta: 0, force: true)
        alpha.update(focused: true, delta: 0.1, force: false)
        XCTAssertEqual(alpha.value.bright, 0.2 + 0.8 * (97.8310351866891 - 97) / 3, accuracy: 1e-8)
        XCTAssertGreaterThan(alpha.value.dark, 0.2)
        XCTAssertLessThan(alpha.value.dark, 0.4)
        XCTAssertFalse(alpha.arrived)
        for _ in 0 ..< 600 { alpha.update(focused: true, delta: 1.0 / 120, force: false) }
        XCTAssertTrue(alpha.arrived)
        XCTAssertEqual(alpha.value.bright, 1)
    }

    func testBackgroundPreparationWakesAtItsOwnAdvanceBoundary() throws {
        let lines = [
            LyricLine(id: "lead", text: "Lead", start: 0, end: 10,
                      words: [.init(text: "Lead", start: 0, end: 10)], precision: .word),
            LyricLine(id: "echo", text: "Echo", start: 2, end: 4,
                      words: [.init(text: "Echo", start: 2, end: 4)], isBackground: true, precision: .word),
        ]
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.animationStyle = .appleMusic164
        var options = LyricsBlossomAnimationOptions()
        options.background = 1
        environment.appleMusicAnimation = options
        environment.advance = 0.3
        var engine = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: [60, 40])
        _ = engine.render(.init(position: 1, playing: true), delta: 0)
        for _ in 0 ..< 60 { _ = engine.render(.init(position: 1.6, playing: true), delta: 1.0 / 120) }
        let before = try XCTUnwrap(engine.render(.init(position: 1.6, playing: true), delta: 0).rows.first { $0.lineIndex == 1 })
        XCTAssertEqual(before.visualFocus, .waiting)
        let after = try XCTUnwrap(engine.render(.init(position: 1.701, playing: true), delta: 0.101).rows.first { $0.lineIndex == 1 })
        XCTAssertEqual(after.visualFocus, .preparing)
        XCTAssertFalse(after.active)
        XCTAssertFalse(after.fillComplete)
        XCTAssertFalse(after.hdrHold)
    }

}
