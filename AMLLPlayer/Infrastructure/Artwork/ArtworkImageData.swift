import CryptoKit
import Foundation

enum ArtworkImageData {
    private static let maximumBytes = 20 * 1024 * 1024
    private static let coalescer = ArtworkDownloadCoalescer()

    static func load(_ url: URL) async throws -> Data {
        if url.isFileURL {
            return try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try Data(contentsOf: url)
            }.value
        }
        return try await coalescer.load(url, maximumBytes: maximumBytes)
    }
}

private actor ArtworkDownloadCoalescer {
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 40 * 1024 * 1024
        cache.countLimit = 80
        return cache
    }()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
    private var inFlight: [URL: Task<Data, Error>] = [:]

    deinit {
        session.finishTasksAndInvalidate()
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw URLError(.unsupportedURL)
        }
        let cacheKey = url.absoluteString as NSString
        if let hit = cache.object(forKey: cacheKey) {
            return hit as Data
        }
        if let existing = inFlight[url] {
            return try await existing.value
        }
        let session = self.session
        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard !data.isEmpty, data.count <= maximumBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            return data
        }
        inFlight[url] = task
        defer { inFlight.removeValue(forKey: url) }
        let data = try await task.value
        cache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return data
    }
}
