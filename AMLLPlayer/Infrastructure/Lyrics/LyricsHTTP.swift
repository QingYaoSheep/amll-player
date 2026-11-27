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
        let limit = 8_000_000
        let delegate = LyricsDataDelegate(limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                    delegate.start(session: session, request: request, continuation: continuation)
                }
            } onCancel: {
                delegate.cancel()
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as LyricsError { throw error }
        catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw LyricsError.transport
        }
    }

    static func allowed(_ host: String) -> Bool {
        ["amp-api.music.apple.com", "music.apple.com", "beta.music.apple.com", "u.y.qq.com", "c.y.qq.com", "music.163.com", "interface3.music.163.com"].contains(host)
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

private final class LyricsDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var redirects = 0
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false

    init(limit: Int) {
        self.limit = limit
    }

    func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<Data, Error>) {
        let shouldCancel = lock.withLock {
            self.session = session
            self.continuation = continuation
            let created = session.dataTask(with: request)
            self.task = created
            return cancelled
        }
        if shouldCancel {
            task?.cancel()
            finish(with: .failure(CancellationError()))
        } else {
            task?.resume()
        }
    }

    func cancel() {
        let currentTask = lock.withLock { () -> URLSessionDataTask? in
            cancelled = true
            return task
        }
        currentTask?.cancel()
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let original = task.originalRequest, LyricsHTTP.canFollowRedirect(from: original, to: request) else {
            completionHandler(nil); return
        }
        let allowed = lock.withLock {
            redirects += 1
            return redirects <= 3
        }
        completionHandler(allowed ? request : nil)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .failure(LyricsError.transport))
            return
        }
        guard (200 ... 299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(with: .failure(LyricsError.http(http.statusCode)))
            return
        }
        guard http.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel)
            finish(with: .failure(LyricsError.tooLarge))
            return
        }
        if http.expectedContentLength > 0 {
            lock.withLock { buffer.reserveCapacity(Int(http.expectedContentLength)) }
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            if buffer.count + data.count > limit {
                return true
            }
            buffer.append(data)
            return false
        }
        if overflow {
            dataTask.cancel()
            finish(with: .failure(LyricsError.tooLarge))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let urlError = error as? URLError
            let isCancelled = lock.withLock { cancelled } || urlError?.code == .cancelled
            finish(with: .failure(isCancelled ? CancellationError() : LyricsError.transport))
        } else {
            let data = lock.withLock { buffer }
            finish(with: .success(data))
        }
    }

    private func finish(with result: Result<Data, Error>) {
        let (cont, sess) = lock.withLock { () -> (CheckedContinuation<Data, Error>?, URLSession?) in
            let c = continuation
            let s = session
            continuation = nil
            session = nil
            task = nil
            return (c, s)
        }
        sess?.finishTasksAndInvalidate()
        switch result {
        case let .success(data): cont?.resume(returning: data)
        case let .failure(error): cont?.resume(throwing: error)
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

    static func form(_ url: String, fields: [String: String], headers: [String: String] = [:]) throws -> URLRequest {
        guard let url = URL(string: url) else { throw LyricsError.transport }
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { throw LyricsError.transport }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.allHTTPHeaderFields = headers
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
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
