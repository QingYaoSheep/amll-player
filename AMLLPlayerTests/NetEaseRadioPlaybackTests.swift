import AVFoundation
import XCTest
@testable import AMLLPlayer

@MainActor final class NetEaseRadioPlaybackTests: XCTestCase {
    private func make(_ api: RadioAPI, savedRadio: NetEaseRadioState? = nil) async throws -> (NetEasePlayback, UserDefaults) {
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Radio-" + UUID().uuidString))
        if let savedRadio { defaults.set(try JSONEncoder().encode(savedRadio), forKey: "netease.radio.v1.1") }
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "seek-markers", withExtension: "m4a"))
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: defaults,
            makeItem: { _ in NetEasePlayback.makeAudioItem(audio) })
        playback.start()
        return (playback, defaults)
    }
    func testRadioUsesRealPlayerAndRestoresOrdinaryQueuePaused() async throws {
        let api = RadioAPI(); let (playback, defaults) = try await make(api)
        defer { playback.stop() }
        let ordinary = try XCTUnwrap(NetEaseDecoder.item(RadioAPI.song(42), kind: .track))
        try await playback.enqueue(ordinary, next: false)
        try await playback.setShuffle(true); try await playback.setRepeat(.all)
        let original = playback.queue.currentID
        try await playback.startPersonalFM()
        XCTAssertTrue(playback.isPersonalFM)
        XCTAssertFalse(playback.queue.shuffle); XCTAssertEqual(playback.queue.repeatMode, .off)
        XCTAssertEqual(playback.currentEntry?.item.spotifyID, "100")
        for _ in 0..<200 where playback.latestSnapshot?.isPlaying != true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(playback.latestSnapshot?.isPlaying == true)
        try await playback.seek(to: 8.25)
        XCTAssertEqual(try XCTUnwrap(playback.latestSnapshot?.position), 8.25, accuracy: 0.1)
        do { try await playback.setShuffle(true); XCTFail("Radio must reject queue modes") }
        catch { XCTAssertTrue(error is NetEaseRadioError) }
        playback.exitPersonalFM()
        XCTAssertFalse(playback.isPersonalFM); XCTAssertEqual(playback.queue.currentID, original)
        XCTAssertTrue(playback.queue.shuffle); XCTAssertEqual(playback.queue.repeatMode, .all)
        XCTAssertFalse(playback.latestSnapshot?.isPlaying ?? true)
        XCTAssertNil(defaults.data(forKey: "netease.radio.v1.1"))
    }
    func testLateRefillAfterExitCannotAppendOrResume() async throws {
        let api = RadioAPI(); let (playback, _) = try await make(api)
        defer { playback.stop() }
        let ordinary = try XCTUnwrap(NetEaseDecoder.item(RadioAPI.song(42), kind: .track))
        try await playback.enqueue(ordinary, next: false)
        try await playback.startPersonalFM()
        try await playback.pause()
        api.suspend = true
        let work = Task { await playback.retryPersonalFM() }
        for _ in 0..<100 where api.pending == nil { await Task.yield() }
        XCTAssertNotNil(api.pending)
        playback.exitPersonalFM()
        api.pending?.resume(returning: .init(object: ["data": [RadioAPI.song(999)]], cookie: nil)); api.pending = nil
        await work.value
        XCTAssertEqual(playback.queue.entries.map { $0.item.spotifyID }, ["42"])
        XCTAssertFalse(playback.latestSnapshot?.isPlaying ?? true)
    }
    func testPausePersistsFMAndRestartDoesNotFetchOrPlay() async throws {
        let api = RadioAPI(); let (playback, defaults) = try await make(api)
        defer { playback.stop() }
        try await playback.startPersonalFM(); try await playback.pause()
        let expected = playback.queue.currentID, calls = api.batches
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let restored = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: defaults)
        restored.start(); defer { restored.stop() }
        try await restored.refresh()
        XCTAssertTrue(restored.isPersonalFM); XCTAssertEqual(restored.queue.currentID, expected)
        XCTAssertFalse(restored.latestSnapshot?.isPlaying ?? true); XCTAssertEqual(api.batches, calls)
    }
    func testFailedStartupKeepsOrdinaryQueue() async throws {
        let api = RadioAPI(); api.audioUnavailable = true
        let (playback, _) = try await make(api); defer { playback.stop() }
        try await playback.enqueue(try XCTUnwrap(NetEaseDecoder.item(RadioAPI.song(42), kind: .track)), next: false)
        do { try await playback.startPersonalFM(); XCTFail("Unavailable media must not enter radio") } catch {}
        XCTAssertFalse(playback.isPersonalFM)
        XCTAssertEqual(playback.currentEntry?.item.spotifyID, "42")
    }
    func testSystemInterruptionCancelsDelayedFMStartup() async throws {
        let api = RadioAPI(); api.suspend = true
        let (playback, _) = try await make(api); defer { playback.stop() }
        let work = Task { try await playback.startPersonalFM() }
        for _ in 0..<100 where api.pending == nil { await Task.yield() }
        XCTAssertNotNil(api.pending)
        playback.suspendForInterruption()
        api.pending?.resume(returning: .init(object: ["data": [RadioAPI.song(100)]], cookie: nil)); api.pending = nil
        do { try await work.value; XCTFail("Interruption must cancel startup") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(playback.isPersonalFM); XCTAssertFalse(playback.isStartingRadio)
        XCTAssertFalse(playback.latestSnapshot?.isPlaying ?? true)
    }
    func testOrdinaryQueueIsCapturedAtHandoff() async throws {
        let api = RadioAPI(); api.suspendAudio = true
        let (playback, _) = try await make(api); defer { playback.stop() }
        try await playback.enqueue(try XCTUnwrap(NetEaseDecoder.item(RadioAPI.song(42), kind: .track)), next: false)
        let work = Task { try await playback.startPersonalFM() }
        for _ in 0..<100 where api.audioPending == nil { await Task.yield() }
        XCTAssertNotNil(api.audioPending)
        try await playback.enqueue(try XCTUnwrap(NetEaseDecoder.item(RadioAPI.song(43), kind: .track)), next: false)
        playback.remove(at: IndexSet(integer: 0))
        let target = playback.queue.currentID
        api.audioPending?.resume(returning: RadioAPI.audio(100)); api.audioPending = nil; api.suspendAudio = false
        try await work.value
        playback.exitPersonalFM()
        XCTAssertEqual(playback.queue.currentID, target)
        XCTAssertEqual(playback.queue.entries.map { $0.item.spotifyID }, ["43"])
    }
    func testPausedRetryAndResumeShareOneRefillAndContinueAfterIt() async throws {
        let api = RadioAPI(); api.batchSize = 3
        let (playback, _) = try await make(api); defer { playback.stop() }
        try await playback.startPersonalFM(); try await playback.pause()
        api.suspend = true
        let work = Task { await playback.retryPersonalFM() }
        for _ in 0..<100 where api.pending == nil { await Task.yield() }
        XCTAssertNotNil(api.pending)
        let count = api.batches
        try await playback.play()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(api.batches, count)
        api.pending?.resume(returning: .init(object: ["data": [RadioAPI.song(900)]], cookie: nil)); api.pending = nil; api.suspend = false
        await work.value
        XCTAssertFalse(playback.isRefillingRadio)
        let tail = try XCTUnwrap(playback.queue.entries.last?.id)
        try await playback.selectEntry(tail)
        for _ in 0..<100 where api.batches == count { await Task.yield() }
        XCTAssertGreaterThan(api.batches, count, "A completed retry must not block the next automatic refill")
    }
    func testBrowsingHomeDoesNotConsumeRadioAndMoodsUseRealCategories() async throws {
        let api = RadioAPI()
        let publicSession = NetEaseSession(api: api, store: SeekFixtureStore())
        let catalog = NetEaseCatalog(session: publicSession)
        _ = try await catalog.homePage(.newAlbums, next: nil)
        _ = try await catalog.homePage(.mood("放松"), next: nil)
        XCTAssertEqual(api.batches, 0)
        XCTAssertEqual(api.category, "放松")
        XCTAssertFalse(publicSession.currentState.connected)
    }
    func testSelectingPendingTailTrimsHistoryBeforeRefillAndRemainsRestorable() async throws {
        let api = RadioAPI(); api.batchSize = 10
        let entries = try (0..<61).map { id in
            NetEaseQueueEntry(item: try XCTUnwrap(NetEaseDecoder.item(RadioAPI.song(id), kind: .track)))
        }
        let queue = NetEaseQueueState(entries: entries, currentID: entries[50].id)
        let record = NetEaseRadioState(ordinary: .init(), radio: queue, recentIDs: entries.map { $0.item.spotifyID })
        let (playback, defaults) = try await make(api, savedRadio: record)
        defer { playback.stop() }
        try await playback.selectEntry(entries[60].id)
        for _ in 0..<100 where api.batches == 0 || playback.isRefillingRadio { await Task.yield() }
        XCTAssertEqual(api.batches, 1)
        XCTAssertEqual(playback.queue.entries.firstIndex { $0.id == playback.queue.currentID }, 50)
        XCTAssertEqual(NetEaseRadioState.pendingCount(playback.queue), 10)
        XCTAssertEqual(playback.queue.entries.count, 61)
        try await playback.pause()
        let saved = try JSONDecoder().decode(NetEaseRadioState.self, from: XCTUnwrap(defaults.data(forKey: "netease.radio.v1.1")))
        XCTAssertTrue(saved.isValid)
        XCTAssertEqual(saved.radio.currentID, entries[60].id)
    }
    func testFiveUnavailableRecommendationsPauseWithRecovery() async throws {
        let api = RadioAPI()
        let (playback, _) = try await make(api); defer { playback.stop() }
        try await playback.startPersonalFM()
        api.audioUnavailable = true
        let calls = api.audioRequests
        do { try await playback.skipNext(); XCTFail("Five unavailable songs must stop automatic skipping") }
        catch { XCTAssertTrue(error is NetEaseRadioError) }
        XCTAssertEqual(api.audioRequests - calls, 5)
        XCTAssertNotNil(playback.radioFailure)
        XCTAssertFalse(playback.latestSnapshot?.isPlaying ?? true)
    }
}

