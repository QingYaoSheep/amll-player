@testable import AMLLPlayer
import XCTest

@MainActor
final class LyricsRenderPreferencesTests: XCTestCase {
    func testPageAdjustmentsDecodeOlderConfigurationAndPersist() throws {
        let original = LyricsRenderConfiguration()
        let oldData = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LyricsRenderConfiguration.self, from: oldData)
        XCTAssertNil(decoded.horizontalPadding)
        XCTAssertNil(decoded.auxiliaryScale)
        let name = "appearance-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.configuration.horizontalPadding = 36
        preferences.configuration.paragraphSpacing = 24
        preferences.configuration.auxiliaryScale = 0.7
        preferences.configuration.backgroundDimming = 0.4
        preferences.configuration.artworkCornerRadius = 20
        preferences.configuration.showMetadata = false
        XCTAssertEqual(LyricsRenderPreferences(defaults: defaults).configuration, preferences.configuration)
        var invalid = original
        invalid.horizontalPadding = 999
        invalid.auxiliaryScale = .nan
        invalid.backgroundDimming = -1
        XCTAssertEqual(invalid.validated().horizontalPadding, 60)
        XCTAssertEqual(invalid.validated().auxiliaryScale, 0.5)
        XCTAssertEqual(invalid.validated().backgroundDimming, 0)
    }

    func testSettingsSurviveRelaunchAndReset() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.activate(.custom)
        preferences.configuration.fontSize = 40
        preferences.configuration.translation = false
        preferences.configuration.remainingTime = true
        let restored = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(restored.configuration.fontSize, 40)
        XCTAssertFalse(restored.configuration.translation)
        XCTAssertTrue(restored.configuration.remainingTime)
        XCTAssertEqual(restored.profile, .custom)
        restored.restoreAMLLDefaults()
        XCTAssertEqual(LyricsRenderPreferences(defaults: defaults).configuration, .amllDefault)
        XCTAssertEqual(LyricsRenderPreferences(defaults: defaults).profile, .amll)
    }

    func testProfileSwitchPreservesEditedCustomValuesAndRestoresAMLLBaseline() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.activate(.custom)
        preferences.configuration.fontSize = 41
        preferences.activate(.amll)
        XCTAssertEqual(preferences.configuration, .amllDefault)
        preferences.activate(.custom)
        XCTAssertEqual(preferences.configuration.fontSize, 41)
        preferences.configuration.fontSize = 43
        preferences.activate(.amll)
        preferences.activate(.custom)
        XCTAssertEqual(preferences.configuration.fontSize, 43)
    }

    func testLegacyPartialSettingsGainNewDefaultsAndClampRanges() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"fontSize":999,"translation":false,"backgroundBlur":-4,"credits":"preferred"}"#.utf8), forKey: "lyrics.render.v1")
        let preferences = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(preferences.profile, .amll)
        XCTAssertEqual(preferences.configuration, .amllDefault)
        let migrated = try XCTUnwrap(preferences.migratedCustomConfiguration)
        XCTAssertEqual(migrated.fontSize, 52)
        XCTAssertEqual(migrated.backgroundBlur, 0)
        XCTAssertFalse(migrated.translation)
        XCTAssertTrue(migrated.romanization)
        XCTAssertFalse(migrated.remainingTime)
        XCTAssertEqual(migrated.credits, .preferLyricAuthor)
        XCTAssertEqual(migrated.gradientWidth, 0.5)
    }

    func testCorruptAndFutureVersionSettingsFallBackWithoutDeletingData() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for raw in ["invalid", #"{"version":99,"configuration":{"fontSize":40}}"#] {
            let data = Data(raw.utf8)
            defaults.set(data, forKey: "lyrics.render.v1")
            XCTAssertEqual(LyricsRenderPreferences(defaults: defaults).configuration, .amllDefault)
            XCTAssertEqual(defaults.data(forKey: "lyrics.render.v1"), data)
        }
    }

    func testLegacyPointGradientMigratesToAMLLRelativeEmWidth() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"fontSize":40,"gradientWidth":20}"#.utf8), forKey: "lyrics.render.v1")
        let preferences = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(try XCTUnwrap(preferences.migratedCustomConfiguration).gradientWidth, 0.5)
    }

    func testStoredAppleMusicProfileMigratesToUnifiedAMLLPage() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let encodedConfiguration = try JSONEncoder().encode(LyricsRenderConfiguration())
        let configuration = try JSONSerialization.jsonObject(with: encodedConfiguration)
        let object: [String: Any] = [
            "version": 2,
            "profile": "appleMusic26",
            "configuration": configuration,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: object)
        defaults.set(encoded, forKey: "lyrics.render.v2")

        let preferences = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(preferences.profile, .amll)
        XCTAssertEqual(preferences.configuration, LyricsRenderConfiguration())
    }

    func testAMLLTypographySurvivesRepeatedRelaunches() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.configuration.fontSize = 32
        preferences.configuration.sizePreset = nil
        preferences.configuration.bold = false
        for _ in 0 ..< 3 {
            let restored = LyricsRenderPreferences(defaults: defaults)
            XCTAssertEqual(restored.profile, .amll)
            XCTAssertNil(restored.configuration.sizePreset)
            XCTAssertFalse(restored.configuration.bold)
            XCTAssertEqual(restored.configuration.resolvedFontSize(width: 402, height: 874), 32)
            restored.configuration.translation.toggle()
        }
    }

    func testAMLLResponsivePresetSurvivesRelaunch() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.configuration.sizePreset = .small
        preferences.configuration.bold = false
        let restored = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(restored.configuration.sizePreset, .small)
        XCTAssertFalse(restored.configuration.bold)
    }

    func testCreditModesSelectTypesAndOnlyPreferredModesFallBack() {
        var document = LyricsDocument(candidate: .init(source: .apple, sourceID: "test", title: "Test", artists: []),
                                      lines: [], language: "", selectionReason: "", lyricAuthor: "Transcriber", songwriters: ["Composer"])
        typealias Mode = LyricsRenderConfiguration.Credits
        XCTAssertNil(Mode.hidden.content(in: document))
        XCTAssertEqual(Mode.lyricAuthor.content(in: document)?.names, ["Transcriber"])
        XCTAssertEqual(Mode.preferSongwriters.content(in: document)?.names, ["Composer"])
        document.songwriters = [" "]
        XCTAssertNil(Mode.songwriters.content(in: document))
        XCTAssertEqual(Mode.preferSongwriters.content(in: document)?.kind, .lyricAuthor)
        document.lyricAuthor = nil
        XCTAssertNil(Mode.preferLyricAuthor.content(in: document))
        document.songwriters = ["Composer"]
        XCTAssertEqual(Mode.preferLyricAuthor.content(in: document)?.kind, .songwriters)
    }

    func testReducedMotionDoesNotAlterUserBackgroundBlur() {
        let regular = RenderQualityPolicy.resolve(maximumFPS: 120, reduceMotion: false)
        XCTAssertEqual(regular.frameRate, 120)
        let reduced = RenderQualityPolicy.resolve(maximumFPS: 120, reduceMotion: true)
        XCTAssertFalse(reduced.emphasis)
        XCTAssertFalse(reduced.blur)
        var configuration = LyricsRenderConfiguration()
        configuration.backgroundBlur = 75
        XCTAssertEqual(configuration.validated().backgroundBlur, 75)
    }

    func testAMLLResponsiveFontPresetsUseViewportFormula() {
        XCTAssertEqual(AMLLLyricSizePreset.tiny.pointSize(width: 402, height: 700), 17.5, accuracy: 0.000_001)
        XCTAssertEqual(AMLLLyricSizePreset.medium.pointSize(width: 402, height: 700), 35, accuracy: 0.000_001)
        XCTAssertEqual(AMLLLyricSizePreset.huge.pointSize(width: 1024, height: 768), 40.96, accuracy: 0.000_001)
        var configuration = LyricsRenderConfiguration()
        configuration.sizePreset = .large
        XCTAssertEqual(configuration.resolvedFontSize(width: 402, height: 700), 42, accuracy: 0.000_001)
    }

    func testLegacyRubyIsRenderedOnlyAsRubyAndNotDuplicatedAsRomanization() {
        let line = LyricLine(
            id: "ruby",
            text: "漢",
            start: 0,
            end: 2,
            words: [.init(text: "漢", start: 0, end: 2, ruby: "かん")],
            precision: .word
        )
        var configuration = LyricsRenderConfiguration()
        configuration.translation = false
        XCTAssertTrue(configuration.auxiliaryText(for: line).isEmpty)
    }
}
