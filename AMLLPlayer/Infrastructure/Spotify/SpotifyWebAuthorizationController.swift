@preconcurrency import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct SpotifyWebToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    var isRefreshable: Bool {
        refreshToken?.isEmpty == false
    }
}

enum SpotifyPKCE {
    static func verifier(byteCount: Int = 64) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SpotifyServiceError.transport
        }
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

@MainActor
final class SpotifyWebAuthorizationController: NSObject {
    private let clientID: String
    private let redirectURI: URL
    private let presentationContext = SpotifyWebPresentationContext()
    private var authenticationSession: ASWebAuthenticationSession?

    init(clientID: String, redirectURI: URL) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    func authorize() async throws -> SpotifyWebToken {
        let verifier = try SpotifyPKCE.verifier()
        let state = try SpotifyPKCE.verifier(byteCount: 32)
        let authorizationURL = try makeAuthorizationURL(
            challenge: SpotifyPKCE.challenge(for: verifier),
            state: state
        )
        let callbackURL = try await openAuthorizationPage(authorizationURL)
        let code = try authorizationCode(from: callbackURL, expectedState: state)
        return try await exchange(code: code, verifier: verifier)
    }

    func refresh(_ token: SpotifyWebToken) async throws -> SpotifyWebToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw SpotifyServiceError.tokenExpired
        }

        let response = try await requestToken(
            parameters: [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
            ]
        )
        return response.token(fallbackRefreshToken: refreshToken)
    }

    func cancel() {
        authenticationSession?.cancel()
        authenticationSession = nil
    }

    private func makeAuthorizationURL(challenge: String, state: String) throws -> URL {
        var components = URLComponents(
            string: "https://accounts.spotify.com/authorize"
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]
        guard let url = components?.url else {
            throw SpotifyServiceError.transport
        }
        return url
    }

    private func openAuthorizationPage(_ url: URL) async throws -> URL {
        guard let callbackScheme = redirectURI.scheme else {
            throw SpotifyServiceError.notConfigured
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.authenticationSession = nil
                    if let authenticationError = error as? ASWebAuthenticationSessionError,
                       authenticationError.code == .canceledLogin
                    {
                        continuation.resume(throwing: CancellationError())
                    } else if error != nil {
                        continuation.resume(throwing: SpotifyServiceError.transport)
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: SpotifyServiceError.transport)
                    }
                }
            }
            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                continuation.resume(throwing: SpotifyServiceError.transport)
                return
            }
        }
    }

    private func authorizationCode(
        from callbackURL: URL,
        expectedState: String
    ) throws -> String {
        guard callbackURL.scheme == redirectURI.scheme,
              callbackURL.host == redirectURI.host,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        else {
            throw SpotifyServiceError.transport
        }

        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        if values["error"] != nil {
            throw SpotifyServiceError.notAuthorized
        }
        guard values["state"] == expectedState,
              let code = values["code"],
              !code.isEmpty
        else {
            throw SpotifyServiceError.transport
        }
        return code
    }

    private func exchange(code: String, verifier: String) async throws -> SpotifyWebToken {
        let response = try await requestToken(
            parameters: [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "code_verifier", value: verifier),
            ]
        )
        return response.token(fallbackRefreshToken: nil)
    }

    private func requestToken(parameters: [URLQueryItem]) async throws -> TokenResponse {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyServiceError.transport
        }

        var components = URLComponents()
        components.queryItems = parameters
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyServiceError.transport
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw SpotifyServiceError.invalidResponse(statusCode: httpResponse.statusCode)
            }
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch let error as SpotifyServiceError {
            throw error
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw SpotifyServiceError.offline
        } catch {
            throw SpotifyServiceError.transport
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }

        func token(fallbackRefreshToken: String?) -> SpotifyWebToken {
            SpotifyWebToken(
                accessToken: accessToken,
                refreshToken: refreshToken ?? fallbackRefreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn)
            )
        }
    }

    private static let scopes = [
        "app-remote-control",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "user-read-recently-played",
        "user-library-read",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-follow-read",
        "user-top-read",
        "user-read-private",
    ]
}

@MainActor
private final class SpotifyWebPresentationContext: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
