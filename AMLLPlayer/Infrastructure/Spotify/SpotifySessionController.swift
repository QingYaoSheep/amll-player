@preconcurrency import SpotifyiOS
import UIKit

@MainActor
final class SpotifySessionController: NSObject, SpotifySessionProviding {
    private static let refreshLeeway: TimeInterval = 120

    private let sessionManager: SPTSessionManager
    private let store: any SpotifySessionDataStoring
    private let webStore: any SpotifySessionDataStoring
    private let webAuthorization: SpotifyWebAuthorizationController
    private let diagnostics: any DiagnosticsExporting
    private var stateContinuations: [
        UUID: AsyncStream<SpotifySessionState>.Continuation
    ] = [:]
    private var renewalContinuation: CheckedContinuation<Void, Error>?
    private var webToken: SpotifyWebToken?
    private var webRefreshTask: Task<SpotifyWebToken, Error>?

    private(set) var currentState: SpotifySessionState = .signedOut {
        didSet {
            stateContinuations.values.forEach { $0.yield(currentState) }
        }
    }

    var spotifyAppInstalled: Bool {
        webToken == nil && sessionManager.isSpotifyAppInstalled
    }

    var sessionStates: AsyncStream<SpotifySessionState> {
        let identifier = UUID()
        return AsyncStream { continuation in
            continuation.yield(currentState)
            stateContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.stateContinuations[identifier] = nil
                }
            }
        }
    }

    init(
        clientID: String,
        redirectURI: URL,
        store: any SpotifySessionDataStoring = KeychainSpotifySessionStore(),
        webStore: any SpotifySessionDataStoring = KeychainSpotifySessionStore(
            account: "web-session"
        ),
        diagnostics: any DiagnosticsExporting
    ) {
        let configuration = SPTConfiguration(
            clientID: clientID,
            redirectURL: redirectURI
        )
        configuration.playURI = ""
        self.sessionManager = SPTSessionManager(
            configuration: configuration,
            delegate: nil
        )
        self.store = store
        self.webStore = webStore
        self.webAuthorization = SpotifyWebAuthorizationController(
            clientID: clientID,
            redirectURI: redirectURI
        )
        self.diagnostics = diagnostics
        super.init()
        sessionManager.delegate = self
        restoreSession()
    }

    func authorize() throws {
        guard !currentState.isAuthenticated else {
            return
        }

        clearWebSession()
        currentState = .authorizing
        sessionManager.initiateSession(
            with: Self.requestedScopes,
            options: .default,
            campaign: nil
        )
        record("Authorization started")
    }

    func authorizeInBrowser() async throws {
        guard !currentState.isAuthenticated else {
            return
        }

        currentState = .authorizing
        record("Browser authorization started")
        do {
            let token = try await webAuthorization.authorize()
            accept(token)
        } catch is CancellationError {
            currentState = .signedOut
            record("Browser authorization cancelled")
            throw CancellationError()
        } catch let error as SpotifyServiceError {
            currentState = .failed(error)
            record("Browser authorization failed")
            throw error
        } catch {
            currentState = .failed(.transport)
            record("Browser authorization failed")
            throw SpotifyServiceError.transport
        }
    }

    func refreshIfNeeded() async throws {
        if let webToken {
            guard webToken.expiresAt.timeIntervalSinceNow <= Self.refreshLeeway else {
                return
            }
            try await refreshWebToken(webToken)
            return
        }

        guard let session = sessionManager.session else {
            throw SpotifyServiceError.notAuthorized
        }

        guard session.expirationDate.timeIntervalSinceNow <= Self.refreshLeeway else {
            return
        }

        if renewalContinuation != nil {
            while case .refreshing = currentState {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard currentState.isAuthenticated else {
                throw SpotifyServiceError.tokenExpired
            }
            return
        }

        currentState = .refreshing
        try await withCheckedThrowingContinuation { continuation in
            renewalContinuation = continuation
            sessionManager.renewSession()
        }
    }

    func validAccessToken() async throws -> String {
        try await refreshIfNeeded()
        if let webToken, webToken.expiresAt > Date() {
            return webToken.accessToken
        }
        guard let session = sessionManager.session,
              !session.isExpired
        else {
            throw SpotifyServiceError.tokenExpired
        }
        return session.accessToken
    }

    func handleRedirectURL(_ url: URL) -> Bool {
        sessionManager.application(UIApplication.shared, open: url)
    }

    func logout() {
        webAuthorization.cancel()
        webRefreshTask?.cancel()
        webRefreshTask = nil
        clearWebSession()
        sessionManager.session = nil
        try? store.remove()
        renewalContinuation?.resume(throwing: SpotifyServiceError.notAuthorized)
        renewalContinuation = nil
        currentState = .signedOut
        record("Session removed")
    }

    private func restoreSession() {
        do {
            if let data = try webStore.load(),
               let token = try? JSONDecoder().decode(SpotifyWebToken.self, from: data),
               token.expiresAt > Date() || token.isRefreshable
            {
                webToken = token
                currentState = .authenticated(expiresAt: token.expiresAt)
                record("Stored browser session restored")
                return
            }
            try? webStore.remove()

            guard let data = try store.load(),
                  let session = try NSKeyedUnarchiver.unarchivedObject(
                      ofClass: SPTSession.self,
                      from: data
                  )
            else {
                currentState = .signedOut
                return
            }

            sessionManager.session = session
            currentState = .authenticated(expiresAt: session.expirationDate)
            record("Stored session restored")
        } catch {
            try? store.remove()
            currentState = .signedOut
            record("Stored session was unreadable and removed")
        }
    }

    private func accept(_ session: SPTSession, renewed: Bool) {
        clearWebSession()
        sessionManager.session = session
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: session,
                requiringSecureCoding: true
            )
            try store.save(data)
        } catch {
            record("Session persistence failed")
        }

        currentState = .authenticated(expiresAt: session.expirationDate)
        renewalContinuation?.resume()
        renewalContinuation = nil
        record(renewed ? "Session renewed" : "Authorization completed")
    }

    private func accept(_ token: SpotifyWebToken) {
        sessionManager.session = nil
        try? store.remove()
        webToken = token
        do {
            try webStore.save(JSONEncoder().encode(token))
        } catch {
            record("Browser session persistence failed")
        }
        currentState = .authenticated(expiresAt: token.expiresAt)
        record("Browser authorization completed")
    }

    private func refreshWebToken(_ token: SpotifyWebToken) async throws {
        if let webRefreshTask {
            accept(try await webRefreshTask.value)
            return
        }

        currentState = .refreshing
        let task = Task { try await webAuthorization.refresh(token) }
        webRefreshTask = task
        defer { webRefreshTask = nil }

        do {
            accept(try await task.value)
            record("Browser session renewed")
        } catch is CancellationError {
            currentState = .failed(.tokenExpired)
            throw SpotifyServiceError.tokenExpired
        } catch let error as SpotifyServiceError {
            currentState = .failed(error)
            throw error
        } catch {
            currentState = .failed(.transport)
            throw SpotifyServiceError.transport
        }
    }

    private func clearWebSession() {
        webToken = nil
        try? webStore.remove()
    }

    private func record(_ message: String) {
        Task {
            await diagnostics.record(category: "spotify.session", message: message)
        }
    }

    private static let requestedScopes: SPTScope = [
        .appRemoteControl,
        .userReadPlaybackState,
        .userModifyPlaybackState,
        .userReadCurrentlyPlaying,
        .userReadRecentlyPlayed,
        .userLibraryRead,
        .playlistReadPrivate,
        .playlistReadCollaborative,
        .userFollowRead,
        .userTopRead,
        .userReadPrivate,
    ]
}

extension SpotifySessionController: @preconcurrency SPTSessionManagerDelegate {
    func sessionManager(
        manager: SPTSessionManager,
        didInitiate session: SPTSession
    ) {
        accept(session, renewed: false)
    }

    func sessionManager(
        manager: SPTSessionManager,
        didRenew session: SPTSession
    ) {
        accept(session, renewed: true)
    }

    func sessionManager(
        manager: SPTSessionManager,
        didFailWith error: Error
    ) {
        let mappedError: SpotifyServiceError = {
            if (error as NSError).code == NSURLErrorNotConnectedToInternet {
                return .offline
            }
            if renewalContinuation != nil {
                return .tokenExpired
            }
            return .transport
        }()

        renewalContinuation?.resume(throwing: mappedError)
        renewalContinuation = nil
        currentState = .failed(mappedError)
        record("Authorization or renewal failed")
    }
}
