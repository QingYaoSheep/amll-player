import Foundation
import MusicKit

@MainActor
protocol AppleMusicRequesting: AnyObject {
    func send(_ request: URLRequest) async throws -> Data
}

/// Only this transport receives official MusicKit credentials. Discovery,
/// lyric providers, artwork requests and caches never receive these credentials.
@MainActor
final class AppleMusicAPI: AppleMusicRequesting {
    private var retryAfter: Date?

    func send(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, Self.allowed(url) else { throw MusicCatalogError.invalidResponse }
        if let retryAfter, retryAfter > Date() {
            throw MusicCatalogError.rateLimited(until: retryAfter)
        }
        try Task.checkCancellation()
        let response: MusicDataResponse
        do { response = try await MusicDataRequest(urlRequest: request).response() }
        catch is CancellationError { throw CancellationError() }
        catch {
            if MusicAuthorization.currentStatus != .authorized {
                throw MusicServiceError.musicPermissionDenied
            }
            if let e = error as? URLError, [.notConnectedToInternet, .timedOut, .networkConnectionLost].contains(e.code) {
                throw MusicCatalogError.offline
            }
            throw MusicServiceError.musicFailure(error.localizedDescription)
        }
        try Task.checkCancellation()
        do {
            let http = response.urlResponse
            switch http.statusCode {
            case 200 ..< 300: break
            case 401: throw MusicServiceError.musicConfiguration
            case 403: throw MusicCatalogError.forbidden
            case 404: throw MusicCatalogError.unavailable
            case 429:
                let seconds = min(3600, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30))
                let until = Date().addingTimeInterval(seconds)
                retryAfter = until
                throw MusicCatalogError.rateLimited(until: until)
            default: throw MusicCatalogError.invalidResponse
            }
        }
        guard response.data.count <= 8 * 1024 * 1024 else { throw MusicCatalogError.invalidResponse }
        return response.data
    }

    nonisolated static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "api.music.apple.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.fragment == nil && url.path.hasPrefix("/v1/") && !url.path.contains("..")
    }

    nonisolated static func request(_ path: String, parameters: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) throws -> URLRequest {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.music.apple.com"
        parts.path = path
        parts.queryItems = parameters.isEmpty ? nil : parameters
        guard let url = parts.url, allowed(url) else { throw MusicCatalogError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    nonisolated static func resourcePath(_ resource: MusicResourceID, storefront: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard resource.service == .appleMusic, !resource.rawValue.isEmpty,
              resource.rawValue.unicodeScalars.allSatisfy(allowed.contains), !resource.rawValue.contains(".."),
              storefront.count == 2, storefront.allSatisfy(\.isLetter) else { throw MusicCatalogError.invalidResponse }
        return resource.scope == .library
            ? "/v1/me/library/\(resource.kind.appleType)/\(resource.rawValue)"
            : "/v1/catalog/\(storefront)/\(resource.kind.appleType)/\(resource.rawValue)"
    }

    nonisolated static func next(_ value: String?, from url: URL) throws -> URL? {
        guard let value else { return nil }
        guard let next = URL(string: value, relativeTo: url)?.absoluteURL, allowed(next) else {
            throw MusicCatalogError.invalidResponse
        }
        return next
    }
}

extension MusicCatalogKind {
    var appleType: String {
        switch self {
        case .track: "songs"
        case .album: "albums"
        case .artist: "artists"
        case .playlist: "playlists"
        case .station: "stations"
        case .musicVideo: "music-videos"
        }
    }

    static func apple(_ type: String) -> Self? {
        allCases.first { $0.appleType == type.replacingOccurrences(of: "library-", with: "") }
    }
}
