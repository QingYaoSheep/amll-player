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
                             catalogProvider: MusicTestCatalog(service: .spotify), lyrics: .init(providers: [], cache: MemoryLyricsCache()), appleSession: session, applePlayback: apple,
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
                             catalogProvider: MusicTestCatalog(service: .spotify), lyrics: .init(providers: [], cache: MemoryLyricsCache()), appleSession: MusicTestSession(), applePlayback: apple,
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

    func testOlderAuthorizationRefreshCannotRestoreRevokedConnection() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "appleMusic.connected.v1")
        let api = MusicTestAPI(), account = MusicTestAccount()
        let session = AppleMusicSession(api: api, defaults: defaults, account: account)
        let first = Task { await session.refresh() }
        await waitUntil { api.pending.count == 1 }
        account.authorization = .denied
        await session.refresh()
        api.pending[0].resume(returning: Data(#"{"data":[{"id":"us"}]}"#.utf8))
        await first.value
        XCTAssertFalse(session.currentState.connected)
        XCTAssertEqual(session.currentState.authorization, .denied)
        XCTAssertFalse(session.currentState.capabilities.canPlayCatalog)
    }

    func testOldRefreshFailureCannotOverrideNewSuccessfulCheck() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "appleMusic.connected.v1")
        let api = MusicTestAPI()
        let session = AppleMusicSession(api: api, defaults: defaults, account: MusicTestAccount())
        let old = Task { await session.refresh() }
        await waitUntil { api.pending.count == 1 }
        let new = Task { await session.refresh() }
        await waitUntil { api.pending.count == 2 }
        api.pending[1].resume(returning: Data(#"{"data":[{"id":"us"}]}"#.utf8))
        await new.value
        api.pending[0].resume(throwing: MusicCatalogError.offline)
        await old.value
        XCTAssertTrue(session.currentState.connected)
        XCTAssertNil(session.currentState.error)
    }

    func testCancelledPlaylistLoadCannotUnlockOrOverwriteReplacementLoad() async {
        let state = MusicPlaylistEditingState(), catalog = MusicTestCatalog(service: .appleMusic)
        catalog.deferPages = true
        let resource = MusicResourceID(service: .appleMusic, kind: .playlist, scope: .library, rawValue: "p.1")
        let old = Task { await state.load(resource: resource, provider: catalog) }
        await waitUntil { catalog.pendingPages.count == 1 }
        state.cancel()
        let new = Task { await state.load(resource: resource, provider: catalog) }
        await waitUntil { catalog.pendingPages.count == 2 }
        catalog.pendingPages[0].resume(returning: .init(items: [], next: nil, total: 0))
        await old.value
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.isLoaded) // Saving a replacement remains forbidden.
        let item = MusicCatalogItem(spotifyID: "42", kind: .track, name: "Keep", subtitle: "", artworkURL: nil,
                                    availability: .available, service: .appleMusic)
        catalog.pendingPages[1].resume(returning: .init(items: [.init(id: "p.1:0", item: item, position: 0)], next: nil, total: 1))
        await new.value
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.isLoaded)
        XCTAssertEqual(state.entries.map(\.item.name), ["Keep"])
    }

    func testSubscriptionObservationSurvivesOfflineRefreshAndRecovers() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "appleMusic.connected.v1")
        let api = MusicTestAPI(), account = MusicTestAccount()
        let session = AppleMusicSession(api: api, defaults: defaults, account: account)
        let initial = Task { await session.refresh() }
        await waitUntil { api.pending.count == 1 }
        api.pending[0].resume(returning: Data(#"{"data":[{"id":"us"}]}"#.utf8))
        await initial.value
        let offline = Task { await session.refresh() }
        await waitUntil { api.pending.count == 2 }
        api.pending[1].resume(throwing: MusicCatalogError.offline)
        await offline.value
        account.updates.yield(.init(canBrowse: true))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let recovery = Task { await session.refresh() }
        await waitUntil { api.pending.count == 3 }
        api.pending[2].resume(returning: Data(#"{"data":[{"id":"us"}]}"#.utf8))
        await recovery.value
        XCTAssertTrue(session.currentState.capabilities.canPlayCatalog)
        account.updates.yield(.init(canBrowse: true, canPlayCatalog: false, canModifyLibrary: false))
        await waitUntil { !session.currentState.capabilities.canPlayCatalog }
        XCTAssertFalse(session.currentState.capabilities.canModifyLibrary)
        session.disconnect()
    }

    func testCreatedPlaylistRegistrySurvivesRestartAndDisconnectWithoutGrantingOtherPlaylistsAccess() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let session = AppleMusicSession(api: MusicTestAPI(), defaults: defaults, account: MusicTestAccount())
        let first = AppleMusicCatalog(session: session, defaults: defaults)
        first.registerCreatedPlaylist("p.created")
        session.disconnect()
        let restored = AppleMusicCatalog(session: session, defaults: defaults)
        XCTAssertTrue(restored.isCreatedPlaylist("p.created"))
        XCTAssertFalse(restored.isCreatedPlaylist("p.personal"))
        let raw: [String: Any] = ["id": "p.personal", "type": "library-playlists", "attributes": ["name": "Other", "canEdit": true]]
        XCTAssertFalse(try XCTUnwrap(AppleMusicCatalogDecoder.item(raw, editableIDs: ["p.created"])).editablePlaylist)
    }

    func testLateDeviceResponseDoesNotPolluteNewMusicSource() async throws {
        for fails in [false, true] {
            let spotify = MusicTestPlayback(), apple = MusicTestPlayback()
            spotify.deferDevices = true
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let model = AppModel(environment: .init(configuration: .preview, diagnostics: DiagnosticsStore(),
                                                    spotifySession: MusicTestSpotifySession(), spotifyPlayback: spotify),
                                 catalogProvider: MusicTestCatalog(service: .spotify), lyrics: .init(providers: [], cache: MemoryLyricsCache()),
                                 appleSession: MusicTestSession(), applePlayback: apple, appleCatalog: MusicTestCatalog(service: .appleMusic),
                                 musicPreferences: .init(defaults: defaults))
            let request = Task { await model.loadDevices() }
            await waitUntil { spotify.pendingDevices != nil }
            model.selectMusicService(.appleMusic)
            if fails {
                spotify.pendingDevices?.resume(throwing: MusicServiceError.transport)
            } else {
                spotify.pendingDevices?.resume(returning: [.init(id: "old", name: "Old Spotify", type: "Speaker", isActive: true, isRestricted: false, volumePercent: 50, supportsVolume: true)])
            }
            await request.value
            if case .idle = model.devicesState {} else {
                XCTFail("An old service changed the device state")
            }
            XCTAssertNil(model.presentedError)
        }
    }

    func testShuffleStartIsOneProviderCommand() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let preferences = MusicSourcePreferences(defaults: defaults)
        preferences.selected = .appleMusic
        let apple = MusicTestPlayback()
        let model = AppModel(environment: .init(configuration: .preview, diagnostics: DiagnosticsStore(),
                                                spotifySession: MusicTestSpotifySession(), spotifyPlayback: MusicTestPlayback()),
                             catalogProvider: MusicTestCatalog(service: .spotify), lyrics: .init(providers: [], cache: MemoryLyricsCache()),
                             appleSession: MusicTestSession(), applePlayback: apple, appleCatalog: MusicTestCatalog(service: .appleMusic),
                             musicPreferences: preferences)
        let album = MusicCatalogItem(spotifyID: "123", kind: .album, name: "Album", subtitle: "", artworkURL: nil,
                                     availability: .available, service: .appleMusic)
        try await model.playCatalog(album, shuffled: true)
        XCTAssertEqual(apple.commands, ["shuffled:123"])
    }

    func testLateLibraryFailureBecomesCancellationAfterSourceSwitch() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let preferences = MusicSourcePreferences(defaults: defaults)
        preferences.selected = .appleMusic
        let model = AppModel(environment: .init(configuration: .preview, diagnostics: DiagnosticsStore(),
                                                spotifySession: MusicTestSpotifySession(), spotifyPlayback: MusicTestPlayback()),
                             catalogProvider: MusicTestCatalog(service: .spotify), lyrics: .init(providers: [], cache: MemoryLyricsCache()),
                             appleSession: MusicTestSession(), applePlayback: MusicTestPlayback(), appleCatalog: MusicTestCatalog(service: .appleMusic),
                             musicPreferences: preferences)
        var pending: CheckedContinuation<Void, Error>?
        let request = Task {
            do {
                try await model.mutateAppleLibrary { _ in try await withCheckedThrowingContinuation { pending = $0 } }
                XCTFail("Expected the obsolete request to be cancelled")
            } catch is CancellationError {} catch { XCTFail("Obsolete errors must not reach the active source: \(error)") }
        }
        await waitUntil { pending != nil }
        model.selectMusicService(.spotify)
        pending?.resume(throwing: MusicServiceError.cloudLibraryRequired)
        await request.value
        XCTAssertNil(model.presentedError)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0 ..< 1000 {
            if predicate() {
                return
            }; await Task.yield()
        }
        XCTFail("Async fixture did not reach its expected suspension")
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
    var deferDevices = false
    var pendingDevices: CheckedContinuation<[PlaybackDevice], Error>?
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
        if deferDevices {
            return try await withCheckedThrowingContinuation { pendingDevices = $0 }
        }
        return []
    }

    func playShuffled(_ item: MusicCatalogItem) async throws {
        commands.append("shuffled:" + item.spotifyID)
    }

    func transferPlayback(to _: String) async throws {}
}