@MainActor private final class RadioAPI: NetEaseRequesting {
    var batches = 0
    var audioRequests = 0
    var batchSize = 6
    var suspend = false, audioUnavailable = false
    var suspendAudio = false
    var audioPending: CheckedContinuation<NetEaseResponse, Never>?
    var category: String?
    var pending: CheckedContinuation<NetEaseResponse, Never>?
    static func song(_ id: Int) -> [String: Any] { ["id": id, "name": "Fixture \(id)", "dt": 48000] }
    static func audio(_ id: Int) -> NetEaseResponse {
        .init(object: ["data": [["id": id, "code": 200, "url": "https://m.music.126.net/fixture.m4a", "level": "exhigh"]]], cookie: nil)
    }
    func send(_ path: String, _ parameters: [String: Any], cookie: String?) async throws -> NetEaseResponse {
        switch path {
        case "/w/nuser/account/get": return .init(object: ["code": 200, "profile": ["userId": 1, "nickname": "Fixture"]], cookie: nil)
        case "/v1/radio/get":
            batches += 1
            if suspend { return await withCheckedContinuation { pending = $0 } }
            return .init(object: ["data": (0..<batchSize).map { Self.song(batches * 100 + $0) }], cookie: nil)
        case "/song/enhance/player/url/v1":
            audioRequests += 1
            if suspendAudio { return await withCheckedContinuation { audioPending = $0 } }
            if audioUnavailable { throw NetEaseError.unavailable }
            let raw = parameters["ids"] as? String ?? "[]"
            let ids = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Int] ?? []
            return .init(object: ["data": ids.map { ["id": $0, "code": 200, "url": "https://m.music.126.net/fixture.m4a", "level": "exhigh"] as [String: Any] }], cookie: nil)
        case "/album/new": return .init(object: ["albums": [], "total": 0], cookie: nil)
        case "/playlist/list": category = parameters["cat"] as? String; return .init(object: ["playlists": [], "more": false], cookie: nil)
        default: throw NetEaseError.unavailable
        }
    }
}
