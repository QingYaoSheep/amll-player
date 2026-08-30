import Foundation

enum SpotifySessionState: Equatable, Sendable {
    case signedOut
    case authorizing
    case authenticated(expiresAt: Date)
    case refreshing
    case failed(SpotifyServiceError)

    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
}

enum SpotifyAppRemoteState: Equatable, Sendable {
    case unavailable
    case disconnected
    case connecting
    case connected
    case failed
}
