import XCTest
@testable import AMLLPlayer

@MainActor
final class MusicExperienceTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "product-tests-" + UUID().uuidString)! }

    func testHomeOrdersSupportedSectionsAndOmitsPrivateSectionsWithoutConnection() {
        let supported: [MusicLibrarySection] = [.charts, .recommendations, .playlists, .recent, .savedTracks]
        XCTAssertEqual(MusicHomePresentation.sections(supported: supported, connected: true), [.recent, .playlists, .recommendations, .charts, .savedTracks])
        XCTAssertEqual(MusicHomePresentation.sections(supported: supported, connected: false), [.recommendations, .charts])
        XCTAssertTrue(MusicHomePresentation.sections(supported: [.recent], connected: false).isEmpty)
    }
    func testMixedHomeSectionsUseItemKindsForSongColumns() {
        XCTAssertTrue(MusicHomePresentation.usesSongColumns(.charts, kinds: [.track, .track]))
        XCTAssertTrue(MusicHomePresentation.usesSongColumns(.recentlyAdded, kinds: [.track]))
        XCTAssertFalse(MusicHomePresentation.usesSongColumns(.recommendations, kinds: [.track, .album]))
    }
    func testSearchRequestRespectsKindsAndLibraryScope() {
        let all = MusicSearchRequest(term: "曲", library: false, kind: nil)
        XCTAssertEqual(all.queries(supported: [.track, .album, .station]), [.search("曲", .track), .search("曲", .album)])
        let library = MusicSearchRequest(term: "曲", library: true, kind: .playlist)
        XCTAssertEqual(library.queries(supported: [.playlist]), [.librarySearch("曲", .playlist)])
    }
    func testNewInstallCanSkipWelcomeAndSkipPersists() {
        let preferences = MusicWelcomePreferences(defaults: defaults())
        XCTAssertTrue(preferences.needsWelcome(existingConnection: false, savedSpotifyConfiguration: false))
        preferences.complete()
        XCTAssertFalse(preferences.needsWelcome(existingConnection: false, savedSpotifyConfiguration: false))
    }
    func testUpgradeKeepsExistingSourceAndDoesNotForceWelcome() {
        let storage = defaults()
        storage.set("appleMusic", forKey: "music.source.v1")
        let preferences = MusicWelcomePreferences(defaults: storage)
        XCTAssertFalse(preferences.needsWelcome(existingConnection: false, savedSpotifyConfiguration: false))
        XCTAssertEqual(storage.string(forKey: "music.source.v1"), "appleMusic")
    }
    func testLegacyVisualSettingsAndConnectionsSkipWelcome() {
        let storage = defaults()
        storage.set(Data([1]), forKey: "lyrics.render.v2")
        XCTAssertFalse(MusicWelcomePreferences(defaults: storage).needsWelcome(existingConnection: false, savedSpotifyConfiguration: false))
        XCTAssertFalse(MusicWelcomePreferences(defaults: defaults()).needsWelcome(existingConnection: true, savedSpotifyConfiguration: false))
        XCTAssertFalse(MusicWelcomePreferences(defaults: defaults()).needsWelcome(existingConnection: false, savedSpotifyConfiguration: true))
    }
    func testSearchHistoryOnlyChangesOnExplicitRememberAndIsServiceScoped() async {
        let storage = defaults()
        let provider = ProductTestProvider()
        let store = MusicCatalogStore(provider: provider, defaults: storage)
        store.searchText = "typing"
        await store.loadSearch(.init(term: "typing", library: false, kind: nil))
        XCTAssertTrue(store.searchHistory.isEmpty)
        store.rememberSearch("  complete  ")
        store.rememberSearch("next")
        store.rememberSearch("complete")
        XCTAssertEqual(store.searchHistory, ["complete", "next"])
        let other = ProductTestProvider(); other.service = .netease
        XCTAssertTrue(MusicCatalogStore(provider: other, defaults: storage).searchHistory.isEmpty)
        store.removeSearch("next")
        XCTAssertEqual(MusicCatalogStore(provider: provider, defaults: storage).searchHistory, ["complete"])
        store.clearSearchHistory()
        XCTAssertTrue(MusicCatalogStore(provider: provider, defaults: storage).searchHistory.isEmpty)
    }
    func testComprehensiveSearchKeepsSiblingResultsWhenOneTypeFails() async {
        let provider = ProductTestProvider()
        provider.failedKinds = [.album]
        let store = MusicCatalogStore(provider: provider, defaults: defaults())
        await store.loadSearch(.init(term: "test", library: false, kind: nil))
        XCTAssertEqual(Set(provider.calls), Set([.track, .album, .artist, .playlist]))
        XCTAssertEqual(store.page(.search("test", .album)).error, .offline)
        for kind in [MusicCatalogKind.track, .artist, .playlist] {
            XCTAssertEqual(store.page(.search("test", kind)).rows.count, 1)
        }
    }
    func testAllSearchGroupsStartConcurrently() async {
        let provider = ProductTestProvider(); provider.suspend = true
        let store = MusicCatalogStore(provider: provider, defaults: defaults())
        let task = Task { await store.loadSearch(.init(term: "parallel", library: false, kind: nil)) }
        await waitForCalls(provider, count: 4)
        XCTAssertEqual(provider.pending.count, 4)
        provider.resumeAll()
        await task.value
    }
    func testCancelAndSourceResetRejectAllLateSearchGroups() async {
        let provider = ProductTestProvider(); provider.suspend = true
        let store = MusicCatalogStore(provider: provider, defaults: defaults())
        store.activate()
        let task = Task { await store.loadSearch(.init(term: "old", library: false, kind: nil)) }
        await waitForCalls(provider, count: 4)
        let oldStates = [MusicCatalogKind.track, .album, .artist, .playlist].map { store.page(.search("old", $0)) }
        store.searchLibrary = true; store.searchFilter = .album; store.suggestions = ["private"]
        store.reset(); provider.resumeAll()
        await task.value
        XCTAssertTrue(oldStates.allSatisfy { $0.rows.isEmpty && !$0.isLoading })
        XCTAssertFalse(store.searchLibrary)
        XCTAssertNil(store.searchFilter)
        XCTAssertTrue(store.suggestions.isEmpty)
    }
    func testNewTermCancelsOldGroupsWithoutPublishingTheirResults() async {
        let provider = ProductTestProvider(); provider.suspend = true
        let store = MusicCatalogStore(provider: provider, defaults: defaults())
        let task = Task { await store.loadSearch(.init(term: "old", library: false, kind: .track)) }
        await waitForCalls(provider, count: 1)
        let oldState = store.page(.search("old", .track))
        provider.suspend = false
        await store.loadSearch(.init(term: "new", library: false, kind: .track))
        provider.resumeAll(); await task.value
        XCTAssertTrue(oldState.rows.isEmpty)
        XCTAssertEqual(store.page(.search("new", .track)).rows.first?.item.name, "new")
    }
    func testClearingLyricCachePreservesManualMatchesAndOffset() throws {
        let cache = MemoryLyricsCache()
        let selection = LyricsSelection(candidate: nil, offset: 1.2)
        try cache.saveSelection(selection, for: "netease:catalog:1")
        try cache.clearLyrics()
        XCTAssertEqual(try cache.selection(for: "netease:catalog:1"), selection)
    }
    private func waitForCalls(_ provider: ProductTestProvider, count: Int) async {
        for _ in 0..<2000 {
            if provider.calls.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected concurrent search requests")
    }
}

