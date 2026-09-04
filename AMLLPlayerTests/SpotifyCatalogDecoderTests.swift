import XCTest

@testable import AMLLPlayer

final class SpotifyCatalogDecoderTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }
    private let url = URL(string: "https://api.spotify.com/v1/playlists/list1/items?offset=20")!

    func testPlaylistNewAndLegacyFieldsPreserveOriginalOffsetsAndDuplicates() throws {
        let page = try SpotifyCatalogDecoder.page(data("""
            {"offset":20,"total":25,"next":null,"items":[
              {"item":{"id":"a","type":"track","name":"A"}},
              null,
              {"item":null},
              {"track":{"id":"a","type":"track","name":"A"}},
              {"item":{"id":"episode1","type":"episode","name":"Podcast"}}
            ]}
            """), query: .playlistItems("list1"), requestedURL: url)
        XCTAssertEqual(page.items.map(\.position), [20, 23, 24])
        XCTAssertEqual(Set(page.items.map(\.id)).count, 3)
        XCTAssertEqual(page.items.last?.item.availability, .unsupported)
        XCTAssertFalse(try XCTUnwrap(page.items.last).item.canPlay)
    }

    func testRecentDeduplicatesAndSkipsNullTracks() throws {
        let page = try SpotifyCatalogDecoder.page(data("""
            {"items":[{"track":{"id":"a","type":"track"}},
            {"track":null},{"track":{"id":"a","type":"track"}}],
            "next":"https://api.spotify.com/v1/me/player/recently-played?before=123"}
            """), query: .collection(.recent), requestedURL: url)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.next?.query, "before=123")
    }

    func testArtistCursorAndSavedAlbumsDecode() throws {
        let artists = try SpotifyCatalogDecoder.page(data("""
            {"artists":{"items":[{"id":"artist1","type":"artist","name":"Artist"}],
            "cursors":{"after":"artist1"},"next":"https://api.spotify.com/v1/me/following?after=artist1"}}
            """), query: .collection(.followedArtists), requestedURL: url)
        XCTAssertEqual(artists.items.first?.item.kind, .artist)
        XCTAssertEqual(artists.next?.query, "after=artist1")
        let albums = try SpotifyCatalogDecoder.page(data("""
            {"items":[{"album":{"id":"album1","type":"album","name":"Album"}}]}
            """), query: .collection(.savedAlbums), requestedURL: url)
        XCTAssertEqual(albums.items.first?.item.kind, .album)
    }

    func testMetadataOnlyPlaylistDoesNotInventTracks() throws {
        let detail = try SpotifyCatalogDecoder.detail(data("""
            {"id":"list1","type":"playlist","name":"Private","items":{"total":50}}
            """), kind: .playlist)
        XCTAssertEqual(detail.availability, .metadataOnly)
        XCTAssertNil(detail.children)
        XCTAssertEqual(detail.item.playlist?.total, 50)
    }

    func testReadableEmptyPlaylistIsNotMetadataOnly() throws {
        let detail = try SpotifyCatalogDecoder.detail(data("""
            {"id":"list1","type":"playlist","items":{"total":0,"items":[]}}
            """), kind: .playlist)
        XCTAssertEqual(detail.availability, .available)
        XCTAssertEqual(detail.children, .playlistItems("list1"))
    }

    func testRestrictedAndLocalMusicCannotBePlayed() throws {
        let page = try SpotifyCatalogDecoder.page(data("""
            {"tracks":{"items":[
              {"id":"a","type":"track","restrictions":{"reason":"market"}},
              {"id":"b","type":"track","is_local":true},
              {"id":"c","type":"track","is_playable":false}
            ]}}
            """), query: .search("test", .track), requestedURL: url)
        XCTAssertEqual(page.items.map(\.item.availability), [.restricted, .unsupported, .restricted])
        XCTAssertTrue(page.items.allSatisfy { !$0.item.canPlay })
    }

    func testTrackMetadataContainsNavigableAlbumAndArtistsWithoutOptionalFields() throws {
        let detail = try SpotifyCatalogDecoder.detail(data("""
            {"id":"track1","type":"track","name":"Song","duration_ms":123456,
             "artists":[{"id":"artist1","name":"Singer"}],
             "album":{"id":"album1","name":"Album","images":[{"url":"https://i.scdn.co/image/test"}]},
             "external_ids":{"isrc":"TEST123"}}
            """), kind: .track)
        XCTAssertEqual(detail.item.track?.album?.id, "album1")
        XCTAssertEqual(detail.item.track?.isrc, "TEST123")
        XCTAssertEqual(detail.item.artists.first?.name, "Singer")
        XCTAssertNotNil(detail.item.artworkURL)
        XCTAssertTrue(detail.item.canPlay)
    }

    func testProfilePrefersImmutableAccountIDAndToleratesLegacyID() throws {
        XCTAssertEqual(try SpotifyCatalogDecoder.profile(data(#"{"id":"current","account_id":"alternate"}"#)).accountID, "alternate")
        XCTAssertEqual(try SpotifyCatalogDecoder.profile(data(#"{"account_id":"alternate"}"#)).accountID, "alternate")
        XCTAssertEqual(try SpotifyCatalogDecoder.profile(data(#"{"id":"legacy"}"#)).accountID, "legacy")
        XCTAssertThrowsError(try SpotifyCatalogDecoder.profile(data(#"{}"#)))
    }

    func testMalformedPageIsNotPresentedAsAnEmptySuccess() {
        XCTAssertThrowsError(try SpotifyCatalogDecoder.page(data(#"{"error":"bad"}"#), query: .collection(.savedTracks), requestedURL: url))
        XCTAssertThrowsError(try SpotifyCatalogDecoder.detail(data(#"{"id":"abc","type":"episode"}"#), kind: .track))
    }

    func testSearchQueryEncodingAndLimit() throws {
        let query = SpotifyCatalogQuery.search("中文 & # + ?", .playlist)
        let url = try SpotifyCatalogHTTPClient.validatedURL(endpoint: query.endpoint)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "中文 & # + ?")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "10")
    }

    func testNextURLCannotLeakBearerToAnotherOrigin() {
        for endpoint in ["https://evil.example/v1/me", "http://api.spotify.com/v1/me", "//evil.example/me",
                         "https://api.spotify.com:444/v1/me", "https://user@api.spotify.com/v1/me", "https://api.spotify.com/other"] {
            XCTAssertThrowsError(try SpotifyCatalogHTTPClient.validatedURL(endpoint: endpoint))
        }
    }

    func testQuotaAndCatalog403AreNotMappedToPremiumPlaybackErrors() {
        XCTAssertEqual(SpotifyCatalogHTTPClient.error(status: 403, data: data(#"{"error":{"reason":"QUOTA_EXCEEDED"}}"#), retryAfter: nil), .quotaExceeded)
        XCTAssertEqual(SpotifyCatalogHTTPClient.error(status: 403, data: Data(), retryAfter: nil), .forbidden)
        XCTAssertEqual(SpotifyCatalogHTTPClient.error(status: 404, data: Data(), retryAfter: nil), .unavailable)
        XCTAssertFalse(SpotifyCatalogError.quotaExceeded.allowsRetry)
    }

    func testRetryAfterSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(SpotifyCatalogHTTPClient.error(status: 429, data: Data(), retryAfter: "45", now: now), .rateLimited(until: now.addingTimeInterval(45)))
        XCTAssertEqual(SpotifyCatalogHTTPClient.error(status: 429, data: Data(), retryAfter: "Thu, 01 Jan 1970 00:01:00 GMT", now: now), .rateLimited(until: now.addingTimeInterval(60)))
    }

    func testContextPlayBodyUsesOriginalOffsetAndCorrectWireKeys() throws {
        let body = try SpotifyContextPlaybackBody(uri: "spotify:playlist:list1", position: 23)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(object["context_uri"] as? String, "spotify:playlist:list1")
        XCTAssertEqual((object["offset"] as? [String: Int])?["position"], 23)
        XCTAssertNil(object["uris"])
        XCTAssertThrowsError(try SpotifyContextPlaybackBody(uri: "spotify:track:a", position: 0))
        XCTAssertThrowsError(try SpotifyContextPlaybackBody(uri: "spotify:album:a", position: -1))
    }
}
