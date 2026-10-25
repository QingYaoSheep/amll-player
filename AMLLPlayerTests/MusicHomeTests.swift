import XCTest
import Observation
import os
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
                    group.addTask { await store.load(.catalog(.collection(query))) }
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
    func testRecommendationWithoutEmbeddedContentsInvalidatesFeaturedWhenLoaded() async {
        let store = MusicHomeStore(provider: RecommendationHomeFixture())
        store.configure(connected: true, browsing: true)
        await store.load(.recommendations)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = store.featured } onChange: { changed.withLock { $0 = true } }
        await store.load(.recommendation("new-music"))
        XCTAssertTrue(changed.withLock { $0 }, "The home must observe recommendation rows before their first load")
        XCTAssertEqual(store.featured.first?.0.item.name, "Recommended Song")
        XCTAssertEqual(store.state(.recommendations).groups.first?.title, "New Music for You")
    }
    func testReplayViewSeedsItsFirstPageAndContinuesFromReturnedCursor() async {
        let provider = RecommendationHomeFixture()
        let store = MusicHomeStore(provider: provider)
        store.configure(connected: true, browsing: true)
        await store.load(.replay)
        let state = store.state(.replayView("2024", "top-songs"))
        XCTAssertEqual(state.rows.map(\.id), ["first"])
        XCTAssertEqual(state.next, provider.cursor)
        await store.load(.replayView("2024", "top-songs"), more: true)
        XCTAssertEqual(provider.lastCursor, provider.cursor)
        XCTAssertEqual(state.rows.map(\.id), ["first", "second"])
        XCTAssertNil(state.next)
    }
    func testReplayDecoderPreservesViewCursorAndResourceOccurrences() throws {
        let song: [String: Any] = ["id": "s", "type": "songs", "attributes": ["name": "Song"]]
        let entry: [String: Any] = ["relationships": ["song": ["data": [song]]]]
        let next = "/v1/me/music-summaries/2024/view/top-songs?offset=2"
        let data = try JSONSerialization.data(withJSONObject: ["data": [["id": "2024", "attributes": ["year": 2024, "period": "year"],
            "views": ["top-songs": ["data": [entry, entry], "next": next]]]]])
        let page = try AppleMusicHomeDecoder.page(data, query: .replay, url: URL(string: "https://api.music.apple.com/v1/me/music-summaries")!)
        let section = try XCTUnwrap(page.replay?.sections.first)
        XCTAssertEqual(section.query, .replayView("2024", "top-songs"))
        XCTAssertEqual(section.next?.path, "/v1/me/music-summaries/2024/view/top-songs")
        XCTAssertEqual(section.items.count, 2)
        XCTAssertNotEqual(section.items[0].id, section.items[1].id)
        let following = try JSONSerialization.data(withJSONObject: ["data": [entry]])
        let continuation = try AppleMusicHomeDecoder.page(following, query: .replayView("2024", "top-songs"), url: section.next!)
        XCTAssertEqual(continuation.items.first?.item.name, "Song")
    }
}

@MainActor private final class RecommendationHomeFixture: MusicHomeProviding {
    var service: MusicServiceID { .appleMusic }
    let cursor = URL(string: "https://api.music.apple.com/v1/me/music-summaries/2024/view/top-songs?offset=1")!
    var lastCursor: URL?
    func profile() async throws -> MusicProfile { .init(accountID: "test", displayName: "Test") }
    func invalidate() {}
    func detail(kind: MusicCatalogKind, id: String) async throws -> MusicCatalogDetail { throw MusicCatalogError.unavailable }
    func page(_ query: MusicCatalogQuery, next: URL?) async throws -> MusicPage<MusicCatalogRow> { .init(items: [], next: nil, total: 0) }
    func homePage(_ query: MusicHomeQuery, next: URL?) async throws -> MusicHomePage {
        let item = MusicCatalogItem(spotifyID: "song", kind: .track, name: "Recommended Song", subtitle: "", artworkURL: nil, availability: .available, service: .appleMusic)
        switch query {
        case .recommendations:
            return .init(groups: [.init(id: "new-music", title: "New Music for You", query: .recommendation("new-music"))])
        case .recommendation:
            return .init(items: [.init(id: "recommended", item: item, position: nil)])
        case .replay:
            return .init(replay: .init(year: "2024", sections: [.init(id: "songs", title: "Songs", items: [.init(id: "first", item: item, position: nil)],
                query: .replayView("2024", "top-songs"), next: cursor)]))
        case .replayView:
            lastCursor = next
            return .init(items: [.init(id: "second", item: item, position: nil)])
        default: return .init()
        }
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
