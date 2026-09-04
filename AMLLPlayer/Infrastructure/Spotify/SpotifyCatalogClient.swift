import Foundation

actor SpotifyCatalogHTTPClient {
    private let session: URLSession
    private var retryNotBefore: Date?
    private var quotaExceeded = false

    init(session: URLSession = URLSession(configuration: .ephemeral, delegate: CatalogRedirectPolicy(), delegateQueue: nil)) {
        self.session = session
    }

    static func validatedURL(endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint, relativeTo: URL(string: "https://api.spotify.com/v1/")!)?.absoluteURL,
              url.scheme == "https", url.host == "api.spotify.com",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/v1/"), !url.path.contains("..")
        else { throw SpotifyCatalogError.invalidResponse }
        return url
    }

    func get(endpoint: String, token: String) async throws -> (Data, URL) {
        try Task.checkCancellation()
        if quotaExceeded { throw SpotifyCatalogError.quotaExceeded }
        if let retryNotBefore, Date() < retryNotBefore {
            throw SpotifyCatalogError.rateLimited(until: retryNotBefore)
        }
        let url = try Self.validatedURL(endpoint: endpoint)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw SpotifyCatalogError.invalidResponse }
            if let error = Self.error(status: response.statusCode, data: data,
                                      retryAfter: response.value(forHTTPHeaderField: "Retry-After")) {
                if case .quotaExceeded = error { quotaExceeded = true }
                if case let .rateLimited(until) = error { retryNotBefore = until }
                throw error
            }
            guard data.count <= 8 * 1_024 * 1_024 else { throw SpotifyCatalogError.invalidResponse }
            return (data, url)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw SpotifyCatalogError.offline
        }
    }

    static func error(status: Int, data: Data, retryAfter: String?, now: Date = Date()) -> SpotifyCatalogError? {
        guard !(200..<300).contains(status) else { return nil }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let reason = [error?["reason"], error?["code"], error?["message"], root?["error"]]
            .compactMap { $0 as? String }.joined(separator: " ").uppercased()
        if reason.contains("QUOTA_EXCEEDED") { return .quotaExceeded }
        switch status {
        case 401: return .signInRequired
        case 403: return .forbidden
        case 404: return .unavailable
        case 429:
            let seconds = retryAfter.flatMap(TimeInterval.init)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let date = retryAfter.flatMap(formatter.date(from:))
            let delay = seconds ?? date?.timeIntervalSince(now) ?? 30
            return .rateLimited(until: now.addingTimeInterval(delay.isFinite ? max(1, delay) : 30))
        default: return .invalidResponse
        }
    }
}

final class CatalogRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Catalog pagination is validated separately. Never redirect a bearer-authenticated request.
        completionHandler(nil)
    }
}

@MainActor
final class SpotifyCatalogClient: SpotifyCatalogProviding {
    private let session: any SpotifySessionProviding
    private var http: SpotifyCatalogHTTPClient
    private var generation = UUID()

    init(session: any SpotifySessionProviding, http: SpotifyCatalogHTTPClient = SpotifyCatalogHTTPClient()) {
        self.session = session
        self.http = http
    }

    func invalidate() {
        generation = UUID()
        http = SpotifyCatalogHTTPClient()
    }

    func profile() async throws -> SpotifyProfile {
        let (data, _) = try await request("me")
        return try SpotifyCatalogDecoder.profile(data)
    }

    func page(_ query: SpotifyCatalogQuery, next: URL?) async throws -> SpotifyPage<SpotifyCatalogRow> {
        let (data, url) = try await request(next?.absoluteString ?? query.endpoint)
        return try SpotifyCatalogDecoder.page(data, query: query, requestedURL: url)
    }

    func detail(kind: SpotifyCatalogKind, id: String) async throws -> SpotifyCatalogDetail {
        guard SpotifyCatalogDecoder.validID(id) else { throw SpotifyCatalogError.unavailable }
        let (data, _) = try await request("\(kind.rawValue)s/\(id)")
        return try SpotifyCatalogDecoder.detail(data, kind: kind)
    }

    private func request(_ endpoint: String) async throws -> (Data, URL) {
        let epoch = generation
        let client = http
        do {
            let token = try await session.validAccessToken()
            try check(epoch)
            let result: (Data, URL)
            do {
                result = try await client.get(endpoint: endpoint, token: token)
            } catch SpotifyCatalogError.signInRequired {
                try check(epoch)
                let currentToken = try await session.validAccessToken()
                if currentToken == token { try await session.refreshAfterUnauthorized() }
                try check(epoch)
                let refreshed = try await session.validAccessToken()
                try check(epoch)
                result = try await client.get(endpoint: endpoint, token: refreshed)
            }
            try check(epoch)
            return result
        } catch let error as SpotifyServiceError {
            switch error {
            case .offline: throw SpotifyCatalogError.offline
            default: throw SpotifyCatalogError.signInRequired
            }
        }
    }

    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
    }
}
