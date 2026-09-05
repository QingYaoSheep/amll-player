@testable import AMLLPlayer
import XCTest

@MainActor
final class LyricsProviderTests: XCTestCase {
    private let track = TrackIdentity(spotifyID: "s", title: "Title", artists: ["Artist"], duration: 10)
    private func credentials() -> AppleLyricsCredentials {
        AppleLyricsCredentials(manual: LyricsTestSecret(), media: LyricsTestSecret(), automatic: LyricsTestSecret())
    }

    private func token(issuer: String = "AMPWebPlay", expiration: Double = Date().timeIntervalSince1970 + 7200) throws -> String {
        func encode(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try encode(["kid": issuer == "AMPWebPlay" ? "WebPlayKid" : "other", "alg": "ES256"]) + "." + encode(["iss": issuer, "exp": expiration, "root_https_origin": "https://untrusted.example"]) + ".signaturefixture"
    }

    func testBearerClaimsChecksDoNotTrustOriginOrExpiredToken() throws {
        let info = try AppleBearerInfo(token())
        XCTAssertEqual(info.origin, "https://music.apple.com"); XCTAssertTrue(info.isWebPlay)
        XCTAssertThrowsError(try AppleBearerInfo(token(expiration: 1)))
        XCTAssertNil(try AppleLyricsProvider.extractBearer(token(issuer: "unrelated")))
        XCTAssertNotNil(try AppleLyricsProvider.extractBearer("bundle token: " + token()))
    }

    func testCredentialDeletionInvalidatesLateAutomaticDiscovery() throws {
        let credentials = credentials(), generation = credentials.generation
        try credentials.clearAll()
        XCTAssertThrowsError(try credentials.saveAutomatic(AppleBearerInfo(token()), generation: generation))
        XCTAssertThrowsError(try credentials.saveMedia("bad;injected=value"))
    }

    func testQQSearchFallsBackToLegacyEndpoint() async throws {
        let http = try LyricsHTTPFixture([
            .failure(.http(500)), .success(json(["code": 0, "data": ["song": ["list": [["songmid": "mid", "songid": 1, "songname": "Title", "singer": [["name": "Artist"]], "interval": 10]]]]])),
        ])
        let result = try await QQLyricsProvider(http: http).search(track: track, query: "", settings: LyricsSettings())
        XCTAssertEqual(result.first?.sourceID, "mid"); XCTAssertEqual(result.first?.score, 100)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requests.last?.url?.host, "c.y.qq.com")
    }

    func testQQLyricsBase64AndFallbackRemainLinePrecision() async throws {
        let raw = Data("[00:01]你好".utf8).base64EncodedString()
        let http = try LyricsHTTPFixture([.success(json(["req_0": ["data": ["lrc": ""]]])), .success(json(["code": 0, "lyric": raw]))])
        let candidate = LyricCandidate(source: .qq, sourceID: "mid", title: "Title", artists: [])
        let payload = try await QQLyricsProvider(http: http).lyrics(candidate: candidate, settings: LyricsSettings())
        let document = try payload.parse(candidate: candidate, duration: 10)
        XCTAssertEqual(document.lines.first?.text, "你好"); XCTAssertEqual(document.precision, .line)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testNetEaseInstrumentalAndNoLyricsAreDifferent() async throws {
        let candidate = LyricCandidate(source: .netease, sourceID: "1", title: "Title", artists: [])
        let http = try LyricsHTTPFixture([.success(json(["code": 200, "nolyric": true])), .success(json(["code": 200]))])
        let provider = NetEaseLyricsProvider(http: http)
        let payload = try await provider.lyrics(candidate: candidate, settings: LyricsSettings())
        XCTAssertTrue(payload.isInstrumental)
        do { _ = try await provider.lyrics(candidate: candidate, settings: LyricsSettings()); XCTFail("Expected not found") }
        catch { XCTAssertEqual(error as? LyricsError, .notFound) }
    }

    func testApple401SeparatesAccountAndLyricPermission() async throws {
        let credentials = credentials(); try credentials.saveManual(token()); try credentials.saveMedia("test-user-token")
        let http = try LyricsHTTPFixture([.failure(.http(401)), .success(json([:])), .success(json([:]))])
        let provider = AppleLyricsProvider(http: http, credentials: credentials)
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [])
        do { _ = try await provider.lyrics(candidate: candidate, settings: LyricsSettings()); XCTFail("Expected permission") }
        catch { XCTAssertEqual(error as? LyricsError, .permission) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotNil(requests[2].value(forHTTPHeaderField: "Media-User-Token"))
    }

    func testAppleLocalizationsPreferTranslationAndRememberReason() async throws {
        let credentials = credentials(); try credentials.saveManual(token()); try credentials.saveMedia("fixture-user")
        let plain = #"<tt><body><p begin="1s" end="2s">Main</p></body></tt>"#
        let localized = #"<tt xmlns:m="urn:metadata"><body><p begin="1s" end="2s">Main<span m:role="x-translation">翻译</span></p></body></tt>"#
        let http = try LyricsHTTPFixture([.success(json(["data": [["attributes": ["ttml": plain, "ttmlLocalizations": ["zh-Hans-CN": localized]]]]]))])
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [])
        let payload = try await AppleLyricsProvider(http: http, credentials: credentials).lyrics(candidate: candidate, settings: LyricsSettings())
        XCTAssertTrue(payload.selectionReason.contains("ttmlLocalizations")); XCTAssertEqual(payload.language, "zh-Hans-CN")
        XCTAssertEqual(try payload.parse(candidate: candidate, duration: 10).lines.first?.translation, "翻译")
    }

