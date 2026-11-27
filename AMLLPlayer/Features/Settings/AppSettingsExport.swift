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
    let music: Music
    let lyrics: LyricsSettings
    let appearance: Appearance
    let immersiveArtwork: ImmersiveArtworkDebugConfiguration
    let showsImmersiveArtworkDebugButton: Bool
    let trackLyrics: [String: LyricsSelection]
    let pronunciationOverrides: [String: [String: String]]

    @MainActor
    init(model: AppModel, artwork: ImmersiveArtworkDebugStore,
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
