import XCTest

@testable import AMLLPlayer

final class SpotifyCatalogHTTPTests: XCTestCase {
    private func client() -> SpotifyCatalogHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return SpotifyCatalogHTTPClient(session: URLSession(configuration: configuration))
    }

    func testQuotaStopsSubsequentHTTPRequests() async throws {
        let endpoint = "catalogTest" + UUID().uuidString
        let url = try SpotifyCatalogHTTPClient.validatedURL(endpoint: endpoint)
        CatalogURLProtocol.registry.install(url, responses: [
            .init(status: 429, json: #"{"error":{"reason":"QUOTA_EXCEEDED"}}"#)
        ])
        defer { CatalogURLProtocol.registry.remove(url) }
        let client = client()
        for _ in 0..<2 {
            do {
                _ = try await client.get(endpoint: endpoint, token: "fixture")
                XCTFail("Expected quota error")
            } catch let error as SpotifyCatalogError { XCTAssertEqual(error, .quotaExceeded) }
        }
        XCTAssertEqual(CatalogURLProtocol.registry.count(url), 1)
    }

    func testRetryAfterPreventsEarlyRequests() async throws {
        let endpoint = "catalogTest" + UUID().uuidString
        let url = try SpotifyCatalogHTTPClient.validatedURL(endpoint: endpoint)
        CatalogURLProtocol.registry.install(url, responses: [
            .init(status: 429, json: "{}", headers: ["Retry-After": "120"])
        ])
        defer { CatalogURLProtocol.registry.remove(url) }
        let client = client()
        for _ in 0..<2 {
            do {
                _ = try await client.get(endpoint: endpoint, token: "fixture")
                XCTFail("Expected rate limit")
            } catch let error as SpotifyCatalogError {
                guard case let .rateLimited(until) = error else { return XCTFail("Wrong error") }
                XCTAssertGreaterThan(until.timeIntervalSinceNow, 100)
            }
        }
        XCTAssertEqual(CatalogURLProtocol.registry.count(url), 1)
    }

    @MainActor
    func test401RefreshesOnceAndRetriesReadOnlyRequest() async throws {
        let url = URL(string: "https://api.spotify.com/v1/me")!
        CatalogURLProtocol.registry.install(url, responses: [
            .init(status: 401, json: "{}"),
            .init(status: 200, json: #"{"account_id":"testAccount","display_name":"Listener"}"#),
        ])
        defer { CatalogURLProtocol.registry.remove(url) }
        let session = CatalogHTTPSession()
        let provider = SpotifyCatalogClient(session: session, http: client())
        let profile = try await provider.profile()
        XCTAssertEqual(profile.accountID, "testAccount")
        XCTAssertEqual(session.refreshes, 1)
        XCTAssertEqual(CatalogURLProtocol.registry.count(url), 2)
        XCTAssertEqual(CatalogURLProtocol.registry.methods(url), ["GET", "GET"])
    }
}

private struct CatalogHTTPResponse: Sendable {
    let status: Int
    let json: String
    var headers: [String: String] = [:]
}

private final class CatalogHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: [CatalogHTTPResponse]] = [:]
    private var requests: [URL: [String]] = [:]

    func install(_ url: URL, responses: [CatalogHTTPResponse]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses[url] = responses
        requests[url] = []
    }
    func remove(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = nil
        requests[url] = nil
    }
    func take(_ request: URLRequest) -> CatalogHTTPResponse? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = request.url else { return nil }
        requests[url, default: []].append(request.httpMethod ?? "GET")
        guard responses[url]?.isEmpty == false else { return nil }
        return responses[url]?.removeFirst()
    }
    func count(_ url: URL) -> Int { methods(url).count }
    func methods(_ url: URL) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests[url] ?? []
    }
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = CatalogHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let stub = Self.registry.take(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class CatalogHTTPSession: SpotifySessionProviding {
    var currentState: SpotifySessionState { .authenticated(expiresAt: .distantFuture) }
    var sessionStates: AsyncStream<SpotifySessionState> { AsyncStream { $0.finish() } }
    var spotifyAppInstalled: Bool { false }
    var refreshes = 0
    func authorize() throws {}
    func authorizeInBrowser() async throws {}
    func refreshIfNeeded() async throws {}
    func refreshAfterUnauthorized() async throws { refreshes += 1 }
    func validAccessToken() async throws -> String { "fixture" }
    func handleRedirectURL(_ url: URL) -> Bool { false }
    func logout() {}
}
