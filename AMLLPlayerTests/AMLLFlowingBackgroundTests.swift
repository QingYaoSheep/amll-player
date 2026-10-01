@testable import AMLLPlayer
import XCTest

final class AMLLFlowingBackgroundTests: XCTestCase {
    func testIndependentClockKeepsAngleWhenSpeedChangesAndFreezesWhenHidden() {
        var state = AMLLFlowingBackgroundState()
        state.advance(seconds: 60)
        XCTAssertEqual(state.angle, .pi / 2, accuracy: 0.000001)
        var settings = FlowingBackgroundConfiguration()
        settings.rotationSpeed = 3
        state.configure(settings)
        XCTAssertEqual(state.angle, .pi / 2, accuracy: 0.000001)
        state.advance(seconds: 30)
        XCTAssertEqual(state.angle, .pi, accuracy: 0.000001)
        state.advance(seconds: 3600, running: false)
        XCTAssertEqual(state.angle, .pi, accuracy: 0.000001)
    }

    func testParametersEaseContinuouslyAndRepeatedConfigurationDoesNotRestart() {
        var state = AMLLFlowingBackgroundState()
        let next = FlowingBackgroundConfiguration(rotationSpeed: 0, distortion: 8, blur: 80)
        state.configure(next)
        XCTAssertEqual(state.distortion, 3)
        XCTAssertEqual(state.blur, 40)
        state.advance(seconds: 0.15)
        XCTAssertGreaterThan(state.distortion, 3)
        XCTAssertLessThan(state.distortion, 8)
        XCTAssertGreaterThan(state.blur, 40)
        XCTAssertLessThan(state.blur, 80)
        state.configure(next)
        state.advance(seconds: 0.15)
        XCTAssertEqual(state.distortion, 8)
        XCTAssertEqual(state.blur, 80)
        XCTAssertEqual(state.angle, 0)
    }

    func testOneSecondCoverTransitionPreservesWavePhaseAndCanBeInterrupted() {
        var state = AMLLFlowingBackgroundState()
        state.advance(seconds: 5)
        let angle = state.angle, phase = state.phase18
        state.beginArtworkTransition(hasPrevious: true)
        XCTAssertEqual(state.angle, angle)
        XCTAssertEqual(state.phase18, phase)
        XCTAssertEqual(state.artworkProgress, 0)
        state.advance(seconds: 0.5)
        XCTAssertEqual(state.artworkProgress, 0.5)
        state.beginArtworkTransition(hasPrevious: true)
        state.advance(seconds: 1)
        XCTAssertEqual(state.artworkProgress, 1)
        state.beginArtworkTransition(hasPrevious: true, immediately: true)
        XCTAssertEqual(state.artworkProgress, 1)
    }

    func testLongRunAtDifferentFrameIntervalsHasTheSamePhase() {
        var reference = AMLLFlowingBackgroundState()
        reference.advance(seconds: 900)
        for intervals in [[1.0 / 60], [1.0 / 120], [0.011, 0.027, 0.08, 0.014]] {
            var state = AMLLFlowingBackgroundState()
            var elapsed = 0.0, index = 0
            while elapsed < 900 {
                let delta = min(intervals[index % intervals.count], 900 - elapsed)
                state.advance(seconds: delta)
                elapsed += delta; index += 1
            }
            XCTAssertEqual(sin(state.angle), sin(reference.angle), accuracy: 0.00001)
            XCTAssertEqual(cos(state.angle), cos(reference.angle), accuracy: 0.00001)
            XCTAssertEqual(sin(state.phase18), sin(reference.phase18), accuracy: 0.00001)
            XCTAssertEqual(sin(state.phase27), sin(reference.phase27), accuracy: 0.00001)
        }
    }

    func testCoverageIncludesRotatedCornersAndMaximumWarpInEveryViewport() {
        let known = AMLLFlowingBackgroundState.coverExtent(width: 3, height: 4, imageAspect: 1)
        XCTAssertEqual(known.width, 5.48, accuracy: 0.000001)
        for (width, height) in [(402.0, 874.0), (874, 402), (1376, 1032), (320, 1032)] {
            for aspect in [0.5, 1.0, 2.0] {
                let extent = AMLLFlowingBackgroundState.coverExtent(width: width, height: height, imageAspect: aspect)
                for degrees in stride(from: 0.0, through: 360, by: 15) {
                    let angle = degrees * .pi / 180
                    for x in [-width / 2, width / 2] {
                        for y in [-height / 2, height / 2] {
                            let allowance = min(width, height) * 0.08
                            XCTAssertLessThanOrEqual(abs(cos(angle) * x + sin(angle) * y) + allowance, extent.width / 2 + 0.00001)
                            XCTAssertLessThanOrEqual(abs(-sin(angle) * x + cos(angle) * y) + allowance, extent.height / 2 + 0.00001)
                        }
                    }
                }
            }
        }
    }

    func testPartialConfigurationAndOldPreferencesKeepTheirBackgroundAndOtherValues() throws {
        let partial = try JSONDecoder().decode(FlowingBackgroundConfiguration.self, from: Data("{\"distortion\":6}".utf8))
        XCTAssertEqual(partial, .init(rotationSpeed: 1.5, distortion: 6, blur: 40))
        var configuration = LyricsRenderConfiguration()
        configuration.backgroundMode = .pixi
        configuration.backgroundBlur = 25
        let data = try JSONEncoder().encode(configuration)
        let old = try JSONDecoder().decode(LyricsRenderConfiguration.self, from: data)
        XCTAssertEqual(old.backgroundMode, .pixi)
        XCTAssertNil(old.flowingBackground)
        XCTAssertEqual(old.backgroundBlur, 25)
        XCTAssertEqual(FlowingBackgroundConfiguration(rotationSpeed: .nan, distortion: -9, blur: 999).validated(),
                       .init(rotationSpeed: 1.5, distortion: 0, blur: 80))
    }
}

@MainActor
final class AMLLFlowingPreferencesTests: XCTestCase {
    func testSettingsSurviveRelaunchAndLocalResetKeepsMeshAndLyricsSettings() throws {
        let name = "flowing-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.configuration.backgroundMode = .flowing
        preferences.configuration.fontSize = 43
        preferences.configuration.backgroundBlur = 25
        preferences.configuration.flowingBackground = .init(rotationSpeed: 4, distortion: 7, blur: 65)
        let restored = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(restored.configuration, preferences.configuration)
        restored.configuration.flowingBackground = .init()
        let reset = LyricsRenderPreferences(defaults: defaults).configuration
        XCTAssertEqual(reset.flowingBackground, .init())
        XCTAssertEqual(reset.backgroundMode, .flowing)
        XCTAssertEqual(reset.backgroundBlur, 25)
        XCTAssertEqual(reset.fontSize, 43)
    }
}
