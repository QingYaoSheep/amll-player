import XCTest

@testable import AMLLPlayer

final class SpotifyHTTPStatusMapperTests: XCTestCase {
    func testMapsAuthenticationAndPlaybackFailures() {
        XCTAssertEqual(
            SpotifyHTTPStatusMapper.error(statusCode: 401, retryAfter: nil),
            .tokenExpired
        )
        XCTAssertEqual(
            SpotifyHTTPStatusMapper.error(statusCode: 403, retryAfter: nil),
            .premiumRequired
        )
        XCTAssertEqual(
            SpotifyHTTPStatusMapper.error(statusCode: 404, retryAfter: nil),
            .noActiveDevice
        )
    }

    func testPreservesRetryAfterForRateLimit() {
        XCTAssertEqual(
            SpotifyHTTPStatusMapper.error(statusCode: 429, retryAfter: "7"),
            .rateLimited(retryAfter: 7)
        )
    }

    func testMapsUnknownStatusWithoutResponseBody() {
        XCTAssertEqual(
            SpotifyHTTPStatusMapper.error(statusCode: 500, retryAfter: nil),
            .invalidResponse(statusCode: 500)
        )
    }

    @MainActor
    func testPollingRefreshesAfterUnauthorizedOnTokenExpiredError() async throws {
        let session = PollingUnauthorizedSession()
        let coordinator = SpotifyPlaybackCoordinator(
            session: session,
            appRemote: IdleAppRemoteController(),
            webAPI: ExpiredWebAPI(),
            diagnostics: DiagnosticsStore(),
            pollInterval: .milliseconds(50)
        )
        coordinator.start()
        coordinator.enterForeground()
        defer { coordinator.stop() }

        for _ in 0 ..< 100 where session.unauthorizedRefreshes == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(session.unauthorizedRefreshes, 1)
    }
}

@MainActor
private final class PollingUnauthorizedSession: SpotifySessionProviding {
    var currentState: SpotifySessionState { .authenticated(expiresAt: .distantFuture) }
    var sessionStates: AsyncStream<SpotifySessionState> { AsyncStream { $0.yield(currentState) } }
    var spotifyAppInstalled: Bool { false }
    var unauthorizedRefreshes = 0

    func authorize() throws {}
    func authorizeInBrowser() async throws {}
    func refreshIfNeeded() async throws {}
    func refreshAfterUnauthorized() async throws { unauthorizedRefreshes += 1 }
    func validAccessToken() async throws -> String { "expired-token" }
    func handleRedirectURL(_ url: URL) -> Bool { false }
    func logout() {}
}

@MainActor
private final class IdleAppRemoteController: SpotifyAppRemoteControlling {
    var state: SpotifyAppRemoteState { .disconnected }
    var stateChanges: AsyncStream<SpotifyAppRemoteState> { AsyncStream { $0.finish() } }
    var playbackSnapshots: AsyncStream<PlaybackSnapshot> { AsyncStream { $0.finish() } }
    func connect(accessToken: String) {}
    func disconnect() {}
    func play() async throws {}
    func pause() async throws {}
    func seek(to position: TimeInterval) async throws {}
    func skipNext() async throws {}
    func skipPrevious() async throws {}
    func play(uri: String) async throws {}
}

private struct ExpiredWebAPI: SpotifyWebAPIProviding {
    func playback(accessToken: String) async throws -> PlaybackSnapshot { throw SpotifyServiceError.tokenExpired }
    func devices(accessToken: String) async throws -> [PlaybackDevice] { [] }
    func play(accessToken: String, deviceID: String?) async throws {}
    func pause(accessToken: String, deviceID: String?) async throws {}
    func seek(accessToken: String, position: TimeInterval, deviceID: String?) async throws {}
    func skipNext(accessToken: String, deviceID: String?) async throws {}
    func skipPrevious(accessToken: String, deviceID: String?) async throws {}
    func setVolume(accessToken: String, percent: Int, deviceID: String?) async throws {}
    func play(accessToken: String, uri: String, deviceID: String?) async throws {}
    func transferPlayback(accessToken: String, deviceID: String) async throws {}
}
