@testable import AMLLPlayer
import XCTest

@MainActor
final class AppleMusicIntegrationTests: XCTestCase {
    func testPlaylistDuplicatesKeepOriginalPositionsIncludingUnsupportedEntries() throws {
        let data = Data(#"{"data":[{"id":"42","type":"songs","attributes":{"name":"A","playParams":{"id":"42"}}},{"id":"x","type":"unknown"},{"id":"42","type":"songs","attributes":{"name":"A","playParams":{"id":"42"}}}],"next":"/v1/catalog/us/playlists/pl.1/tracks?offset=28"}"#.utf8)
        let resource = MusicResourceID(service: .appleMusic, kind: .playlist, scope: .catalog, rawValue: "pl.1")
        let url = try XCTUnwrap(URL(string: "https://api.music.apple.com/v1/catalog/us/playlists/pl.1/tracks?offset=25"))
        let page = try AppleMusicCatalogDecoder.page(data, query: .resourceChildren(resource), url: url)
        XCTAssertEqual(page.items.map(\.position), [25, 27])
        XCTAssertNotEqual(page.items[0].id, page.items[1].id)
        XCTAssertEqual(page.next?.host, "api.music.apple.com")
    }

    func testCatalogAndLibraryIdentitiesStayDistinctWithoutChangingSpotifyCacheKeys() throws {
        func item(_ scope: MusicResourceScope) -> PlaybackItem {
            .init(id: "42", uri: "applemusic:\(scope.rawValue):track:42", title: "Same", artists: ["Singer"],
                  albumTitle: nil, artworkURL: nil, duration: 180, isEpisode: false, isAdvertisement: false,
                  service: .appleMusic, resourceScope: scope)
        }
        XCTAssertEqual(TrackIdentity(item(.catalog))?.spotifyID, "appleMusic:catalog:42")
        XCTAssertEqual(TrackIdentity(item(.library))?.spotifyID, "appleMusic:library:42")
        XCTAssertEqual(MusicTrackIdentity.key(service: .spotify, scope: .catalog, id: "old-key"), "old-key")
        let legacy = Data(#"{"spotifyID":"old-key","title":"Song","artists":["Artist"],"album":"Album","duration":10}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(TrackIdentity.self, from: legacy).spotifyID, "old-key")
    }

    func testLibraryImportDoesNotInventCatalogIDAndReadonlyPlaylistIsNotEditable() throws {
        let raw: [String: Any] = ["id": "i.local", "type": "library-songs", "attributes": ["name": "Local", "artistName": "Owner", "playParams": ["id": "i.local"]]]
        let song = try XCTUnwrap(AppleMusicCatalogDecoder.item(raw))
        XCTAssertEqual(song.scope, .library)
        XCTAssertNil(song.catalogID)
        XCTAssertTrue(song.canPlay)
        let playlist = try XCTUnwrap(AppleMusicCatalogDecoder.item([
            "id": "p.1", "type": "library-playlists", "attributes": ["name": "Personal", "canEdit": true],
        ]))
        XCTAssertTrue(playlist.libraryWritable)
        XCTAssertFalse(playlist.editablePlaylist)
    }

    func testMusicVideoNeverStartsAnIndependentPlayerAndFavoritesComeFromService() throws {
        let video = try XCTUnwrap(AppleMusicCatalogDecoder.item([
            "id": "123", "type": "music-videos", "attributes": ["name": "Video", "playParams": ["id": "123"], "inFavorites": true],
        ]))
        XCTAssertFalse(video.canPlay)
        XCTAssertEqual(video.inFavorites, true)
    }

    func testPaginationRejectsCredentialRedirectsAndTraversal() throws {
        let good = try XCTUnwrap(URL(string: "https://api.music.apple.com/v1/catalog/us/songs"))
        for value in ["https://example.com/v1/songs", "http://api.music.apple.com/v1/songs", "https://a:b@api.music.apple.com/v1/songs", "https://api.music.apple.com/v1/songs#token", "https://api.music.apple.com/other"] {
            XCTAssertThrowsError(try AppleMusicAPI.next(value, from: good))
        }
        XCTAssertThrowsError(try AppleMusicAPI.resourcePath(.init(service: .appleMusic, kind: .track, scope: .catalog, rawValue: "../me"), storefront: "us"))
        XCTAssertThrowsError(try AppleMusicAPI.resourcePath(.init(service: .spotify, kind: .track, scope: .catalog, rawValue: "123"), storefront: "us"))
    }

    func testSearchContainersAndChartsDecodeTheirOwnPagination() throws {
        let url = try XCTUnwrap(URL(string: "https://api.music.apple.com/v1/catalog/us/search"))
        let data = Data(#"{"results":{"library-songs":{"data":[{"id":"i.1","type":"library-songs","attributes":{"name":"Local"}}],"next":"/v1/me/library/search?offset=25"},"songs":[{"data":[{"id":"2","type":"songs","attributes":{"name":"Chart"}}]}]}}"#.utf8)
        XCTAssertEqual(try AppleMusicCatalogDecoder.page(data, query: .librarySearch("x", .track), url: url).items.first?.item.name, "Local")
        XCTAssertEqual(try AppleMusicCatalogDecoder.page(data, query: .collection(.charts), url: url).items.first?.item.name, "Chart")
    }

    func testUpgradeDefaultsSpotifyAndSourceSwitchIssuesNoPlaybackCommands() async {
        let defaults = UserDefaults(suiteName: "music-test-" + UUID().uuidString)!
        let preferences = MusicSourcePreferences(defaults: defaults)
        let spotify = MusicTestPlayback()
        let apple = MusicTestPlayback()
        let session = MusicTestSession()
        let model = AppModel(environment: .init(configuration: .preview, diagnostics: DiagnosticsStore(),
                                                spotifySession: MusicTestSpotifySession(), spotifyPlayback: spotify),
                             catalogProvider: MusicTestCatalog(service: .spotify), appleSession: session, applePlayback: apple,
                             appleCatalog: MusicTestCatalog(service: .appleMusic), musicPreferences: preferences)
        XCTAssertEqual(model.selectedMusicService, .spotify)
        model.selectMusicService(.appleMusic)
        await Task.yield()
        XCTAssertEqual(preferences.selected, .appleMusic)
        XCTAssertEqual(spotify.commands, [])
        XCTAssertEqual(apple.commands, [])
        model.selectMusicService(.spotify)
        XCTAssertEqual(apple.commands, [])
        XCTAssertEqual(spotify.commands, [])
    }

    func testApplePlaybackSnapshotUpdatesLyricsSeekRevisionAndIgnoresSpotifySnapshot() async {
        let defaults = UserDefaults(suiteName: "music-test-" + UUID().uuidString)!
        let preferences = MusicSourcePreferences(defaults: defaults)
        preferences.selected = .appleMusic
        let apple = MusicTestPlayback()
        let spotify = MusicTestPlayback()
        let model = AppModel(environment: .init(configuration: .preview, diagnostics: DiagnosticsStore(),
                                                spotifySession: MusicTestSpotifySession(), spotifyPlayback: spotify),
                             catalogProvider: MusicTestCatalog(service: .spotify), appleSession: MusicTestSession(), applePlayback: apple,
                             appleCatalog: MusicTestCatalog(service: .appleMusic), musicPreferences: preferences)
        model.prepare()
        let item = PlaybackItem(id: "42", uri: "applemusic:catalog:track:42", title: "Song", artists: ["Artist"],
                                albumTitle: nil, artworkURL: nil, duration: 100, isEpisode: false, isAdvertisement: false,
                                isrc: "TEST", service: .appleMusic)
        let first = PlaybackSnapshot(item: item, isPlaying: false, position: 60, duration: 100, device: nil,
                                     restrictions: .unrestricted, source: .musicKit, sampledAtUptime: 10)
        apple.continuation.yield(first)
        for _ in 0 ..< 100 {
            await Task.yield(); if model.playbackSnapshot != nil {
                break
            }
        }
        XCTAssertEqual(model.playbackSnapshot?.position, 60)
        var seek = first
        seek = PlaybackSnapshot(item: item, isPlaying: false, position: 10, duration: 100, device: nil,
                                restrictions: .unrestricted, source: .musicKit, sampledAtUptime: 11, positionRevision: 1)
        let revision = model.lyricsSeekRevision
        apple.continuation.yield(seek)
        for _ in 0 ..< 100 {
            await Task.yield(); if model.lyricsSeekRevision != revision {
                break
            }
        }
        XCTAssertEqual(model.lyricsSeekPosition, 10)
        XCTAssertEqual(model.lyricsSeekRevision, revision + 1)
        spotify.continuation.yield(.empty(source: .webAPI, sampledAtUptime: 12))
        await Task.yield()
        XCTAssertEqual(model.playbackSnapshot?.item?.service, .appleMusic)
        model.disconnectAppleMusic()
        XCTAssertNil(model.playbackSnapshot)
        XCTAssertTrue(apple.commands.isEmpty)
    }

    func testInvalidClockCannotAdvanceLyrics() {
        let invalid = PlaybackSnapshot(item: nil, isPlaying: true, position: .nan, duration: 100,
                                       device: nil, restrictions: .unrestricted, source: .musicKit, sampledAtUptime: 0)
        XCTAssertEqual(PlayerClock(anchor: invalid).position(at: 10), 0)
    }
}

@MainActor
private final class MusicTestSession: MusicSessionProviding {
    var currentState = MusicConnectionState(connected: true, authorization: .authorized, storefront: "us",
                                            capabilities: .init(canBrowse: true, canPlayCatalog: true))
    var connectionStates: AsyncStream<MusicConnectionState> {
        AsyncStream { $0.yield(currentState); $0.finish() }
    }

    func connect() async {}
    func refresh() async {}
    func disconnect() {
        currentState.connected = false
    }
}

@MainActor
private final class MusicTestSpotifySession: SpotifySessionProviding {
    var currentState: SpotifySessionState = .authenticated(expiresAt: .distantFuture)
    var sessionStates: AsyncStream<SpotifySessionState> {
        AsyncStream { $0.yield(currentState); $0.finish() }
    }

    var spotifyAppInstalled: Bool {
        false
    }

    func authorize() throws {}
    func authorizeInBrowser() async throws {}
    func refreshIfNeeded() async throws {}
    func validAccessToken() async throws -> String {
        "fixture"
    }

    func handleRedirectURL(_: URL) -> Bool {
        false
    }

    func logout() {}
}

@MainActor
private final class MusicTestPlayback: SpotifyPlaybackProviding {
    var appRemoteState: SpotifyAppRemoteState {
        .disconnected
    }

    let playbackSnapshots: AsyncStream<PlaybackSnapshot>
    let continuation: AsyncStream<PlaybackSnapshot>.Continuation
    var commands: [String] = []
    init() {
        let stream = AsyncStream<PlaybackSnapshot>.makeStream()
        playbackSnapshots = stream.stream; continuation = stream.continuation
    }

    func start() {}
    func stop() {}
    func enterForeground() {}
    func enterBackground() {}
    func refresh() async throws {}
    func play() async throws {
        commands.append("play")
    }

    func pause() async throws {
        commands.append("pause")
    }

    func seek(to _: TimeInterval) async throws {
        commands.append("seek")
    }

    func skipNext() async throws {
        commands.append("next")
    }

    func skipPrevious() async throws {
        commands.append("previous")
    }

    func play(uri: String, on _: String?) async throws {
        commands.append(uri)
    }

    func setVolume(percent _: Int, on _: String?) async throws {}
    func devices() async throws -> [PlaybackDevice] {
        []
    }

    func transferPlayback(to _: String) async throws {}
}

@MainActor
private final class MusicTestCatalog: MusicCatalogProviding {
    let service: MusicServiceID
    init(service: MusicServiceID) {
        self.service = service
    }

    func profile() async throws -> MusicProfile {
        .init(accountID: "context", displayName: service.title)
    }

    func invalidate() {}
    func page(_: MusicCatalogQuery, next _: URL?) async throws -> MusicPage<MusicCatalogRow> {
        .init(items: [], next: nil, total: 0)
    }

    func detail(kind _: MusicCatalogKind, id _: String) async throws -> MusicCatalogDetail {
        throw MusicCatalogError.unavailable
    }
}
