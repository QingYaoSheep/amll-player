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
}