@MainActor
private final class ProductTestProvider: MusicCatalogProviding {
    var service: MusicServiceID = .spotify
    var failedKinds = Set<MusicCatalogKind>()
    var calls: [MusicCatalogKind] = []
    var suspend = false
    var pending: [(MusicCatalogQuery, CheckedContinuation<MusicPage<MusicCatalogRow>, Error>)] = []
    func profile() async throws -> MusicProfile { .init(accountID: "test", displayName: "Test") }
    func invalidate() {}
    func detail(kind: MusicCatalogKind, id: String) async throws -> MusicCatalogDetail { throw MusicCatalogError.unavailable }
    func page(_ query: MusicCatalogQuery, next: URL?) async throws -> MusicPage<MusicCatalogRow> {
        guard case let .search(_, kind) = query else { throw MusicCatalogError.unavailable }
        calls.append(kind)
        if suspend { return try await withCheckedThrowingContinuation { pending.append((query, $0)) } }
        if failedKinds.contains(kind) { throw MusicCatalogError.offline }
        return result(query)
    }
    func resumeAll() {
        let values = pending; pending.removeAll()
        for (query, continuation) in values { continuation.resume(returning: result(query)) }
    }
    private func result(_ query: MusicCatalogQuery) -> MusicPage<MusicCatalogRow> {
        guard case let .search(term, kind) = query else { return .init(items: [], next: nil, total: 0) }
        let item = MusicCatalogItem(spotifyID: term + kind.rawValue, kind: kind, name: term, subtitle: "", artworkURL: nil, availability: .available)
        return .init(items: [.init(id: item.id, item: item, position: nil)], next: nil, total: 1)
    }
}
