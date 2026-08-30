import Foundation

enum SpotifyServiceError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured
    case notAuthorized
    case noActiveDevice
    case restrictedDevice
    case noPlayback
    case premiumRequired
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case tokenExpired
    case appRemoteUnavailable
    case invalidResponse(statusCode: Int)
    case transport

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "error.spotifyConfigurationMissing")
        case .notAuthorized:
            String(localized: "error.spotifyNotAuthorized")
        case .noActiveDevice:
            String(localized: "error.spotifyNoActiveDevice")
        case .restrictedDevice:
            String(localized: "error.spotifyRestrictedDevice")
        case .noPlayback:
            String(localized: "error.spotifyNoPlayback")
        case .premiumRequired:
            String(localized: "error.spotifyPremiumRequired")
        case .rateLimited:
            String(localized: "error.spotifyRateLimited")
        case .offline:
            String(localized: "error.offline")
        case .tokenExpired:
            String(localized: "error.spotifyTokenExpired")
        case .appRemoteUnavailable:
            String(localized: "error.spotifyAppRemoteUnavailable")
        case .invalidResponse:
            String(localized: "error.spotifyInvalidResponse")
        case .transport:
            String(localized: "error.spotifyTransport")
        }
    }
}