@MainActor
private final class MusicTestCatalog: MusicCatalogProviding {
    var deferPages = false
    var pendingPages: [CheckedContinuation<MusicPage<MusicCatalogRow>, Error>] = []
    let service: MusicServiceID
    init(service: MusicServiceID) {
        self.service = service
    }

    func profile() async throws -> MusicProfile {
        .init(accountID: "context", displayName: service.title)
    }

    func invalidate() {}
    func page(_: MusicCatalogQuery, next _: URL?) async throws -> MusicPage<MusicCatalogRow> {
        if deferPages {
            return try await withCheckedThrowingContinuation { pendingPages.append($0) }
        }
        return .init(items: [], next: nil, total: 0)
    }

    func detail(kind _: MusicCatalogKind, id _: String) async throws -> MusicCatalogDetail {
        throw MusicCatalogError.unavailable
    }
}

@MainActor private final class MusicTestAPI: AppleMusicRequesting {
    var pending: [CheckedContinuation<Data, Error>] = []
    func send(_: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}

@MainActor private final class MusicTestAccount: AppleMusicAccountChecking {
    var authorization: MusicAuthorizationState = .authorized
    let subscriptionUpdates: AsyncStream<MusicServiceCapabilities>
    let updates: AsyncStream<MusicServiceCapabilities>.Continuation
    init() {
        let stream = AsyncStream<MusicServiceCapabilities>.makeStream()
        subscriptionUpdates = stream.stream
        updates = stream.continuation
    }

    func requestAuthorization() async {}
    func subscription() async throws -> MusicServiceCapabilities {
        .init(canBrowse: true, canPlayCatalog: true, canModifyLibrary: true)
    }
}
