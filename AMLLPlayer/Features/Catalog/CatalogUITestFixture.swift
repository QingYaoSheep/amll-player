#if DEBUG
import Foundation

/// Explicit opt-in, in-memory fixtures. Release builds have no mock account or launch bypass.
@MainActor
enum CatalogUITestFixture {
    static func makeModel(includeLyrics: Bool = false) -> AppModel {
        let lyrics = LyricsCoordinator(providers: includeLyrics ? [LyricsFixtureProvider()] : [], cache: MemoryLyricsCache(),
                                       settingsStore: LyricsSettingsStore(defaults: UserDefaults(suiteName: "lyrics-ui-" + UUID().uuidString)!))
        return AppModel(environment: AppEnvironment(
            configuration: .preview, diagnostics: DiagnosticsStore(),
            spotifySession: Session(), spotifyPlayback: Playback(includeLyrics: includeLyrics)
        ), catalogProvider: Provider(), lyrics: lyrics,
           renderPreferences: LyricsRenderPreferences(defaults: UserDefaults(suiteName: "render-ui-" + UUID().uuidString)!))
    }

    private static func item(_ id: String, kind: SpotifyCatalogKind = .track, name: String = "Test Song") -> SpotifyCatalogItem {
        SpotifyCatalogItem(spotifyID: id, kind: kind, name: name, subtitle: "Test Artist", artworkURL: nil, availability: .available)
    }

    private final class Provider: SpotifyCatalogProviding {
        func invalidate() {}
        func profile() async throws -> SpotifyProfile { SpotifyProfile(accountID: "fixture", displayName: "Test Listener") }
        func page(_ query: SpotifyCatalogQuery, next: URL?) async throws -> SpotifyPage<SpotifyCatalogRow> {
            let value: SpotifyCatalogItem
            switch query {
            case .collection(.playlists): value = CatalogUITestFixture.item("list1", kind: .playlist, name: "Test Playlist")
            case .collection(.savedAlbums), .artistAlbums: value = CatalogUITestFixture.item("album1", kind: .album, name: "Test Album")
            case .collection(.followedArtists): value = CatalogUITestFixture.item("artist1", kind: .artist, name: "Test Artist")
            case let .search(term, kind): value = CatalogUITestFixture.item("result1", kind: kind, name: term + " Result")
            default: value = CatalogUITestFixture.item("track1")
            }
            return SpotifyPage(items: [SpotifyCatalogRow(id: value.id, item: value, position: query.preservesPositions ? 0 : nil)], next: nil, total: 1)
        }
        func detail(kind: SpotifyCatalogKind, id: String) async throws -> SpotifyCatalogDetail {
            let name = kind == .playlist ? "Test Playlist" : kind == .album ? "Test Album" : kind == .artist ? "Test Artist" : "Test Song"
            let children: SpotifyCatalogQuery?
            switch kind {
            case .track, .playlist: children = nil
            case .album: children = .albumTracks(id)
            case .artist: children = .artistAlbums(id)
            }
            return SpotifyCatalogDetail(item: CatalogUITestFixture.item(id, kind: kind, name: name), children: children,
                                        availability: kind == .playlist ? .metadataOnly : .available)
        }
    }

    private final class Session: SpotifySessionProviding {
        var currentState: SpotifySessionState = .authenticated(expiresAt: .distantFuture)
        var sessionStates: AsyncStream<SpotifySessionState> { AsyncStream { $0.yield(currentState); $0.finish() } }
        var spotifyAppInstalled: Bool { false }
        func authorize() throws {}
        func authorizeInBrowser() async throws {}
        func refreshIfNeeded() async throws {}
        func validAccessToken() async throws -> String { throw SpotifyServiceError.notAuthorized }
        func handleRedirectURL(_ url: URL) -> Bool { false }
        func logout() { currentState = .signedOut }
    }

    private final class Playback: SpotifyPlaybackProviding {
        let includeLyrics: Bool
        init(includeLyrics: Bool) { self.includeLyrics = includeLyrics }
        var appRemoteState: SpotifyAppRemoteState { .disconnected }
        var playbackSnapshots: AsyncStream<PlaybackSnapshot> {
            AsyncStream {
                if includeLyrics {
                    let item = PlaybackItem(id: "fixture", uri: "spotify:track:fixture", title: "Fixture Song", artists: ["Fixture Artist"],
                        albumTitle: nil, artworkURL: nil, duration: 10, isEpisode: false, isAdvertisement: false, isrc: "FIXTURE")
                    $0.yield(PlaybackSnapshot(item: item, isPlaying: false, position: 1, duration: 10, device: nil,
                        restrictions: .unrestricted, source: .webAPI, sampledAtUptime: ProcessInfo.processInfo.systemUptime))
                }
                $0.finish()
            }
        }
        func start() {}
        func stop() {}
        func enterForeground() {}
        func enterBackground() {}
        func refresh() async throws {}
        func play() async throws {}
        func pause() async throws {}
        func seek(to position: TimeInterval) async throws {}
        func skipNext() async throws {}
        func skipPrevious() async throws {}
        func setVolume(percent: Int, on deviceID: String?) async throws {}
        func play(uri: String, on deviceID: String?) async throws {}
        func play(contextURI: String, position: Int, on deviceID: String?) async throws {}
        func devices() async throws -> [PlaybackDevice] { [] }
        func transferPlayback(to deviceID: String) async throws {}
    }

    private final class LyricsFixtureProvider: LyricsProvider {
        let source = LyricsSource.qq
        func search(track: TrackIdentity, query: String, settings: LyricsSettings) async throws -> [LyricCandidate] {
            [LyricCandidate(source: .qq, sourceID: query.isEmpty ? "auto" : "manual", title: query.isEmpty ? "Fixture Song" : "Correction Candidate", artists: ["Fixture Artist"], score: 99)]
        }
        func lyrics(candidate: LyricCandidate, settings: LyricsSettings) async throws -> LyricsPayload {
            LyricsPayload(format: .lrc, original: candidate.sourceID == "manual" ? "[00:01]Corrected fixture line" : "[00:01]Original fixture line")
        }
    }
}
#endif
