@testable import AMLLPlayer
import XCTest

@MainActor
final class LyricsCoordinatorTests: XCTestCase {
    private let track = TrackIdentity(spotifyID: "a", title: "Title", artists: ["Artist"], duration: 10)
    private func store() -> LyricsSettingsStore {
        LyricsSettingsStore(defaults: UserDefaults(suiteName: "lyrics-tests-" + UUID().uuidString)!)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 1000 {
            if condition() {
                return
            }; try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for coordinator")
    }

    func testFailuresFallThroughInPriorityOrder() async {
        let apple = TestLyricsProvider(.apple), qq = TestLyricsProvider(.qq), netease = TestLyricsProvider(.netease)
        apple.failure = .credentials; qq.failure = .transport
        let coordinator = LyricsCoordinator(providers: [apple, qq, netease], cache: MemoryLyricsCache(), settingsStore: store())
        coordinator.update(track: track)
        await waitUntil { !coordinator.isLoading }
        XCTAssertEqual(coordinator.document?.candidate.source, .netease)
        XCTAssertEqual(coordinator.errors.count, 2); XCTAssertEqual(netease.searchCalls, 1)
    }

    func testStaleCacheVisibleBeforeFailedRefreshAndOfflineReload() async throws {
        let provider = TestLyricsProvider(.qq), cache = MemoryLyricsCache(), settings = store()
        provider.failure = .transport
        let candidate = provider.candidate
        let payload = LyricsPayload(format: .lrc, original: "[00:01]Cached")
        try cache.save(LyricsCacheEntry(track: track, payload: payload, document: payload.parse(candidate: candidate, duration: 10), savedAt: Date(timeIntervalSinceNow: -40 * 86400)), settings: settings.load())
        let coordinator = LyricsCoordinator(providers: [provider], cache: cache, settingsStore: settings)
        coordinator.update(track: track)
        XCTAssertEqual(coordinator.document?.lines.first?.text, "Cached")
        await waitUntil { !coordinator.isLoading }
        XCTAssertEqual(coordinator.status, .stale); XCTAssertEqual(coordinator.document?.lines.first?.text, "Cached")
        coordinator.setForeground(false)
        coordinator.update(track: nil); coordinator.update(track: track)
        XCTAssertEqual(coordinator.document?.lines.first?.text, "Cached"); XCTAssertFalse(coordinator.isLoading)
    }

    func testLateTrackResponseCannotReplaceNewTrack() async {
        let provider = TestLyricsProvider(.qq); provider.suspended = true
        let coordinator = LyricsCoordinator(providers: [provider], cache: MemoryLyricsCache(), settingsStore: store())
        coordinator.update(track: track)
        await waitUntil { provider.waiters.count == 1 }
        coordinator.update(track: TrackIdentity(spotifyID: "b", title: "New", artists: [], duration: 10))
        await waitUntil { provider.waiters.count == 2 }
        provider.resume(1, text: "New lyrics")
        await waitUntil { coordinator.document != nil }
        provider.resume(0, text: "Old lyrics")
        await Task.yield()
        XCTAssertEqual(coordinator.document?.lines.first?.text, "New lyrics"); XCTAssertEqual(coordinator.track?.spotifyID, "b")
    }

    func testManualPreviewDoesNotMutateUntilApplyAndLocksAgainstRefresh() async throws {
        let provider = TestLyricsProvider(.qq), cache = MemoryLyricsCache()
        let coordinator = LyricsCoordinator(providers: [provider], cache: cache, settingsStore: store())
        coordinator.update(track: track)
        await waitUntil { !coordinator.isLoading }
        let before = coordinator.document
        var manual = provider.candidate; manual.sourceID = "manual"
        coordinator.preview(manual)
        await waitUntil { !coordinator.isPreviewing }
        XCTAssertEqual(coordinator.document, before)
        coordinator.applyPreview()
        XCTAssertEqual(coordinator.selection.candidate?.sourceID, "manual")
        XCTAssertEqual(try cache.selection(for: "a").candidate?.sourceID, "manual")
        let calls = provider.searchCalls
        coordinator.reload(force: true)
        await waitUntil { !coordinator.isLoading }
        XCTAssertEqual(provider.searchCalls, calls); XCTAssertEqual(coordinator.document?.candidate.sourceID, "manual")
        coordinator.restoreAutomatic()
        await waitUntil { !coordinator.isLoading }
        XCTAssertNil(coordinator.selection.candidate); XCTAssertGreaterThan(provider.searchCalls, calls)
    }

    func testRapidPreviewSelectionAndDismissDiscardLateResults() async {
        let provider = TestLyricsProvider(.qq), coordinator = LyricsCoordinator(providers: [], cache: MemoryLyricsCache(), settingsStore: store())
        coordinator.update(track: track)
        let active = LyricsCoordinator(providers: [provider], cache: MemoryLyricsCache(), settingsStore: store())
        active.update(track: track)
        await waitUntil { !active.isLoading }
        provider.suspended = true
        active.preview(provider.candidate)
        await waitUntil { provider.waiters.count == 1 }
        var second = provider.candidate; second.sourceID = "second"
        active.preview(second)
        await waitUntil { provider.waiters.count == 2 }
        provider.resume(1, text: "second")
        await waitUntil { !active.isPreviewing }
        provider.resume(0, text: "first")
        await Task.yield()
        XCTAssertEqual(active.preview?.candidate.sourceID, "second")
        active.cancelSearch(); active.applyPreview()
        XCTAssertNil(active.selection.candidate)
    }

    func testApplyingManualResultInvalidatesInFlightAutomaticResult() async {
        let provider = TestLyricsProvider(.qq); provider.suspended = true
        let coordinator = LyricsCoordinator(providers: [provider], cache: MemoryLyricsCache(), settingsStore: store())
        coordinator.update(track: track)
        await waitUntil { provider.waiters.count == 1 }
        var manual = provider.candidate; manual.sourceID = "manual"
        coordinator.preview(manual)
        await waitUntil { provider.waiters.count == 2 }
        provider.resume(1, text: "Manual")
        await waitUntil { !coordinator.isPreviewing }
        coordinator.applyPreview()
        provider.resume(0, text: "Late auto")
        await Task.yield()
        XCTAssertEqual(coordinator.document?.lines.first?.text, "Manual")
        XCTAssertEqual(coordinator.selection.candidate?.sourceID, "manual")
    }

    func testOldSearchCannotPublishAfterQueryChanges() async {
        let provider = TestLyricsProvider(.qq)
        let coordinator = LyricsCoordinator(providers: [provider], cache: MemoryLyricsCache(), settingsStore: store())
        coordinator.update(track: track); await waitUntil { !coordinator.isLoading }
        provider.searchSuspended = true
        coordinator.search("old"); await waitUntil { provider.searchWaiters.count == 1 }
        coordinator.search("new"); await waitUntil { provider.searchWaiters.count == 2 }
        provider.resumeSearch(1, title: "New")
        await waitUntil { coordinator.searching.isEmpty }
        provider.resumeSearch(0, title: "Old")
        await Task.yield()
        XCTAssertEqual(coordinator.candidates[.qq]?.first?.title, "New")
    }

    func testManualLockSurvivesClearAndOffsetsPersistWithoutCaching() async throws {
        let cache = MemoryLyricsCache(), settings = store(), provider = TestLyricsProvider(.qq)
        let coordinator = LyricsCoordinator(providers: [provider], cache: cache, settingsStore: settings)
        coordinator.update(track: track); await waitUntil { !coordinator.isLoading }
        coordinator.preview(provider.candidate); await waitUntil { !coordinator.isPreviewing }; coordinator.applyPreview()
        coordinator.setOffset(11); XCTAssertEqual(coordinator.selection.offset, 10)
        coordinator.clearCache()
        XCTAssertTrue(cache.entries.isEmpty); XCTAssertNotNil(try cache.selection(for: "a").candidate)
        var config = coordinator.settings; config.cacheEnabled = false
        coordinator.updateSettings(config); await waitUntil { !coordinator.isLoading }
        XCTAssertTrue(cache.entries.isEmpty)
        coordinator.setOffset(-11); XCTAssertEqual(try cache.selection(for: "a").offset, -10)
        coordinator.resetMatches(); await waitUntil { !coordinator.isLoading }
        XCTAssertNil(try cache.selection(for: "a").candidate); XCTAssertEqual(try cache.selection(for: "a").offset, -10)
    }

    func testCacheFailureDoesNotPreventCurrentLyrics() async {
        let coordinator = LyricsCoordinator(providers: [TestLyricsProvider(.qq)], cache: FailingLyricsCache(), settingsStore: store())
        coordinator.update(track: track); await waitUntil { !coordinator.isLoading }
        XCTAssertNotNil(coordinator.document); XCTAssertNotNil(coordinator.cacheWarning)
    }

    func testFreshnessZeroMeansNeverExpire() throws {
        let candidate = TestLyricsProvider(.qq).candidate, payload = LyricsPayload(format: .lrc, original: "[00:01]x")
        let entry = try LyricsCacheEntry(track: track, payload: payload, document: payload.parse(candidate: candidate, duration: 10), savedAt: .distantPast)
        XCTAssertTrue(entry.isFresh(days: 0)); XCTAssertFalse(entry.isFresh(days: 30))
    }

    func testSettingsValidationAndPersistence() throws {
        let settings = store()
        var value = LyricsSettings(); value.priority = [.qq, .qq]; value.storefront = "../us"; value.language = ""; value.refreshDays = -1
        try settings.save(value)
        let restored = settings.load()
        XCTAssertEqual(restored.priority, [.qq, .apple, .netease]); XCTAssertEqual(restored.storefront, "us")
        XCTAssertEqual(restored.language, "zh-Hans-CN"); XCTAssertEqual(restored.refreshDays, 0)
    }
}

@MainActor
private final class TestLyricsProvider: LyricsProvider {
    let source: LyricsSource
    var failure: LyricsError?
    var suspended = false
    var searchSuspended = false
    var searchCalls = 0
    var waiters: [CheckedContinuation<LyricsPayload, Error>?] = []
    var searchWaiters: [CheckedContinuation<[LyricCandidate], Never>?] = []
    var candidate: LyricCandidate {
        LyricCandidate(source: source, sourceID: "1", title: "Title", artists: ["Artist"], score: 99)
    }

