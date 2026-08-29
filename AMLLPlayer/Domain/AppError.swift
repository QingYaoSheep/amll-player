import Foundation

enum AppError: Error, Equatable, LocalizedError, Sendable {
    case missingSpotifyConfiguration
    case invalidSpotifyRedirectURI
    case unavailable(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .missingSpotifyConfiguration:
            String(localized: "error.spotifyConfigurationMissing")
        case .invalidSpotifyRedirectURI:
            String(localized: "error.spotifyRedirectInvalid")
        case let .unavailable(reason):
            reason
        case let .underlying(message):
            message
        }
    }
}
