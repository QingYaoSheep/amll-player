import SwiftUI
import UniformTypeIdentifiers

struct AppSettingsExport: Codable {
    struct Appearance: Codable {
        let profile: LyricsPresentationProfile
        let current: LyricsRenderConfiguration
        let savedCustom: LyricsRenderConfiguration?
    }

    struct Music: Codable {
        let source: MusicServiceID
        let spotifyClientID: String?
        let netEaseQuality: NetEaseQuality
        let netEaseShuffle: Bool
        let netEaseRepeat: MusicRepeatMode
        let netEaseRoomSystemAlerts: Bool?
    }

    let version: Int
    let hapticsEnabled: Bool?
    let autoDesktopLyrics: Bool?
    let desktopLyrics: DesktopLyricsSettings?
    let lockScreenLyrics: Bool?
    let lockScreenLyricsTranslation: Bool?
    let lockScreenLyricsRomanization: Bool?
    let lockScreenLyricsKeepAlive: Bool?
    let music: Music
    let lyrics: LyricsSettings
    let appearance: Appearance
    let immersiveArtwork: ImmersiveArtworkDebugConfiguration?
    let showsImmersiveArtworkDebugButton: Bool?
    let trackLyrics: [String: LyricsSelection]
    let pronunciationOverrides: [String: [String: String]]

    @MainActor
    init(model: AppModel,
         artwork: ImmersiveArtworkDebugStore = .shared,
         pronunciationOverrides: [String: [String: String]], haptics: AppHaptics = .shared) throws {
        let configuration = model.renderPreferences.configuration.validated()
        let playback = model.netEasePlayback
        let modes = playback.savedPlaybackModes
        version = 1
        hapticsEnabled = haptics.isEnabled
        autoDesktopLyrics = UserDefaults.standard.bool(forKey: DesktopLyricsController.autoStartKey)
        desktopLyrics = model.desktopLyricsPreferences.settings
        lockScreenLyrics = model.lockScreenLyricsEnabled
        lockScreenLyricsTranslation = model.lockScreenLyricsShowsTranslation
        lockScreenLyricsRomanization = model.lockScreenLyricsShowsRomanization
        lockScreenLyricsKeepAlive = model.lockScreenLyricsKeepAliveEnabled
        music = Music(source: model.selectedMusicService,
                      spotifyClientID: model.environment.configuration.spotifyClientID.flatMap(SpotifyClientIDStore.normalized),
                      netEaseQuality: playback.quality, netEaseShuffle: modes.shuffle, netEaseRepeat: modes.repeatMode,
                      netEaseRoomSystemAlerts: playback.roomActivity.savedSystemAlertsPreference)
        lyrics = model.lyrics.settings.validated()
        appearance = Appearance(profile: model.renderPreferences.profile, current: configuration,
                                savedCustom: model.renderPreferences.migratedCustomConfiguration?.validated())
        immersiveArtwork = artwork.exportConfiguration(backgroundDimming: configuration.backgroundDimming ?? 0.16)
        showsImmersiveArtworkDebugButton = artwork.showsButton
        trackLyrics = try model.lyrics.savedSelections()
        self.pronunciationOverrides = pronunciationOverrides
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    @MainActor
    func apply(to model: AppModel,
               artwork: ImmersiveArtworkDebugStore = .shared,
               haptics: AppHaptics = .shared) async throws {
        guard version == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let hapticsEnabled {
            haptics.isEnabled = hapticsEnabled
        }
        if let autoDesktopLyrics {
            UserDefaults.standard.set(autoDesktopLyrics, forKey: DesktopLyricsController.autoStartKey)
        }
        if let desktopLyrics {
            model.desktopLyricsPreferences.settings = desktopLyrics
        }
        if let lockScreenLyrics {
            model.lockScreenLyricsEnabled = lockScreenLyrics
        }
        if let lockScreenLyricsTranslation {
            model.lockScreenLyricsShowsTranslation = lockScreenLyricsTranslation
        }
        if let lockScreenLyricsRomanization {
            model.lockScreenLyricsShowsRomanization = lockScreenLyricsRomanization
        }
        if let lockScreenLyricsKeepAlive, AMLLBuildCapabilities.supportsSilentBackgroundKeepAlive {
            model.lockScreenLyricsKeepAliveEnabled = lockScreenLyricsKeepAlive
        }
        model.selectMusicService(music.source)
        if let clientID = music.spotifyClientID.flatMap(SpotifyClientIDStore.normalized),
           clientID != model.environment.configuration.spotifyClientID {
            try model.configureSpotify(clientID: clientID)
        }
        model.netEasePlayback.quality = music.netEaseQuality
        model.netEasePlayback.restorePlaybackModes(shuffle: music.netEaseShuffle, repeatMode: music.netEaseRepeat)
        model.lyrics.updateSettings(lyrics)
        model.renderPreferences.restore(profile: appearance.profile,
                                        current: appearance.current,
                                        savedCustom: appearance.savedCustom)
        if let immersiveArtwork {
            artwork.configuration = immersiveArtwork.enablingReflection()
        }
        if let showsImmersiveArtworkDebugButton {
            artwork.showsButton = showsImmersiveArtworkDebugButton
        }
        try model.lyrics.restoreSelections(trackLyrics)
        let overridesData = try JSONEncoder().encode(pronunciationOverrides)
        try await LyricsRomanizationEngine.shared.importOverrides(overridesData)
    }
}

struct AppSettingsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
