import Foundation

@MainActor
final class UnavailableSpotifySession: SpotifySessionProviding {
    let currentState: SpotifySessionState
    let spotifyAppInstalled = false
    private let error: SpotifyServiceError

    init(error: SpotifyServiceError = .notConfigured) {
        self.error = error
        currentState = .failed(error)
    }

    var sessionStates: AsyncStream<SpotifySessionState> {
        AsyncStream { continuation in
            continuation.yield(currentState)
            continuation.finish()
        }
    }

    func authorize() throws {
        throw error
    }

    func authorizeInBrowser() async throws {
        throw error
    }

    func refreshIfNeeded() async throws {
        throw error
    }

    func validAccessToken() async throws -> String {
        throw error
    }

    func handleRedirectURL(_ url: URL) -> Bool {
        false
    }

    func logout() {}
}

@MainActor
final class UnavailableSpotifyPlayback: SpotifyPlaybackProviding {
    let appRemoteState: SpotifyAppRemoteState = .unavailable

    var playbackSnapshots: AsyncStream<PlaybackSnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func start() {}
    func stop() {}
    func enterForeground() {}
    func enterBackground() {}
    func refresh() async throws { throw SpotifyServiceError.notConfigured }
    func play() async throws { throw SpotifyServiceError.notConfigured }
    func pause() async throws { throw SpotifyServiceError.notConfigured }
    func seek(to position: TimeInterval) async throws {
        throw SpotifyServiceError.notConfigured
    }
    func skipNext() async throws { throw SpotifyServiceError.notConfigured }
    func skipPrevious() async throws { throw SpotifyServiceError.notConfigured }
    func setVolume(percent: Int, on deviceID: String?) async throws {
        throw SpotifyServiceError.notConfigured
    }
    func play(uri: String, on deviceID: String?) async throws {
        throw SpotifyServiceError.notConfigured
    }
    func devices() async throws -> [PlaybackDevice] {
        throw SpotifyServiceError.notConfigured
    }
    func transferPlayback(to deviceID: String) async throws {
        throw SpotifyServiceError.notConfigured
    }
}
