import XCTest

@testable import AMLLPlayer

@MainActor
final class AppModelSpotifyLoginTests: XCTestCase {
    func testNewClientIDStopsOldConnectionAndAuthorizesUsingNewEnvironment() async throws {
        let oldSession = LoginTestSession()
        let oldPlayback = LoginTestPlayback()
        let newSession = LoginTestSession()
        let newPlayback = LoginTestPlayback()
        let store = SpotifyClientIDStore(storage: MemorySpotifyDataStore())
        let model = AppModel(
            environment: environment(clientID: "old-client", session: oldSession, playback: oldPlayback),
            clientIDStore: store,
            environmentFactory: { configuration in
                AppEnvironment(
                    configuration: configuration,
                    diagnostics: DiagnosticsStore(),
                    spotifySession: newSession,
                    spotifyPlayback: newPlayback
                )
            }
        )
        model.handleScenePhase(.active)

        await model.authorizeInBrowser(clientID: " new-client ")

        XCTAssertEqual(oldPlayback.stopCount, 1)
        XCTAssertEqual(oldSession.logoutCount, 1)
        XCTAssertEqual(newSession.browserLoginCount, 1)
        XCTAssertEqual(oldSession.browserLoginCount, 0)
        XCTAssertEqual(newPlayback.foregroundCount, 1)
        XCTAssertEqual(model.environment.configuration.spotifyClientID, "new-client")
        XCTAssertEqual(try store.load(), "new-client")
        XCTAssertFalse(model.isBrowserLoginInProgress)
    }

    func testSameClientIDDoesNotReplaceConnection() throws {
        let session = LoginTestSession()
        let playback = LoginTestPlayback()
        let model = AppModel(
            environment: environment(clientID: "same-client", session: session, playback: playback),
            clientIDStore: SpotifyClientIDStore(storage: MemorySpotifyDataStore()),
            environmentFactory: { _ in
                XCTFail("The existing environment should be reused")
                return self.environment(clientID: "unexpected")
            }
        )

        try model.configureSpotify(clientID: " same-client ")

        XCTAssertEqual(playback.stopCount, 0)
        XCTAssertEqual(session.logoutCount, 0)
    }

    func testBlankClientIDDoesNotDisconnectExistingAccount() throws {
        let session = LoginTestSession()
        let playback = LoginTestPlayback()
        let model = AppModel(
            environment: environment(clientID: "existing-client", session: session, playback: playback),
            clientIDStore: SpotifyClientIDStore(storage: MemorySpotifyDataStore())
        )

        XCTAssertThrowsError(try model.configureSpotify(clientID: " \n"))
        XCTAssertEqual(playback.stopCount, 0)
        XCTAssertEqual(session.logoutCount, 0)
        XCTAssertEqual(model.environment.configuration.spotifyClientID, "existing-client")
    }

    private func environment(
        clientID: String,
        session: LoginTestSession = LoginTestSession(),
        playback: LoginTestPlayback = LoginTestPlayback()
    ) -> AppEnvironment {
        AppEnvironment(
            configuration: AppConfiguration(infoDictionary: ["SpotifyClientID": clientID]),
            diagnostics: DiagnosticsStore(),
            spotifySession: session,
            spotifyPlayback: playback
        )
    }
}

@MainActor
private final class LoginTestSession: SpotifySessionProviding {
    var currentState: SpotifySessionState = .signedOut
    let spotifyAppInstalled = false
    var browserLoginCount = 0
    var logoutCount = 0

    var sessionStates: AsyncStream<SpotifySessionState> {
        AsyncStream { $0.finish() }
    }

    func authorize() throws {}
    func authorizeInBrowser() async throws { browserLoginCount += 1 }
    func refreshIfNeeded() async throws {}
    func validAccessToken() async throws -> String { "test-token" }
    func handleRedirectURL(_ url: URL) -> Bool { false }
    func logout() { logoutCount += 1 }
}

@MainActor
private final class LoginTestPlayback: SpotifyPlaybackProviding {
    let appRemoteState: SpotifyAppRemoteState = .disconnected
    var stopCount = 0
    var foregroundCount = 0

    var playbackSnapshots: AsyncStream<PlaybackSnapshot> {
        AsyncStream { $0.finish() }
    }

    func start() {}
    func stop() { stopCount += 1 }
    func enterForeground() { foregroundCount += 1 }
    func enterBackground() {}
    func refresh() async throws {}
    func play() async throws {}
    func pause() async throws {}
    func seek(to position: TimeInterval) async throws {}
    func skipNext() async throws {}
    func skipPrevious() async throws {}
    func setVolume(percent: Int, on deviceID: String?) async throws {}
    func play(uri: String, on deviceID: String?) async throws {}
    func devices() async throws -> [PlaybackDevice] { [] }
    func transferPlayback(to deviceID: String) async throws {}
}
