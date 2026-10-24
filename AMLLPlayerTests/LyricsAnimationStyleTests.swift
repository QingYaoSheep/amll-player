@testable import AMLLPlayer
import XCTest

@MainActor
final class LyricsAnimationStyleTests: XCTestCase {
    func testOlderAndUnknownStylesKeepSavedAMLLMotionAndOtherPreferences() throws {
        var original = LyricsRenderConfiguration()
        original.advance = 1
        original.enableSpring = false
        original.gradientWidth = 0.75
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "animationProfiles")
        let old = try JSONDecoder().decode(LyricsRenderConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.animationStyle, .amll)
        XCTAssertEqual(old.advance, 1)
        XCTAssertFalse(old.enableSpring)
        json["animationProfiles"] = ["selected": "future-style"]
        let unknown = try JSONDecoder().decode(LyricsRenderConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(unknown.animationStyle, .amll)
        XCTAssertEqual(unknown.gradientWidth, 0.75)
        XCTAssertEqual(unknown.fontSize, original.fontSize)
        json["animationProfiles"] = [:] as [String: Any]
        let empty = try JSONDecoder().decode(LyricsRenderConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(empty.animationStyle, .amll)
        XCTAssertEqual(empty.advance, 1)
        XCTAssertFalse(empty.enableSpring)
    }

    func testStyleSwitchCopiesOnceAndRestoresIndependentOptionsWithoutChangingLayout() throws {
        let name = "animation-style-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.configuration.fontSize = 41
        preferences.configuration.anchor = 0.35
        preferences.configuration.advance = 1
        preferences.configuration.enableScale = false
        preferences.configuration.selectAnimationStyle(.appleMusic164)
        XCTAssertEqual(preferences.configuration.advance, 1)
        XCTAssertFalse(preferences.configuration.enableScale)
        preferences.configuration.advance = 0
        preferences.configuration.emphasizeWords = false
        preferences.configuration.selectAnimationStyle(.amll)
        XCTAssertEqual(preferences.configuration.advance, 1)
        XCTAssertTrue(preferences.configuration.emphasizeWords)
        preferences.configuration.selectAnimationStyle(.appleMusic164)
        XCTAssertEqual(preferences.configuration.advance, 0)
        XCTAssertFalse(preferences.configuration.emphasizeWords)
        XCTAssertEqual(preferences.configuration.fontSize, 41)
        XCTAssertEqual(preferences.configuration.anchor, 0.35)
        let restored = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(restored.configuration.animationStyle, .appleMusic164)
        XCTAssertFalse(restored.configuration.emphasizeWords)
        restored.configuration.restoreCurrentAnimationDefaults()
        XCTAssertTrue(restored.configuration.emphasizeWords)
        XCTAssertEqual(restored.configuration.fontSize, 41)
        restored.configuration.selectAnimationStyle(.amll)
        XCTAssertEqual(restored.configuration.advance, 1)
        XCTAssertFalse(restored.configuration.enableScale)
    }

    func testVerifiedFixedSpringSamplesAreIndependentOfFrameRate() {
        for deltas in [Array(repeating: 1.0 / 60, count: 6), Array(repeating: 1.0 / 120, count: 12), [0.013, 0.027, 0.06]] {
            var spring = AMLLSourceSpring(97)
            spring.updateParameters(LyricsAnimationMotion(style: .appleMusic164).mainScale.sourceParameters)
            spring.setTarget(100)
            for delta in deltas { spring.update(delta) }
            // Independently evaluated damped oscillator: m=1, k=100, c=18,
            // x(0)=97, v(0)=0, target=100, t=0.1. Not a button timing curve.
            XCTAssertEqual(spring.position, 97.8310351866891, accuracy: 0.000001)
        }
    }

    func testAMLLExplicitStyleMatchesLegacyEngineAndSwitchRetainsClocksAndPresentation() throws {
        let lines = (0 ..< 5).map { index in
            LyricLine(id: String(index), text: "Line", start: Double(index) * 2, end: Double(index) * 2 + 1.5,
                      words: [.init(text: "Line", start: Double(index) * 2, end: Double(index) * 2 + 1.5)], precision: .word)
        }
        let document = AMLLDisplayDocument(lines: lines)
        for delta in [1.0 / 60, 1.0 / 120, 0.037] {
            var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
            environment.alignPosition = 0.28
            var legacy = AMLLFrameEngine(document: document, environment: environment, heights: Array(repeating: 60, count: 5))
            environment.animationStyle = .amll
            var explicit = AMLLFrameEngine(document: document, environment: environment, heights: Array(repeating: 60, count: 5))
            var time = 0.0
            for _ in 0 ..< 150 {
                time += delta
                let input = AMLLPlayerInput(position: time, playing: true)
                let oldFrame = legacy.render(input, delta: delta)
                let newFrame = explicit.render(input, delta: delta)
                XCTAssertEqual(oldFrame.rows, newFrame.rows)
                XCTAssertEqual(oldFrame.lyricTime, newFrame.lyricTime)
                XCTAssertEqual(oldFrame.focusGroup, newFrame.focusGroup)
            }
            let input = AMLLPlayerInput(position: time, playing: true)
            let before = explicit.render(input, delta: 0)
            let revision = explicit.timeAnchorRevision
            environment.animationStyle = .appleMusic164
            explicit.resize(environment: environment, heights: Array(repeating: 60, count: 5))
            let after = explicit.render(input, delta: 0)
            XCTAssertEqual(explicit.timeAnchorRevision, revision)
            XCTAssertEqual(before.lyricTime, after.lyricTime)
            XCTAssertEqual(before.focusGroup, after.focusGroup)
            for (old, new) in zip(before.rows, after.rows) {
                XCTAssertEqual(old.y, new.y, accuracy: 0.000001)
                XCTAssertEqual(old.scale, new.scale, accuracy: 0.000001)
                XCTAssertEqual(old.wordClock, new.wordClock)
                XCTAssertEqual(old.visualFocus, new.visualFocus)
                XCTAssertEqual(old.brightAlpha, new.brightAlpha, accuracy: 0.000001)
            }
        }
    }

    func testSwitchingSavedSpringModesDuringMotionHasNoPresentationJump() {
        let lines = (0 ..< 5).map { index in
            LyricLine(id: String(index), text: "Line", start: Double(index) * 2, end: Double(index) * 2 + 1.5,
                      words: [.init(text: "Line", start: Double(index) * 2, end: Double(index) * 2 + 1.5)], precision: .word)
        }
        for initialSpring in [true, false] {
            var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
            environment.enableSpring = initialSpring
            var engine = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: Array(repeating: 60, count: 5))
            _ = engine.render(.init(position: 0.1, playing: true), delta: 0)
            let input = AMLLPlayerInput(position: 2.1, playing: true)
            _ = engine.render(input, delta: 0.06)
            let before = engine.render(input, delta: 0)
            environment.animationStyle = .appleMusic164
            environment.enableSpring = !initialSpring
            engine.resize(environment: environment, heights: Array(repeating: 60, count: 5))
            let after = engine.render(input, delta: 0)
            for (old, new) in zip(before.rows, after.rows) {
                XCTAssertEqual(old.y, new.y, accuracy: 0.000001)
                XCTAssertEqual(old.scale, new.scale, accuracy: 0.000001)
                XCTAssertEqual(old.wordClock, new.wordClock)
            }
        }
    }