    func testAppleLyricsRetriesAfterRejectedAutomaticBearerIsReplaced() async throws {
        let credentials = credentials()
        try credentials.saveMedia("fixture-user")
        try credentials.saveAutomatic(AppleBearerInfo(token()), generation: credentials.generation)
        let xml = #"<tt><body><p begin="1s" end="2s">Recovered</p></body></tt>"#
        let html = try Data(("<html>" + token(expiration: Date().timeIntervalSince1970 + 8000) + "</html>").utf8)
        let http = try LyricsHTTPFixture([.failure(.http(401)), .failure(.http(401)), .success(html),
                                          .success(json(["data": [["attributes": ["ttml": xml]]]]))])
        let provider = AppleLyricsProvider(http: http, credentials: credentials)
        var settings = LyricsSettings(); settings.language = "en"
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [])
        let result = try await provider.lyrics(candidate: candidate, settings: settings)
        XCTAssertEqual(try result.parse(candidate: candidate, duration: 10).lines.first?.text, "Recovered")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testRequestQueryEscapingAndHostAllowlist() throws {
        let request = try LyricsRequest.make("https://music.163.com/api/search/get/web", query: ["s": "A&B #你好"])
        XCTAssertEqual(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "A&B #你好")
        XCTAssertFalse(LyricsHTTP.allowed("music.apple.com.evil.example")); XCTAssertTrue(LyricsHTTP.allowed("music.apple.com"))
        let page = try LyricsRequest.make("https://music.apple.com/us/browse")
        let next = try LyricsRequest.make("https://music.apple.com/us/new")
        XCTAssertTrue(LyricsHTTP.canFollowRedirect(from: page, to: next))
        var authenticated = page; authenticated.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(LyricsHTTP.canFollowRedirect(from: authenticated, to: next))
        XCTAssertFalse(try LyricsHTTP.canFollowRedirect(from: page, to: LyricsRequest.make("https://untrusted.example/")))
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
}

private actor LyricsHTTPFixture: LyricsHTTPProviding {
    var results: [Result<Data, LyricsError>]
    private(set) var requests: [URLRequest] = []
    init(_ results: [Result<Data, LyricsError>]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> Data {
        requests.append(request)
        guard !results.isEmpty else { throw LyricsError.transport }
        return try results.removeFirst().get()
    }
}

private final class LyricsTestSecret: SpotifySessionDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() throws -> Data? {
        lock.withLock { data }
    }

    func save(_ value: Data) throws {
        lock.withLock { data = value }
    }

    func remove() throws {
        lock.withLock { data = nil }
    }
}
