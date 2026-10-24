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
}
