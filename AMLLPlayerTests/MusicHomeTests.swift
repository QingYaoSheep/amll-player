import XCTest
@testable import AMLLPlayer

@MainActor final class MusicHomeTests: XCTestCase {
    func testFeaturedDeduplicatesResourcesButSectionPreservesOccurrences() async {
        let provider = HomeFixture()
        let store = MusicHomeStore(provider: provider)
        store.configure(connected: true, browsing: true)
        await store.prime()
        XCTAssertEqual(store.featured.count, 1)
        XCTAssertEqual(store.state(.catalog(.collection(.recent))).rows.count, 2)
    }
    func testRequestConcurrencyAndResetRejectsOldResults() async {
        let provider = HomeFixture(); provider.delay = true
        let store = MusicHomeStore(provider: provider)
        store.configure(connected: true, browsing: true)
        let old = store.state(.catalog(.collection(.recent)))
        let requests = Task {
            await withTaskGroup(of: Void.self) { group in
                for query in [MusicLibrarySection.recent, .playlists, .topTracks, .savedTracks, .savedAlbums, .followedArtists] {
                    group.addTask { @MainActor in await store.load(.catalog(.collection(query))) }
                }
            }
        }
        for _ in 0..<100 where provider.active < 3 { await Task.yield() }
        XCTAssertLessThanOrEqual(provider.maximum, 3)
        store.reset()
        await requests.value
        XCTAssertTrue(old.rows.isEmpty)
        XCTAssertTrue(store.sections.isEmpty)
    }
    func testFailedRefreshKeepsContentAndStoresFailure() async {
        let provider = HomeFixture(); let store = MusicHomeStore(provider: provider)
        store.configure(connected: true, browsing: true)
        await store.load(.catalog(.collection(.recent)))
        provider.fail = true
        await store.load(.catalog(.collection(.recent)), force: true)
        XCTAssertEqual(store.state(.catalog(.collection(.recent))).rows.count, 2)
        XCTAssertEqual(store.state(.catalog(.collection(.recent))).error, .offline)
    }
    func testRecommendationGroupsKeepTitleReasonOrderAndCursor() throws {
        let resource: [String: Any] = ["id": "song", "type": "songs", "attributes": ["name": "Title", "playParams": ["id": "song"]]]
        let data = try JSONSerialization.data(withJSONObject: ["data": [["id": "group", "attributes": ["title": ["stringForDisplay": "Original"], "reason": ["stringForDisplay": "Because"]], "relationships": ["contents": ["data": [resource, resource], "next": "/v1/me/recommendations/group/contents?offset=2"]]]]])
        let page = try AppleMusicHomeDecoder.page(data, query: .recommendations, url: URL(string: "https://api.music.apple.com/v1/me/recommendations")!)
        XCTAssertEqual(page.groups.first?.title, "Original")
        XCTAssertEqual(page.groups.first?.subtitle, "Because")
        XCTAssertEqual(page.groupPages["group"]?.items.count, 2)
        XCTAssertNotNil(page.groupPages["group"]?.next)
    }
    func testReplayUsesReturnedEligibleYearAndRelatedResource() throws {
        let data = try JSONSerialization.data(withJSONObject: ["data": [["id": "summary", "attributes": ["year": 2024, "period": "year"], "views": ["top-albums": ["data": [["relationships": ["album": ["data": [["id": "a", "type": "albums", "attributes": ["name": "Album"]]]]]]]]]]]])
        let page = try AppleMusicHomeDecoder.page(data, query: .replay, url: URL(string: "https://api.music.apple.com/v1/me/music-summaries")!)
        XCTAssertEqual(page.replay?.year, "2024")
        XCTAssertEqual(page.replay?.sections.first?.items.first?.item.name, "Album")
    }
    func testHomeSizingMatchesReferenceAndRemainsBoundedOnIPad() {
        XCTAssertEqual(MusicHomeLayout.coverWidth(in: 402, largeText: false), 150.22, accuracy: 0.1)
        XCTAssertEqual(MusicHomeLayout.featuredWidth(in: 402, largeText: false), 232, accuracy: 0.1)
        XCTAssertLessThanOrEqual(MusicHomeLayout.coverWidth(in: 1366, largeText: false), 200)
    }
}

@MainActor private final class HomeFixture: MusicCatalogProviding {
    var active = 0, maximum = 0
    var delay = false, fail = false
    func profile() async throws -> MusicProfile { .init(accountID: "test", displayName: "Test") }
    func invalidate() {}
    func detail(kind: MusicCatalogKind, id: String) async throws -> MusicCatalogDetail { throw MusicCatalogError.unavailable }
    func page(_ query: MusicCatalogQuery, next: URL?) async throws -> MusicPage<MusicCatalogRow> {
        active += 1; maximum = max(active, maximum); defer { active -= 1 }
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        if fail { throw MusicCatalogError.offline }
        let item = MusicCatalogItem(spotifyID: "same", kind: .track, name: "Song", subtitle: "", artworkURL: nil, availability: .available)
        return .init(items: [0, 1].map { .init(id: "\(query):\($0)", item: item, position: $0) }, next: nil, total: 2)
    }
}