    func testSourcePresetsMatchByFieldsAndManualEditsBecomeCustom() throws {
        var options = LyricsBlossomAnimationOptions()
        XCTAssertEqual(options.matchedPreset, .appleMusic164)
        options.apply(.advance)
        XCTAssertEqual(options.selection, 0)
        XCTAssertEqual(options.matchedPreset, .advance)
        options.apply(.appleMusic264)
        XCTAssertEqual([options.background, options.scale, options.word, options.emphasis, options.selection, options.maximum], [1, 2, 1, 1, 2, 0])
        XCTAssertEqual(options.matchedPreset, .appleMusic264)
        options.maximumLines = 3
        XCTAssertEqual(options.matchedPreset, .custom)
        XCTAssertFalse(options.limitsSelection)
        options.maximumLines = 2
        XCTAssertEqual(options.matchedPreset, .appleMusic264)
        options.apply(.appleMusic27)
        XCTAssertEqual(options.word, 3, "Preset fields use stored values, not the UI's swapped index")
        XCTAssertEqual(options.matchedPreset, .appleMusic27)
        let decoded = try JSONDecoder().decode(LyricsBlossomAnimationOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, LyricsBlossomAnimationOptions())
        options.emphasis = 1
        XCTAssertEqual(options.emphasisReleaseWeight(lineTime: 1, wordEnd: 1, reverseElapsed: 0), 1)
        XCTAssertEqual(options.emphasisReleaseWeight(lineTime: 1.125, wordEnd: 1, reverseElapsed: 0), 0.5)
        XCTAssertEqual(options.emphasisReleaseWeight(lineTime: 1.25, wordEnd: 1, reverseElapsed: 0), 0)
    }

