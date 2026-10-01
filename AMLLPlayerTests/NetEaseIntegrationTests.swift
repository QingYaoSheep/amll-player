@testable import AMLLPlayer
import XCTest

@MainActor final class NetEaseIntegrationTests: XCTestCase {
    func testWEAPIProtocolMatchesIndependentReferenceVector() throws {
        let result = try NetEaseCrypto.encrypt(["csrf_token": "", "type": 1], secret: "abcdefghijklmnop")
        XCTAssertEqual(result["encSecKey"], "d15a1683c992095d0c234c19966605c5c5964911268bbeda8cb8d08d834913e59d53b32358903a121b5fca784c1f5ae44951fd02524df58ecc98e52cc7cf8689b42c2e93ddf05b0592512d87f5960467e2f086c018849d76014d323500e30f13ef4cafbb0cf5a66731a3f1776c75ca35d0062dac70a3e33245afabcf47938487")
        // Fixture generated independently with node:crypto from the pinned MIT reference.
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "netease-weapi", withExtension: "json"))
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixture))
        XCTAssertEqual(result, expected)
    }
    func testCredentialRequestIsHTTPSAndCannotChooseAnotherHost() throws {
        let request = try NetEaseAPI.request("/cloudsearch/pc", ["s": "Test"], cookie: "MUSIC_U=secret; __csrf=csrf")
        XCTAssertEqual(request.url?.host, "music.163.com")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!.contains("secret"))
        XCTAssertThrowsError(try NetEaseAPI.request("https://evil.example", [:], cookie: "MUSIC_U=x"))
    }
    func testCookieNormalizationRejectsHeaderInjectionAndKeepsOnlyCredentialFields() throws {
        XCTAssertEqual(try NetEaseCookie.normalized("other=ignore; MUSIC_U=a=b; __csrf=c"), "MUSIC_U=a=b; __csrf=c")
        XCTAssertThrowsError(try NetEaseCookie.normalized("MUSIC_U=a\r\nHost:evil"))
        XCTAssertThrowsError(try NetEaseCookie.normalized("os=pc"))
    }
    func testFailedImportKeepsValidSessionAndStoredCookie() async throws {
        let api = NetEaseFixtureAPI(), store = NetEaseMemoryStore()
        let session = NetEaseSession(api: api, store: store)
        try await session.importCookie("MUSIC_U=good")
        let context = session.currentState.contextID
        api.invalidAccount = true
        do { try await session.importCookie("MUSIC_U=bad"); XCTFail("Must reject") } catch {}
        XCTAssertTrue(session.currentState.connected)
        XCTAssertEqual(session.currentState.contextID, context)
        XCTAssertEqual(String(data: try XCTUnwrap(store.load()), encoding: .utf8), "MUSIC_U=good")
    }
    func testAccountSwitchChangesContextAndDisconnectClearsCredential() async throws {
        let api = NetEaseFixtureAPI(), store = NetEaseMemoryStore()
        let session = NetEaseSession(api: api, store: store)
        try await session.importCookie("MUSIC_U=one")
        let context = session.currentState.contextID
        api.userID = 2
        try await session.importCookie("MUSIC_U=two")
        XCTAssertNotEqual(session.currentState.contextID, context)
        session.disconnect()
        XCTAssertNil(try store.load()); XCTAssertNil(session.profile); XCTAssertFalse(session.currentState.connected)
    }
    func testQRKeyReturningAfterViewExitCannotRestoreQRCode() async {
        let api = NetEaseFixtureAPI()
        api.deferQR = true
        let session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        let work = Task { await session.beginQR() }
        for _ in 0..<100 where api.qrContinuation == nil { await Task.yield() }
        session.cancelQR()
        api.qrContinuation?.resume(returning: .init(object: ["code": 200, "unikey": "late"], cookie: nil))
        await work.value
        XCTAssertNil(session.qrURL); XCTAssertFalse(session.currentState.requesting)
    }
    func testPlaylistPagingKeepsDuplicatePositionsAndUnavailablePlaceholders() async throws {
        let api = NetEaseFixtureAPI()
        let session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let catalog = NetEaseCatalog(session: session)
        let first = try await catalog.page(.playlistItems("99"), next: nil)
        XCTAssertEqual(first.items.count, 50)
        XCTAssertEqual(first.items[0].item.spotifyID, first.items[1].item.spotifyID)
        XCTAssertNotEqual(first.items[0].id, first.items[1].id)
        XCTAssertEqual(first.items[4].item.availability, .restricted)
        let next = try await catalog.page(.playlistItems("99"), next: first.next)
        XCTAssertEqual(next.items.map(\.position), Array(50..<60).map { Optional($0) })
        XCTAssertNil(next.next)
        let all = try await catalog.allSongs(.init(service: .netease, kind: .playlist, scope: .catalog, rawValue: "99"))
        XCTAssertEqual(all.count, 60)
        XCTAssertEqual(all[0].spotifyID, all[1].spotifyID)
    }
    func testCursorCannotBeReusedForAnotherQueryOrExternalHost() async throws {
        let api = NetEaseFixtureAPI(), session = NetEaseSession(api: NetEaseFixtureAPI(), store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let catalog = NetEaseCatalog(session: session)
        let page = try await catalog.page(.playlistItems("99"), next: nil)
        do { _ = try await catalog.page(.playlistItems("100"), next: page.next); XCTFail("Cross-query cursor") } catch {}
        do { _ = try await catalog.page(.playlistItems("99"), next: URL(string: "https://evil.example/")); XCTFail("External cursor") } catch {}
        XCTAssertTrue(api.paths.isEmpty)
    }
    func testAudioSourceRejectsTrialsMissingRightsAndUntrustedURLs() throws {
        func root(_ changes: [String: Any]) -> [String: Any] {
            var row: [String: Any] = ["id": 42, "code": 200, "url": "http://m7.music.126.net/audio.mp3", "level": "standard", "br": 128000]
            row.merge(changes) { _, new in new }; return ["data": [row]]
        }
        let playable = try NetEaseAudioSource.decode(root([:]), id: "42")
        XCTAssertEqual(playable.url.scheme, "https"); XCTAssertEqual(playable.level, "standard")
        XCTAssertThrowsError(try NetEaseAudioSource.decode(root(["freeTrialInfo": ["start": 0, "end": 30]]), id: "42"))
        XCTAssertThrowsError(try NetEaseAudioSource.decode(root(["url": NSNull()]), id: "42"))
        XCTAssertThrowsError(try NetEaseAudioSource.decode(root(["url": "https://evil.example/a"]), id: "42"))
    }
    func testOwnershipIsFromServerAndSpecialLikedPlaylistCannotBeEdited() throws {
        let own = NetEaseDecoder.item(["id": 99, "name": "Mine", "creator": ["userId": 1]], kind: .playlist, owner: "1")
        XCTAssertTrue(try XCTUnwrap(own).editablePlaylist)
        let readonly = NetEaseDecoder.item(["id": 99, "name": "Other", "creator": ["userId": 2]], kind: .playlist, owner: "1")
        XCTAssertFalse(try XCTUnwrap(readonly).libraryWritable)
        let liked = NetEaseDecoder.item(["id": 99, "name": "Liked", "creator": ["userId": 1], "specialType": 5], kind: .playlist, owner: "1")
        XCTAssertFalse(try XCTUnwrap(liked).editablePlaylist)
        XCTAssertFalse(try XCTUnwrap(liked).libraryWritable)
    }
    func testQueuePersistsDuplicateEntriesAndRestoresPausedOnSourceSwitch() async throws {
        let api = NetEaseFixtureAPI(), session = NetEaseSession(api: NetEaseFixtureAPI(), store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NetEaseTests-\(UUID())"))
        let catalog = NetEaseCatalog(session: session)
        let playback = NetEasePlayback(session: session, catalog: catalog, defaults: defaults)
        playback.start()
        let item = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Song", "dt": 10000], kind: .track))
        try await playback.enqueue(item, next: false); try await playback.enqueue(item, next: false)
        XCTAssertNotEqual(playback.queue.entries[0].id, playback.queue.entries[1].id)
        try await playback.seek(to: 5); try await playback.setShuffle(true); try await playback.setRepeat(.all)
        playback.deselect()
        let restored = NetEasePlayback(session: session, catalog: catalog, defaults: defaults)
        restored.start()
        XCTAssertEqual(restored.queue.entries.count, 2); XCTAssertEqual(restored.queue.position, 5)
        XCTAssertTrue(restored.queue.shuffle); XCTAssertEqual(restored.queue.repeatMode, .all)
        XCTAssertFalse(MusicAudioSession.ownsPlayback)
        restored.deselect()
        XCTAssertTrue(api.paths.isEmpty)
    }
    func testNetEaseIdentityAndPreferenceMigrationKeepExistingSpotifyKeys() throws {
        XCTAssertEqual(MusicTrackIdentity.key(service: .netease, scope: .catalog, id: "42"), "netease:catalog:42")
        XCTAssertEqual(MusicTrackIdentity.key(service: .spotify, scope: .catalog, id: "old"), "old")
        let d = try XCTUnwrap(UserDefaults(suiteName: "NetEaseSource-\(UUID())"))
        let p = MusicSourcePreferences(defaults: d)
        XCTAssertEqual(p.selected, .spotify); p.selected = .netease
        XCTAssertEqual(MusicSourcePreferences(defaults: d).selected, .netease)
    }

    func testQRCodeExpiryStopsPollingAndRequiresRefresh() async {
        let api = NetEaseFixtureAPI(); api.qrCode = 800
        let session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        await session.beginQR()
        for _ in 0..<100 where session.currentState.requesting { await Task.yield() }
        XCTAssertNil(session.qrURL); XCTAssertFalse(session.currentState.requesting)
        XCTAssertTrue(session.qrStatus.contains("过期"))
        XCTAssertEqual(api.paths.filter { $0 == "/login/qrcode/client/login" }.count, 1)
    }
    func testQRCodeConfirmedAccountIsValidatedBeforeCredentialStorage() async throws {
        let api = NetEaseFixtureAPI(); api.qrCode = 803
        let store = NetEaseMemoryStore(), session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        let valid = NetEaseSession(api: api, store: store)
        await valid.beginQR()
        for _ in 0..<100 where valid.currentState.requesting { await Task.yield() }
        XCTAssertTrue(valid.currentState.connected)
        XCTAssertEqual(String(data: try XCTUnwrap(store.load()), encoding: .utf8), "MUSIC_U=qr")
        XCTAssertNil(valid.qrURL)
        api.invalidAccount = true
        await session.beginQR()
        for _ in 0..<100 where session.currentState.requesting { await Task.yield() }
        XCTAssertFalse(session.currentState.connected)
    }
    func testExpiredPrivateRequestClearsSessionWithoutRetriedAuthentication() async throws {
        let api = NetEaseFixtureAPI(), store = NetEaseMemoryStore()
        let session = NetEaseSession(api: api, store: store)
        try await session.importCookie("MUSIC_U=x")
        do { _ = try await session.call("/fixture/expired"); XCTFail("Must expire") } catch {}
        XCTAssertFalse(session.currentState.connected); XCTAssertNil(try store.load())
        XCTAssertEqual(api.paths.filter { $0 == "/fixture/expired" }.count, 1)
    }
    func testLateAudioURLAfterSourceSwitchCannotAcquireAudioSession() async throws {
        let api = NetEaseFixtureAPI(); api.deferAudio = true
        let session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let d = try XCTUnwrap(UserDefaults(suiteName: "NetEaseLateAudio-\(UUID())"))
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: d)
        playback.start()
        let song = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Song"], kind: .track))
        let work = Task { try await playback.play(item: song, context: nil, position: nil) }
        for _ in 0..<100 where api.audioContinuation == nil { await Task.yield() }
        playback.deselect()
        api.audioContinuation?.resume(returning: .init(object: ["data": [["id": 42, "code": 200, "url": "https://m7.music.126.net/a.mp3", "level": "exhigh"]]], cookie: nil))
        do { try await work.value; XCTFail("Late source must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(MusicAudioSession.ownsPlayback)
    }
    func testPauseDuringAudioLookupDoesNotStartReturnedSource() async throws {
        let api = NetEaseFixtureAPI(); api.deferAudio = true
        let session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let d = try XCTUnwrap(UserDefaults(suiteName: "NetEasePauseLookup-\(UUID())"))
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: d)
        playback.start()
        let song = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Song"], kind: .track))
        let work = Task { try await playback.play(item: song, context: nil, position: nil) }
        for _ in 0..<100 where api.audioContinuation == nil { await Task.yield() }
        try await playback.pause()
        api.audioContinuation?.resume(returning: .init(object: ["data": [["id": 42, "code": 200, "url": "https://m7.music.126.net/a.mp3"]]], cookie: nil))
        do { try await work.value; XCTFail("Paused lookup must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(MusicAudioSession.ownsPlayback); playback.deselect()
    }
    func testRandomContextRequestsOnlyOneStartingAudioSource() async throws {
        let api = NetEaseFixtureAPI()
        let session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session),
                                      defaults: try XCTUnwrap(UserDefaults(suiteName: "NetEaseRandom-\(UUID())")))
        playback.start()
        let playlist = try XCTUnwrap(NetEaseDecoder.item(["id": 99, "name": "List"], kind: .playlist))
        do { try await playback.playShuffled(playlist); XCTFail("Fixture has no audio") } catch {}
        XCTAssertEqual(api.paths.filter { $0 == "/song/enhance/player/url/v1" }.count, 1)
        XCTAssertEqual(Set(playback.queue.shuffleOrder ?? []).count, playback.queue.entries.count)
        XCTAssertEqual(playback.queue.shuffleOrder?.first, playback.queue.currentID)
        playback.deselect()
    }
    func testQueueRemovalDoesNotLeaveDeletedSongPlayingOrDuplicateIdentity() async throws {
        let session = NetEaseSession(api: NetEaseFixtureAPI(), store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session),
                                      defaults: try XCTUnwrap(UserDefaults(suiteName: "NetEaseRemove-\(UUID())")))
        playback.start()
        let item = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Song"], kind: .track))
        try await playback.enqueue(item, next: false); try await playback.enqueue(item, next: false)
        let old = playback.queue.currentID
        playback.remove(at: [0])
        XCTAssertEqual(playback.queue.entries.count, 1); XCTAssertNotEqual(playback.queue.currentID, old)
        XCTAssertFalse(MusicAudioSession.ownsPlayback)
        playback.remove(at: [0]); XCTAssertNil(playback.queue.currentID); playback.deselect()
    }
    func testUnsignedBrowsingHasOnlyPublicHomeSectionsAndWritesRemainUnavailable() {
        let session = NetEaseSession(api: NetEaseFixtureAPI(), store: NetEaseMemoryStore())
        let catalog = NetEaseCatalog(session: session)
        XCTAssertEqual(catalog.homeSections, [.recommendations, .charts])
        XCTAssertTrue(catalog.librarySections.isEmpty)
        XCTAssertFalse(session.currentState.capabilities.canEditPlaylists)
        XCTAssertFalse(session.currentState.capabilities.canEditQueue)
    }

    func testAudioInterruptionInvalidatesPendingURLAndNeverResumesAutomatically() async throws {
        let api = NetEaseFixtureAPI(); api.deferAudio = true
        let session = NetEaseSession(api: api, store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session),
                                      defaults: try XCTUnwrap(UserDefaults(suiteName: "NetEaseInterrupt-\(UUID())")))
        playback.start()
        let song = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Song"], kind: .track))
        let work = Task { try await playback.play(item: song, context: nil, position: nil) }
        for _ in 0..<100 where api.audioContinuation == nil { await Task.yield() }
        playback.suspendForInterruption()
        api.audioContinuation?.resume(returning: .init(object: ["data": [["id": 42, "code": 200, "url": "https://m7.music.126.net/a.mp3"]]], cookie: nil))
        do { try await work.value; XCTFail("Interrupted lookup must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(MusicAudioSession.ownsPlayback); playback.deselect()
    }
    func testPlayNextInShuffleAppearsImmediatelyAfterCurrentEntry() async throws {
        let session = NetEaseSession(api: NetEaseFixtureAPI(), store: NetEaseMemoryStore())
        try await session.importCookie("MUSIC_U=x")
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session),
                                      defaults: try XCTUnwrap(UserDefaults(suiteName: "NetEasePlayNext-\(UUID())")))
        playback.start()
        let song = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Song"], kind: .track))
        for _ in 0..<4 { try await playback.enqueue(song, next: false) }
        try await playback.setShuffle(true)
        let prior = playback.displayedEntries.map(\.id)
        try await playback.enqueue(song, next: true)
        let after = playback.displayedEntries.map(\.id)
        XCTAssertEqual(after[0], prior[0]); XCTAssertFalse(prior.contains(after[1]))
        XCTAssertEqual(Array(after.dropFirst(2)), Array(prior.dropFirst()))
        playback.deselect()
    }

    func testExpiredStoredCookieReturningEmptyProfileDisconnectsAndRemovesCredential() async throws {
        let api = NetEaseFixtureAPI(), store = NetEaseMemoryStore()
        let session = NetEaseSession(api: api, store: store)
        try await session.importCookie("MUSIC_U=x")
        api.invalidAccount = true
        await session.refresh()
        XCTAssertFalse(session.currentState.connected)
        XCTAssertNil(session.profile); XCTAssertNil(try store.load())
    }
}
@MainActor private final class NetEaseFixtureAPI: NetEaseRequesting {
    var userID = 1
    var invalidAccount = false
    var deferQR = false
    var deferAudio = false
    var qrCode = 800
    var audioContinuation: CheckedContinuation<NetEaseResponse, Never>?
    var qrContinuation: CheckedContinuation<NetEaseResponse, Never>?
    var paths: [String] = []
    func send(_ path: String, _ parameters: [String: Any], cookie: String?) async throws -> NetEaseResponse {
        paths.append(path)
        switch path {
        case "/w/nuser/account/get":
            return .init(object: invalidAccount ? ["code": 200] : ["code": 200, "profile": ["userId": userID, "nickname": "Fixture"]], cookie: nil)
        case "/login/qrcode/unikey":
            if deferQR { return await withCheckedContinuation { qrContinuation = $0 } }
            return .init(object: ["code": 200, "unikey": "key"], cookie: nil)
        case "/login/qrcode/client/login":
            return .init(object: ["code": qrCode], cookie: qrCode == 803 ? "MUSIC_U=qr" : nil)
        case "/fixture/expired": throw NetEaseError.expired
        case "/song/enhance/player/url/v1":
            if deferAudio { return await withCheckedContinuation { audioContinuation = $0 } }
            throw NetEaseError.unavailable
        case "/v6/playlist/detail":
            let ids = (0..<60).map { ["id": $0 < 2 ? 42 : $0] }
            return .init(object: ["playlist": ["id": 99, "name": "List", "trackIds": ids, "creator": ["userId": userID]]], cookie: nil)
        case "/v3/song/detail":
            let raw = parameters["c"] as? String ?? "[]"
            let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: String]] ?? []
            let songs = input.filter { $0["id"] != "4" }.map { ["id": $0["id"]!, "name": "Song", "dt": 10000] as [String: Any] }
            return .init(object: ["songs": songs], cookie: nil)
        default: throw NetEaseError.unavailable
        }
    }
}
private final class NetEaseMemoryStore: SpotifySessionDataStoring, @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()
    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data) throws { lock.withLock { self.data = data } }
    func remove() throws { lock.withLock { data = nil } }
}
