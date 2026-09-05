import Foundation

protocol LyricsHTTPProviding: Sendable {
    func data(for request: URLRequest) async throws -> Data
}

private final class LyricsRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects: [Int: Int] = [:]
    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let original = task.originalRequest, LyricsHTTP.canFollowRedirect(from: original, to: request) else {
            completionHandler(nil); return
        }
        let count = lock.withLock {
            redirects[task.taskIdentifier, default: 0] += 1
            return redirects[task.taskIdentifier, default: 0]
        }
        completionHandler(count <= 3 ? request : nil)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError _: Error?) {
        _ = lock.withLock { redirects.removeValue(forKey: task.taskIdentifier) }
    }
}

actor LyricsHTTP: LyricsHTTPProviding {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: LyricsRedirectGuard(), delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> Data {
        guard let url = request.url, url.scheme == "https", Self.allowed(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw LyricsError.transport }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw LyricsError.transport }
            guard (200 ... 299).contains(response.statusCode) else { throw LyricsError.http(response.statusCode) }
            let limit = 8_000_000
            guard response.expectedContentLength <= limit else { throw LyricsError.tooLarge }
            var result = Data()
            for try await byte in bytes {
                if result.count % 4096 == 0 {
                    try Task.checkCancellation()
                }
                guard result.count < limit else { throw LyricsError.tooLarge }
                result.append(byte)
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as LyricsError { throw error }
        catch {
            if Task.isCancelled {
                throw CancellationError()
            }; throw LyricsError.transport
        }
    }

    static func allowed(_ host: String) -> Bool {
        ["amp-api.music.apple.com", "music.apple.com", "beta.music.apple.com", "u.y.qq.com", "c.y.qq.com", "music.163.com"].contains(host)
    }

    static func canFollowRedirect(from original: URLRequest, to request: URLRequest) -> Bool {
        let publicHosts = ["music.apple.com", "beta.music.apple.com"]
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              publicHosts.contains(original.url?.host ?? ""), publicHosts.contains(url.host ?? "") else { return false }
        // Both original and redirected headers must be credential-free, even if Foundation stripped a header.
        return [original, request].allSatisfy { value in
            ["Authorization", "Cookie", "Media-User-Token"].allSatisfy { value.value(forHTTPHeaderField: $0) == nil }
        }
    }
}

enum LyricsRequest {
    static func make(_ url: String, query: [String: String] = [:], headers: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: url) else { throw LyricsError.transport }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw LyricsError.transport }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsError.malformed }
        return object
    }

    static func id(_ value: Any?) -> String {
        (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
    }
}
