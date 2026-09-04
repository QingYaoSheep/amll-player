import Foundation

struct AppConfiguration: Equatable, Sendable {
    static let defaultRedirectURI = URL(string: "amllplayer://spotify-callback")!

    let spotifyClientID: String?
    let spotifyRedirectURI: URL

    var isSpotifyConfigured: Bool {
        spotifyConfigurationError == nil
    }

    var spotifyConfigurationError: SpotifyServiceError? {
        guard let spotifyClientID,
              SpotifyClientIDStore.normalized(spotifyClientID) != nil
        else {
            return .notConfigured
        }
        guard spotifyRedirectURI == Self.defaultRedirectURI else {
            return .invalidRedirectURI
        }
        return nil
    }

    init(bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        let clientID = infoDictionary["SpotifyClientID"] as? String
        let redirectValue = infoDictionary["SpotifyRedirectURI"] as? String

        spotifyClientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        spotifyRedirectURI = redirectValue.flatMap(URL.init(string:)) ?? Self.defaultRedirectURI
    }

    func overridingSpotifyClientID(_ clientID: String?) -> AppConfiguration {
        guard let clientID = clientID.flatMap(SpotifyClientIDStore.normalized) else {
            return self
        }
        return AppConfiguration(
            infoDictionary: [
                "SpotifyClientID": clientID,
                "SpotifyRedirectURI": spotifyRedirectURI.absoluteString,
            ]
        )
    }

    static let preview = AppConfiguration(
        infoDictionary: [
            "SpotifyClientID": "preview-client",
            "SpotifyRedirectURI": "amllplayer://spotify-callback",
        ]
    )
}
