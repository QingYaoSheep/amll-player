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
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try encode(["kid": issuer == "AMPWebPlay" ? "WebPlayKid" : "other", "alg": "ES256"]) + "." +
            encode(["iss": issuer, "exp": expiration, "root_https_origin": "https://untrusted.example"]) + ".signaturefixture"
    }

    private func appleLyrics(_ attributes: [String: Any], relationship: String = "syllable-lyrics") throws -> Data {
        try json(["data": [["relationships": [relationship: ["data": [["attributes": attributes]]]]]]])
    }

    func testBearerClaimsChecksDoNotTrustOriginOrExpiredToken() throws {
        let info = try AppleBearerInfo(token())
        XCTAssertEqual(info.origin, "https://music.apple.com")
        XCTAssertTrue(info.isWebPlay)
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

    func testQQSearchFallsBackToLegacyEndpointAndKeepsBothIDs() async throws {
        let http = try LyricsHTTPFixture([
            .failure(.http(500)),
            .success(json(["code": 0, "data": ["song": ["list": [["songmid": "mid", "songid": 1, "songname": "Title",
                                                                  "singer": [["name": "Artist"]], "interval": 10]]]]])),
        ])
        let result = try await QQLyricsProvider(http: http).search(track: track, query: "", settings: LyricsSettings())
        XCTAssertEqual(result.first?.sourceID, "mid")
        XCTAssertEqual(result.first?.numericID, "1")
        XCTAssertEqual(result.first?.score, 100)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
    }

    func testQQLyricDownloadReturnsEncryptedWordsTranslationAndRomanization() async throws {
        let encrypted = "c90db2e3f6940a43538b45865eb6753863c981f936a71a093b450246d48b65f09ea70dc2b1510075f51ddfb35bdd67a91b2353ae0e4225c227d0571074570c21"
        let translation = Data("[00:01]Translation".utf8).base64EncodedString()
        let romanization = Data("[00:01]hai".utf8).base64EncodedString()
        let xml = Data("<root><content>\(encrypted)</content><contentts>\(translation)</contentts><contentroma>\(romanization)</contentroma></root>".utf8)
        let http = LyricsHTTPFixture([.success(xml)])
        let candidate = LyricCandidate(source: .qq, sourceID: "mid", numericID: "1", title: "Title", artists: [], duration: 4)
        let bundle = try await QQLyricsProvider(http: http).lyrics(candidate: candidate, settings: LyricsSettings())
        let document = try bundle.parse(candidate: candidate, duration: 4)
        XCTAssertEqual(bundle.format, .qrc)
        XCTAssertEqual(document.precision, .word)
        XCTAssertEqual(document.lines.first?.text, "Hi")
        XCTAssertEqual(document.lines.first?.translation, "Translation")
        XCTAssertEqual(document.lines.first?.romanization, "hai")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/qqmusic/fcgi-bin/lyric_download.fcg")
        XCTAssertTrue(try String(data: XCTUnwrap(requests.first?.httpBody), encoding: .utf8)?.contains("musicid=1") == true)
    }

    func testQQModernRequestRetainsTranslationWhenNumericIDIsUnavailable() async throws {
        let translation = Data("[00:01.050]翻译".utf8).base64EncodedString()
        let http = try LyricsHTTPFixture([.success(json(["req_0": ["data": ["lyric": "[00:01]原文", "trans": translation, "roma": ""]]]))])
        let candidate = LyricCandidate(source: .qq, sourceID: "mid", title: "Title", artists: [])
        let bundle = try await QQLyricsProvider(http: http).lyrics(candidate: candidate, settings: LyricsSettings())
        let document = try bundle.parse(candidate: candidate, duration: 10)
        XCTAssertEqual(document.lines.first?.translation, "翻译")
        XCTAssertEqual(document.precision, .line)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testQQFallsBackToLegacyLRCWithoutInventingWordTimes() async throws {
        let raw = Data("[00:01]你好".utf8).base64EncodedString()
        let http = try LyricsHTTPFixture([.success(json(["req_0": ["data": ["lrc": ""]]])), .success(json(["code": 0, "lyric": raw]))])
        let candidate = LyricCandidate(source: .qq, sourceID: "mid", title: "Title", artists: [])
        let bundle = try await QQLyricsProvider(http: http).lyrics(candidate: candidate, settings: LyricsSettings())
        let document = try bundle.parse(candidate: candidate, duration: 10)
        XCTAssertEqual(document.lines.first?.text, "你好")
        XCTAssertEqual(document.precision, .line)
        XCTAssertNotNil(document.degradationReason)
    }

    func testNetEaseEAPIPrefersYRCAndMergesAuxiliaryLyrics() async throws {
        let response: [String: Any] = [
            "code": 200,
            "yrc": ["lyric": "[1000,2000](1000,500,0)你(1500,1500,0)好"],
            "lrc": ["lyric": "[00:01]你好"],
            "ytlrc": ["lyric": "[00:01.050]Hello"],
            "yromalrc": ["lyric": "[00:01]ni hao"],
        ]
        let http = try LyricsHTTPFixture([.success(json(response))])
        let candidate = LyricCandidate(source: .netease, sourceID: "1", title: "Title", artists: [], duration: 4)
        let bundle = try await NetEaseLyricsProvider(http: http).lyrics(candidate: candidate, settings: LyricsSettings())
        let document = try bundle.parse(candidate: candidate, duration: 4)
        XCTAssertEqual(bundle.format, .yrc)
        XCTAssertEqual(document.lines.first?.words.map(\.text), ["你", "好"])
        XCTAssertEqual(document.lines.first?.translation, "Hello")
        XCTAssertEqual(document.lines.first?.romanization, "ni hao")
        XCTAssertNil(document.degradationReason)
        let requests = await http.requests
        XCTAssertEqual(requests.first?.url?.host, "interface3.music.163.com")
    }

    func testNetEaseEAPIEncryptionMatchesReferenceVector() throws {
        let value: [String: Any] = ["csrf_token": "", "header": "{}", "id": "1"]
        XCTAssertEqual(
            try NeteaseEAPI.encryptedParameters(path: "/api/song/lyric/v1", object: value),
            "04AE33D34A93FE3EC22DA8FA305D290AB337D0FE5F36D211DE0D338CC6AA89D063E9A4704E7BD369DB3DB245775F35B5AA1F7F9120A9E1FA22276E15BA00061833690C2E3E7A44468E6EA0C12881905D00456445D7F35D6FAE8E3E3B97BEA095913F827D82A4C9FD4A16CA66FE61FCEB9AC2FE9CC43BCE455033953A2AC2DC65"
        )
    }

    func testNetEaseEAPIFailureFallsBackToLineLyricsWithReason() async throws {
        let http = try LyricsHTTPFixture([.failure(.http(500)), .success(json([
            "code": 200, "lrc": ["lyric": "[00:01]Line"], "tlyric": ["lyric": "[00:01]翻译"],
        ]))])
        let candidate = LyricCandidate(source: .netease, sourceID: "1", title: "Title", artists: [])
        let bundle = try await NetEaseLyricsProvider(http: http).lyrics(candidate: candidate, settings: LyricsSettings())
        let document = try bundle.parse(candidate: candidate, duration: 4)
        XCTAssertEqual(document.precision, .line)
        XCTAssertEqual(document.lines.first?.translation, "翻译")
        XCTAssertNotNil(document.degradationReason)
    }

    func testNetEaseInstrumentalAndUncollectedAreDifferent() async throws {
        let candidate = LyricCandidate(source: .netease, sourceID: "1", title: "Title", artists: [])
        let instrumental = try LyricsHTTPFixture([.success(json(["code": 200, "nolyric": true]))])
        let instrumentalBundle = try await NetEaseLyricsProvider(http: instrumental).lyrics(candidate: candidate, settings: LyricsSettings())
        XCTAssertTrue(instrumentalBundle.isInstrumental)
        let missing = try LyricsHTTPFixture([.success(json(["code": 200, "uncollected": true])), .success(json(["code": 200, "uncollected": true]))])
        do {
            _ = try await NetEaseLyricsProvider(http: missing).lyrics(candidate: candidate, settings: LyricsSettings())
            XCTFail("Expected not found")
        } catch {
            XCTAssertEqual(error as? LyricsError, .notFound)
        }
    }

    func testAppleUsesSongRelationshipWithoutAccountToken() async throws {
        let credentials = credentials()
        try credentials.saveManual(token())
        let xml = #"<tt><body><p begin="1s" end="2s"><span begin="1s" end="2s">Word</span></p></body></tt>"#
        let http = try LyricsHTTPFixture([.success(appleLyrics(["ttml": xml]))])
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [], duration: 4)
        let bundle = try await AppleLyricsProvider(http: http, credentials: credentials).lyrics(candidate: candidate, settings: LyricsSettings())
        XCTAssertEqual(try bundle.parse(candidate: candidate, duration: 4).precision, .word)
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/v1/catalog/us/songs/1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Media-User-Token"))
        let query = try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "include[songs]" }?.value, "syllable-lyrics")
    }

    func testAppleAccountTokenResolvesStorefrontAndLanguage() async throws {
        let credentials = credentials()
        try credentials.saveManual(token())
        try credentials.saveMedia("fixture-user")
        let context = try json(["data": [["id": "hk", "attributes": ["defaultLanguageTag": "zh-Hant-HK"]]]])
        let xml = #"<tt><body><p begin="1s" end="2s"><span begin="1s" end="2s">字</span></p></body></tt>"#
        let http = try LyricsHTTPFixture([.success(context), .success(appleLyrics(["ttml": xml]))])
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [], duration: 4)
        _ = try await AppleLyricsProvider(http: http, credentials: credentials).lyrics(candidate: candidate, settings: LyricsSettings())
        let requests = await http.requests
        XCTAssertEqual(requests.first?.url?.path, "/v1/me/storefront")
        XCTAssertEqual(requests.last?.url?.path, "/v1/catalog/hk/songs/1")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Media-User-Token"), "fixture-user")
    }

    func testAppleLocalizationsPreferTranslatedWordTTML() async throws {
        let credentials = credentials()
        try credentials.saveManual(token())
        let plain = #"<tt><body><p begin="1s" end="2s"><span begin="1s" end="2s">Main</span></p></body></tt>"#
        let localized = #"<tt xmlns:m="urn:metadata"><body><p begin="1s" end="2s"><span begin="1s" end="2s">Main</span><span m:role="x-translation">翻译</span></p></body></tt>"#
        let http = try LyricsHTTPFixture([.success(appleLyrics(["ttml": plain, "ttmlLocalizations": ["zh-Hans-CN": localized]]))])
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [], duration: 4)
        let bundle = try await AppleLyricsProvider(http: http, credentials: credentials).lyrics(candidate: candidate, settings: LyricsSettings())
        XCTAssertTrue(bundle.selectionReason.contains("ttmlLocalizations"))
        XCTAssertEqual(try bundle.parse(candidate: candidate, duration: 4).lines.first?.translation, "翻译")
    }

    func testAppleLyrics404RetriesWithoutLanguageAndReportsNotFound() async throws {
        let credentials = credentials()
        try credentials.saveManual(token())
        let http = LyricsHTTPFixture(Array(repeating: .failure(.http(404)), count: 5))
        let provider = AppleLyricsProvider(http: http, credentials: credentials)
        var settings = LyricsSettings()
        settings.language = "en-US"
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [])
        do {
            _ = try await provider.lyrics(candidate: candidate, settings: settings)
            XCTFail("Expected no timed lyrics")
        } catch {
            XCTAssertEqual(error as? LyricsError, .notFound)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertNotNil(try URLComponents(url: XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "l" })
        XCTAssertEqual(try URLComponents(url: XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "l" }?.value, "zh-Hans-CN")
        XCTAssertNil(try URLComponents(url: XCTUnwrap(requests[4].url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "l" })
    }

    func testAppleLyricsRetriesAfterRejectedAutomaticBearerIsReplaced() async throws {
        let credentials = credentials()
        try credentials.saveAutomatic(AppleBearerInfo(token()), generation: credentials.generation)
        let xml = #"<tt xmlns:m="urn:metadata"><body><p begin="1s" end="2s"><span begin="1s" end="2s">Recovered</span><span m:role="x-translation">恢复</span></p></body></tt>"#
        let html = try Data(("<html>" + token(expiration: Date().timeIntervalSince1970 + 8000) + "</html>").utf8)
        let http = try LyricsHTTPFixture([.failure(.http(401)), .failure(.http(401)), .success(html), .success(appleLyrics(["ttml": xml]))])
        let provider = AppleLyricsProvider(http: http, credentials: credentials)
        var settings = LyricsSettings()
        settings.language = "en"
        let candidate = LyricCandidate(source: .apple, sourceID: "1", title: "Title", artists: [], duration: 4)
        let result = try await provider.lyrics(candidate: candidate, settings: settings)
        XCTAssertEqual(try result.parse(candidate: candidate, duration: 4).lines.first?.text, "Recovered")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testRequestQueryEscapingFormEncodingAndHostAllowlist() throws {
        let request = try LyricsRequest.make("https://music.163.com/api/search/get/web", query: ["s": "A&B #你好"])
        XCTAssertEqual(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "A&B #你好")
        let form = try LyricsRequest.form("https://c.y.qq.com/test", fields: ["value": "A&B #你好"])
        XCTAssertEqual(try String(data: XCTUnwrap(form.httpBody), encoding: .utf8), "value=A%26B%20%23%E4%BD%A0%E5%A5%BD")
        XCTAssertTrue(LyricsHTTP.allowed("interface3.music.163.com"))
        XCTAssertFalse(LyricsHTTP.allowed("music.apple.com.evil.example"))
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