    func testSelectionLimitDoesNotChangeOverlappingVoiceClocksOrActualActivity() {
        let lines = (0 ..< 4).map { index in
            LyricLine(id: String(index), text: "Line", start: 0, end: 5,
                      words: [.init(text: "Line", start: 0, end: 5)], precision: .word)
        }
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.animationStyle = .appleMusic164
        var options = LyricsBlossomAnimationOptions()
        options.maximumLines = 3
        environment.appleMusicAnimation = options
        var limited = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: Array(repeating: 60, count: 4))
        let before = limited.render(.init(position: 0.5, playing: true), delta: 0)
        XCTAssertTrue(before.rows.allSatisfy(\.active))
        XCTAssertEqual(before.rows.filter { $0.brightAlpha > 0.5 }.count, 3)
        options.selection = 2
        environment.appleMusicAnimation = options
        var unlimited = AMLLFrameEngine(document: .init(lines: lines), environment: environment, heights: Array(repeating: 60, count: 4))
        let after = unlimited.render(.init(position: 0.5, playing: true), delta: 0)
        XCTAssertEqual(after.rows.filter { $0.brightAlpha > 0.5 }.count, 4)
        XCTAssertEqual(before.rows.map(\.wordClock), after.rows.map(\.wordClock))
        XCTAssertEqual(before.lyricTime, after.lyricTime)
    }

    func testFineOptionsSurviveStyleChangesRelaunchAndResetOnlyWithAppleDefaults() throws {
        let name = "animation-versions-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.configuration.selectAnimationStyle(.appleMusic164)
        var options = LyricsBlossomAnimationOptions()
        options.apply(.appleMusic264)
        options.selection = 0
        options.maximumLines = 3
        preferences.configuration.appleMusicAnimation = options
        preferences.configuration.selectAnimationStyle(.amll)
        preferences.configuration.restoreCurrentAnimationDefaults()
        XCTAssertEqual(preferences.configuration.appleMusicAnimation, options)
        let restored = LyricsRenderPreferences(defaults: defaults)
        restored.configuration.selectAnimationStyle(.appleMusic164)
        XCTAssertEqual(restored.configuration.appleMusicAnimation, options)
        XCTAssertEqual(restored.configuration.appleMusicAnimation?.matchedPreset, .custom)
        restored.configuration.restoreCurrentAnimationDefaults()
        XCTAssertEqual(restored.configuration.appleMusicAnimation, LyricsBlossomAnimationOptions())
        XCTAssertEqual(restored.configuration.appleMusicAnimation?.matchedPreset, .appleMusic164)
    }
}