    init(_ source: LyricsSource) {
        self.source = source
    }

    func search(track _: TrackIdentity, query _: String, settings _: LyricsSettings) async throws -> [LyricCandidate] {
        searchCalls += 1; if let failure {
            throw failure
        }
        if searchSuspended {
            return await withCheckedContinuation { searchWaiters.append($0) }
        }
        return [candidate]
    }

    func lyrics(candidate: LyricCandidate, settings _: LyricsSettings) async throws -> LyricsPayload {
        if let failure {
            throw failure
        }
        if suspended {
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        return LyricsPayload(format: .lrc, original: "[00:01]" + candidate.title)
    }

    func resume(_ index: Int, text: String) {
        waiters[index]?.resume(returning: LyricsPayload(format: .lrc, original: "[00:01]" + text)); waiters[index] = nil
    }

    func resumeSearch(_ index: Int, title: String) {
        var result = candidate; result.title = title
        searchWaiters[index]?.resume(returning: [result]); searchWaiters[index] = nil
    }
}

@MainActor
private final class FailingLyricsCache: LyricsCacheProviding {
    func read(track _: TrackIdentity, source _: LyricsSource, settings _: LyricsSettings) throws -> LyricsCacheEntry? {
        throw LyricsError.cache
    }

    func save(_: LyricsCacheEntry, settings _: LyricsSettings) throws {
        throw LyricsError.cache
    }

    func selection(for _: String) throws -> LyricsSelection {
        throw LyricsError.cache
    }

    func saveSelection(_: LyricsSelection, for _: String) throws {
        throw LyricsError.cache
    }

    func clearLyrics() throws {
        throw LyricsError.cache
    }

    func resetSelections() throws {
        throw LyricsError.cache
    }
}
