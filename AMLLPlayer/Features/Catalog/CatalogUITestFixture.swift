#if DEBUG
import Foundation

/// Explicit opt-in, in-memory fixtures. Release builds have no mock account or launch bypass.
@MainActor
enum CatalogUITestFixture {
    static func makeModel() -> AppModel {
        AppModel(environment: AppEnvironment(
            configuration: .preview, diagnostics: DiagnosticsStore(),
            spotifySession: Session(), spotifyPlayback: Playback()
        ), catalogProvider: Provider())
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
        var appRemoteState: SpotifyAppRemoteState { .disconnected }
        var playbackSnapshots: AsyncStream<PlaybackSnapshot> { AsyncStream { $0.finish() } }
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
}
#endif
