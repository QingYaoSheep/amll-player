@testable import AMLLPlayer
import XCTest

@MainActor final class AppSettingsExportTests: XCTestCase {
    func testExportReadsCurrentPreferencesAndOnlyUserSelectedLyrics() throws {
        let suite = "settings-export-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fixture-token", forKey: "unrelatedAccountData")
        let selected = MusicSourcePreferences(defaults: defaults)
        selected.selected = .netease
        let appearances = LyricsRenderPreferences(defaults: defaults)
        appearances.activate(.custom)
        appearances.configuration.fontSize = 43
        let settingsStore = LyricsSettingsStore(defaults: defaults)
        var settings = LyricsSettings()
        settings.globalDelay = 0.65
        try settingsStore.save(settings)
        let cache = try SwiftDataLyricsCache(inMemory: true)
        let candidate = LyricCandidate(source: .netease, sourceID: "123", title: "Fixture", artists: ["Artist"])
        try cache.saveSelection(.init(candidate: candidate, offset: -1.2), for: "netease:123")
        let lyrics = LyricsCoordinator(providers: [], cache: cache, settingsStore: settingsStore)
        let desktop = DesktopLyricsPreferences(defaults: defaults)
        desktop.settings.aspect = .tall
        desktop.settings.plusLighter = false
        let model = AppModel(environment: .make(configuration: .preview), lyrics: lyrics,
                             renderPreferences: appearances, desktopLyricsPreferences: desktop, musicPreferences: selected)
        let overrides = ["ja": ["言葉": "ことば"]]

        defaults.set(false, forKey: AppHaptics.preferenceKey)
        let savedLockScreen = model.lockScreenLyricsEnabled
        let savedKeepAlive = model.lockScreenLyricsKeepAliveEnabled
        defer {
            model.lockScreenLyricsEnabled = savedLockScreen
            model.lockScreenLyricsKeepAliveEnabled = savedKeepAlive
        }
        model.lockScreenLyricsEnabled = true
        model.lockScreenLyricsKeepAliveEnabled = true
        let snapshot = try AppSettingsExport(model: model, pronunciationOverrides: overrides,
                                             haptics: AppHaptics(defaults: defaults))
        let data = try snapshot.encoded()
        let decoded = try JSONDecoder().decode(AppSettingsExport.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.lockScreenLyrics, true)
        XCTAssertEqual(decoded.lockScreenLyricsKeepAlive, true)
        XCTAssertEqual(decoded.desktopLyrics?.aspect, .tall)
        XCTAssertEqual(decoded.desktopLyrics?.plusLighter, false)
        XCTAssertEqual(decoded.hapticsEnabled, false)
        XCTAssertEqual(decoded.music.source, .netease)
        XCTAssertEqual(decoded.music.netEaseQuality, model.netEasePlayback.quality)
        XCTAssertEqual(decoded.lyrics.globalDelay, 0.65)
        XCTAssertEqual(decoded.appearance.current.fontSize, 43)
        XCTAssertEqual(decoded.appearance.savedCustom?.fontSize, 43)
        XCTAssertEqual(decoded.trackLyrics["netease:123"], .init(candidate: candidate, offset: -1.2))
        XCTAssertEqual(decoded.pronunciationOverrides, overrides)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-token"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "hapticsEnabled")
        legacy.removeValue(forKey: "desktopLyrics")
        legacy.removeValue(forKey: "lockScreenLyricsKeepAlive")
        legacy["immersiveArtwork"] = ["blurRadius": 10]
        legacy["showsImmersiveArtworkDebugButton"] = false
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacySettings = try JSONDecoder().decode(AppSettingsExport.self, from: legacyData)
        XCTAssertNil(legacySettings.hapticsEnabled)
        XCTAssertNil(legacySettings.desktopLyrics)
        XCTAssertNil(legacySettings.lockScreenLyricsKeepAlive)
    }

    func testApplyRestoresPreferencesSelectionsAndPlaybackModes() async throws {
        let suite = "settings-import-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let selected = MusicSourcePreferences(defaults: defaults)
        selected.selected = .spotify
        let appearances = LyricsRenderPreferences(defaults: defaults)
        let settingsStore = LyricsSettingsStore(defaults: defaults)
        let cache = try SwiftDataLyricsCache(inMemory: true)
        let lyrics = LyricsCoordinator(providers: [], cache: cache, settingsStore: settingsStore)
        let desktop = DesktopLyricsPreferences(defaults: defaults)
        let model = AppModel(environment: .make(configuration: .preview), lyrics: lyrics,
                             renderPreferences: appearances, desktopLyricsPreferences: desktop, musicPreferences: selected)
        let haptics = AppHaptics(defaults: defaults)

        var renderConfig = LyricsRenderConfiguration()
        renderConfig.fontSize = 44
        renderConfig.bold = false
        var lyricSettings = LyricsSettings()
        lyricSettings.globalDelay = 1.25
        var desktopSettings = DesktopLyricsSettings()
        desktopSettings.aspect = .tall
        desktopSettings.plusLighter = false

        let candidate = LyricCandidate(source: .netease, sourceID: "456", title: "Imported Track", artists: ["Tester"])
        let exported = AppSettingsExport(
            version: 1,
            exportedAt: Date(),
            music: .init(source: .netease, spotifyClientID: nil, netEaseQuality: .lossless, netEaseShuffle: true, netEaseRepeat: .one),
            lyrics: lyricSettings,
            appearance: .init(profile: .custom, current: renderConfig, savedCustom: renderConfig),
            trackLyrics: ["netease:456": .init(candidate: candidate, offset: -0.75)],
            pronunciationOverrides: [:],
            lockScreenLyrics: true,
            lockScreenLyricsTranslation: false,
            lockScreenLyricsRomanization: true,
            lockScreenLyricsKeepAlive: false,
            autoDesktopLyrics: nil,
            desktopLyrics: desktopSettings,
            hapticsEnabled: false
        )

        let savedLockScreen = model.lockScreenLyricsEnabled
        let savedTranslation = model.lockScreenLyricsShowsTranslation
        let savedRomanization = model.lockScreenLyricsShowsRomanization
        let savedKeepAlive = model.lockScreenLyricsKeepAliveEnabled
        defer {
            model.lockScreenLyricsEnabled = savedLockScreen
            model.lockScreenLyricsShowsTranslation = savedTranslation
            model.lockScreenLyricsShowsRomanization = savedRomanization
            model.lockScreenLyricsKeepAliveEnabled = savedKeepAlive
        }

        try await exported.apply(to: model, haptics: haptics)

        XCTAssertFalse(haptics.isEnabled)
        XCTAssertEqual(model.selectedMusicService, .netease)
        XCTAssertEqual(model.netEasePlayback.quality, .lossless)
        XCTAssertEqual(model.lyrics.settings.globalDelay, 1.25)
        XCTAssertEqual(model.renderPreferences.profile, .custom)
        XCTAssertEqual(model.renderPreferences.configuration.fontSize, 44)
        XCTAssertFalse(model.renderPreferences.configuration.bold)
        XCTAssertEqual(model.desktopLyricsPreferences.settings.aspect, .tall)
        XCTAssertEqual(model.desktopLyricsPreferences.settings.plusLighter, false)
        XCTAssertEqual(try cache.selection(for: "netease:456"), .init(candidate: candidate, offset: -0.75))

        var invalid = exported
        invalid.version = 999
        do {
            try await invalid.apply(to: model, haptics: haptics)
            XCTFail("Expected unsupported settings version to throw")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadCorruptFile)
        }
    }
}
