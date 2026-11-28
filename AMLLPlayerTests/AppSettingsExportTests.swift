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
        let artwork = ImmersiveArtworkDebugStore(defaults: defaults)
        artwork.showsButton = false
        artwork.configuration[.reflection].enabled = false
        let overrides = ["ja": ["言葉": "ことば"]]

        defaults.set(false, forKey: AppHaptics.preferenceKey)
        let savedLockScreen = model.lockScreenLyricsEnabled
        let savedKeepAlive = model.lockScreenLyricsKeepAliveEnabled
        let savedKeepScreenAwake = model.lyricsKeepScreenAwake
        defer {
            model.lockScreenLyricsEnabled = savedLockScreen
            model.lockScreenLyricsKeepAliveEnabled = savedKeepAlive
            model.lyricsKeepScreenAwake = savedKeepScreenAwake
        }
        model.lockScreenLyricsEnabled = true
        model.lockScreenLyricsKeepAliveEnabled = true
        model.lyricsKeepScreenAwake = true
        let snapshot = try AppSettingsExport(model: model, artwork: artwork, pronunciationOverrides: overrides,
                                             haptics: AppHaptics(defaults: defaults))
        let data = try snapshot.encoded()
        let decoded = try JSONDecoder().decode(AppSettingsExport.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.lockScreenLyrics, true)
        XCTAssertEqual(decoded.lockScreenLyricsKeepAlive, true)
        XCTAssertEqual(decoded.lyricsKeepScreenAwake, true)
        XCTAssertEqual(decoded.desktopLyrics?.aspect, .tall)
        XCTAssertEqual(decoded.desktopLyrics?.plusLighter, false)
        XCTAssertEqual(decoded.hapticsEnabled, false)
        XCTAssertEqual(decoded.music.source, .netease)
        XCTAssertEqual(decoded.music.netEaseQuality, model.netEasePlayback.quality)
        XCTAssertEqual(decoded.lyrics.globalDelay, 0.65)
        XCTAssertEqual(decoded.appearance.current.fontSize, 43)
        XCTAssertEqual(decoded.appearance.savedCustom?.fontSize, 43)
        XCTAssertEqual(decoded.immersiveArtwork?.validatedBlur, 10)
        XCTAssertEqual(decoded.immersiveArtwork?[.reflection].enabled, true)
        XCTAssertEqual(decoded.showsImmersiveArtworkDebugButton, false)
        XCTAssertEqual(decoded.trackLyrics["netease:123"], .init(candidate: candidate, offset: -1.2))
        XCTAssertEqual(decoded.pronunciationOverrides, overrides)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-token"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "hapticsEnabled")
        legacy.removeValue(forKey: "desktopLyrics")
        legacy.removeValue(forKey: "lockScreenLyricsKeepAlive")
        legacy.removeValue(forKey: "lyricsKeepScreenAwake")
        legacy.removeValue(forKey: "immersiveArtwork")
        legacy.removeValue(forKey: "showsImmersiveArtworkDebugButton")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacySettings = try JSONDecoder().decode(AppSettingsExport.self, from: legacyData)
        XCTAssertNil(legacySettings.hapticsEnabled)
        XCTAssertNil(legacySettings.desktopLyrics)
        XCTAssertNil(legacySettings.lockScreenLyricsKeepAlive)
        XCTAssertNil(legacySettings.lyricsKeepScreenAwake)
        XCTAssertNil(legacySettings.immersiveArtwork)
        XCTAssertNil(legacySettings.showsImmersiveArtworkDebugButton)
    }

    func testApplyRestoresPreferencesSelectionsAndPlaybackModes() async throws {
        let sourceSuite = "settings-export-src-" + UUID().uuidString
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }

        let targetSuite = "settings-import-dst-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        defer { defaults.removePersistentDomain(forName: targetSuite) }

        let sourceSelected = MusicSourcePreferences(defaults: sourceDefaults)
        sourceSelected.selected = .netease
        let sourceAppearances = LyricsRenderPreferences(defaults: sourceDefaults)
        sourceAppearances.activate(.custom)
        sourceAppearances.configuration.fontSize = 44
        sourceAppearances.configuration.bold = false
        let sourceSettingsStore = LyricsSettingsStore(defaults: sourceDefaults)
        var lyricSettings = LyricsSettings()
        lyricSettings.globalDelay = 1.25
        try sourceSettingsStore.save(lyricSettings)
        let sourceCache = try SwiftDataLyricsCache(inMemory: true)
        let candidate = LyricCandidate(source: .netease, sourceID: "456", title: "Imported Track", artists: ["Tester"])
        try sourceCache.saveSelection(.init(candidate: candidate, offset: -0.75), for: "netease:456")
        let sourceLyrics = LyricsCoordinator(providers: [], cache: sourceCache, settingsStore: sourceSettingsStore)
        let sourceDesktop = DesktopLyricsPreferences(defaults: sourceDefaults)
        sourceDesktop.settings.aspect = .tall
        sourceDesktop.settings.plusLighter = false
        let sourceModel = AppModel(environment: .make(configuration: .preview), lyrics: sourceLyrics,
                                   renderPreferences: sourceAppearances, desktopLyricsPreferences: sourceDesktop,
                                   musicPreferences: sourceSelected)
        sourceDefaults.set(false, forKey: AppHaptics.preferenceKey)
        let sourceHaptics = AppHaptics(defaults: sourceDefaults)

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

        let savedSourceQuality = sourceModel.netEasePlayback.quality
        let savedTargetQuality = model.netEasePlayback.quality
        let savedLockScreen = model.lockScreenLyricsEnabled
        let savedTranslation = model.lockScreenLyricsShowsTranslation
        let savedRomanization = model.lockScreenLyricsShowsRomanization
        let savedKeepAlive = model.lockScreenLyricsKeepAliveEnabled
        let savedKeepScreenAwake = model.lyricsKeepScreenAwake
        defer {
            sourceModel.netEasePlayback.quality = savedSourceQuality
            model.netEasePlayback.quality = savedTargetQuality
            model.lockScreenLyricsEnabled = savedLockScreen
            model.lockScreenLyricsShowsTranslation = savedTranslation
            model.lockScreenLyricsShowsRomanization = savedRomanization
            model.lockScreenLyricsKeepAliveEnabled = savedKeepAlive
            model.lyricsKeepScreenAwake = savedKeepScreenAwake
        }

        sourceModel.lockScreenLyricsEnabled = true
        sourceModel.lockScreenLyricsShowsTranslation = false
        sourceModel.lockScreenLyricsShowsRomanization = true
        sourceModel.lockScreenLyricsKeepAliveEnabled = false
        sourceModel.lyricsKeepScreenAwake = true
        sourceModel.netEasePlayback.quality = .lossless
        sourceModel.netEasePlayback.restorePlaybackModes(shuffle: true, repeatMode: .one)
        let sourceArtwork = ImmersiveArtworkDebugStore(defaults: sourceDefaults)
        sourceArtwork.showsButton = false
        sourceArtwork.configuration.blurRadius = 28
        sourceArtwork.configuration.topFeatherLength = 42
        let targetArtwork = ImmersiveArtworkDebugStore(defaults: defaults)

        let data = try AppSettingsExport(
            model: sourceModel,
            artwork: sourceArtwork,
            pronunciationOverrides: [:],
            haptics: sourceHaptics
        ).encoded()
        let exported = try JSONDecoder().decode(AppSettingsExport.self, from: data)

        try await exported.apply(to: model, artwork: targetArtwork, haptics: haptics)

        XCTAssertFalse(targetArtwork.showsButton)
        XCTAssertEqual(targetArtwork.configuration.validatedBlur, 28)
        XCTAssertEqual(targetArtwork.configuration.validatedTopFeatherLength, 42)
        XCTAssertFalse(haptics.isEnabled)
        XCTAssertTrue(model.lyricsKeepScreenAwake)
        XCTAssertEqual(model.selectedMusicService, .netease)
        XCTAssertEqual(model.netEasePlayback.quality, .lossless)
        XCTAssertEqual(model.netEasePlayback.savedPlaybackModes.shuffle, true)
        XCTAssertEqual(model.netEasePlayback.savedPlaybackModes.repeatMode, .one)
        XCTAssertEqual(model.lyrics.settings.globalDelay, 1.25)
        XCTAssertEqual(model.renderPreferences.profile, .custom)
        XCTAssertEqual(model.renderPreferences.configuration.fontSize, 44)
        XCTAssertFalse(model.renderPreferences.configuration.bold)
        XCTAssertEqual(model.desktopLyricsPreferences.settings.aspect, .tall)
        XCTAssertEqual(model.desktopLyricsPreferences.settings.plusLighter, false)
        XCTAssertEqual(try cache.selection(for: "netease:456"), .init(candidate: candidate, offset: -0.75))

        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw["version"] = 999
        let invalidData = try JSONSerialization.data(withJSONObject: raw)
        let invalid = try JSONDecoder().decode(AppSettingsExport.self, from: invalidData)
        do {
            try await invalid.apply(to: model, haptics: haptics)
            XCTFail("Expected unsupported settings version to throw")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadCorruptFile)
        }
    }
}
