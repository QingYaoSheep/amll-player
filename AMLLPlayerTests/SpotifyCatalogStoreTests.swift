import XCTest

@testable import AMLLPlayer

@MainActor
final class SpotifyCatalogStoreTests: XCTestCase {
    private func row(_ id: String) -> SpotifyCatalogRow {
        SpotifyCatalogRow(id: id, item: SpotifyCatalogItem(
            spotifyID: id, kind: .track, name: id, subtitle: "", artworkURL: nil, availability: .available
        ), position: nil)
    }

    func testPagesAppendWithoutDuplicatesAndStopRepeatedCursor() async {
        let provider = CatalogTestProvider()
        let next = URL(string: "https://api.spotify.com/v1/me/tracks?offset=2")!
        provider.responses = [
            .success(SpotifyPage(items: [row("a"), row("b")], next: next, total: 4)),
            .success(SpotifyPage(items: [row("b"), row("c")], next: next, total: 4)),
        ]
        let state = SpotifyCatalogPageState()
        await state.load(query: .collection(.savedTracks), provider: provider)
        await state.load(query: .collection(.savedTracks), provider: provider, more: true)
        XCTAssertEqual(state.rows.map(\.id), ["a", "b", "c"])
        XCTAssertNil(state.next)
        XCTAssertEqual(provider.calls, 2)
    }

    func testCacheSkipsRepeatLoadButForceRefreshReplacesRows() async {
        let provider = CatalogTestProvider()
        provider.responses = [.success(SpotifyPage(items: [row("old")], next: nil, total: 1)),
                              .success(SpotifyPage(items: [row("new")], next: nil, total: 1))]
        let state = SpotifyCatalogPageState()
        await state.load(query: .collection(.recent), provider: provider)
        await state.load(query: .collection(.recent), provider: provider)
        XCTAssertEqual(provider.calls, 1)
        await state.load(query: .collection(.recent), provider: provider, force: true)
        XCTAssertEqual(state.rows.map(\.id), ["new"])
    }

    func testFailedRefreshKeepsUsableRowsAndOtherSectionsWork() async {
        let provider = CatalogTestProvider()
        provider.responses = [.success(SpotifyPage(items: [row("cached")], next: nil, total: 1)),
                              .failure(.offline), .success(SpotifyPage(items: [row("other")], next: nil, total: 1))]
        let store = SpotifyCatalogStore(provider: provider)
        let recent = store.page(.collection(.recent))
        await recent.load(query: .collection(.recent), provider: provider)
        await recent.load(query: .collection(.recent), provider: provider, force: true)
        await store.page(.collection(.topTracks)).load(query: .collection(.topTracks), provider: provider)
        XCTAssertEqual(recent.rows.first?.id, "cached")
        XCTAssertEqual(recent.error, .offline)
        XCTAssertEqual(store.page(.collection(.topTracks)).rows.first?.id, "other")
    }

    func testCancelledSearchCannotPublishLateResults() async {
        let provider = CatalogTestProvider()
        provider.suspend = true
        let state = SpotifyCatalogPageState()
        let old = Task { await state.load(query: .search("old", .track), provider: provider) }
        await waitForRequest(provider)
        state.cancel()
        provider.resume(SpotifyPage(items: [row("old")], next: nil, total: 1))
        await old.value
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.error)
    }

    func testLogoutInvalidatesInFlightResultsAndClearsSearchAndProfile() async {
        let provider = CatalogTestProvider()
        let store = SpotifyCatalogStore(provider: provider)
        store.activate()
        await store.loadProfile()
        store.searchText = "private query"
        let identity = store.identity
        let state = store.page(.collection(.savedTracks))
        provider.suspend = true
        let old = Task { await state.load(query: .collection(.savedTracks), provider: provider) }
        await waitForRequest(provider)
        store.reset()
        provider.resume(SpotifyPage(items: [row("private")], next: nil, total: 1))
        await old.value
        XCTAssertNil(store.profile)
        XCTAssertEqual(store.searchText, "")
        XCTAssertFalse(store.active)
        XCTAssertNotEqual(store.identity, identity)
        XCTAssertEqual(provider.invalidations, 1)
        XCTAssertTrue(store.page(.collection(.savedTracks)).rows.isEmpty)
        XCTAssertTrue(state.rows.isEmpty)
    }

    func testAccountChangeInvalidatesPreviouslyLoadedCollections() async {
        let provider = CatalogTestProvider()
        let store = SpotifyCatalogStore(provider: provider)
        store.activate()
        await store.loadProfile()
        let before = store.identity
        provider.profileID = "second"
        await store.loadProfile(force: true)
        XCTAssertEqual(store.profile?.accountID, "second")
        XCTAssertNotEqual(before, store.identity)
        XCTAssertEqual(provider.invalidations, 1)
    }

    private func waitForRequest(_ provider: CatalogTestProvider) async {
        for _ in 0..<1_000 {
            if provider.pending != nil { return }
            await Task.yield()
        }
        XCTFail("The mock request did not start")
    }
}

@MainActor
private final class CatalogTestProvider: SpotifyCatalogProviding {
    var calls = 0
    var invalidations = 0
    var profileID = "first"
    var suspend = false
    var responses: [Result<SpotifyPage<SpotifyCatalogRow>, SpotifyCatalogError>] = []
    var pending: CheckedContinuation<SpotifyPage<SpotifyCatalogRow>, Error>?

    func profile() async throws -> SpotifyProfile { SpotifyProfile(accountID: profileID, displayName: profileID) }
    func detail(kind: SpotifyCatalogKind, id: String) async throws -> SpotifyCatalogDetail { throw SpotifyCatalogError.unavailable }
    func invalidate() { invalidations += 1 }
    func page(_ query: SpotifyCatalogQuery, next: URL?) async throws -> SpotifyPage<SpotifyCatalogRow> {
        calls += 1
        if suspend { return try await withCheckedThrowingContinuation { pending = $0 } }
        guard !responses.isEmpty else { throw SpotifyCatalogError.invalidResponse }
        return try responses.removeFirst().get()
    }
    func resume(_ page: SpotifyPage<SpotifyCatalogRow>) {
        pending?.resume(returning: page)
        pending = nil
    }
}
