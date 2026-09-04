import XCTest

@testable import AMLLPlayer

final class AppConfigurationTests: XCTestCase {
    func testUsesConfiguredClientIDAndRedirectURI() {
        let configuration = AppConfiguration(
            infoDictionary: [
                "SpotifyClientID": "client-for-test",
                "SpotifyRedirectURI": "amllplayer://spotify-callback",
            ]
        )

        XCTAssertTrue(configuration.isSpotifyConfigured)
        XCTAssertEqual(
            configuration.spotifyRedirectURI.absoluteString,
            "amllplayer://spotify-callback"
        )
    }

    func testMissingClientIDIsNotConfigured() {
        let configuration = AppConfiguration(infoDictionary: [:])

        XCTAssertFalse(configuration.isSpotifyConfigured)
        XCTAssertEqual(
            configuration.spotifyRedirectURI,
            AppConfiguration.defaultRedirectURI
        )
    }

    func testRejectsRedirectURIThatDoesNotMatchRegisteredCallback() {
        let configuration = AppConfiguration(
            infoDictionary: [
                "SpotifyClientID": "client-for-test",
                "SpotifyRedirectURI": "other-app://callback",
            ]
        )

        XCTAssertFalse(configuration.isSpotifyConfigured)
        XCTAssertEqual(configuration.spotifyConfigurationError, .invalidRedirectURI)
    }

    func testTruncatedXcconfigURLIsNotReportedAsMissingClientID() {
        let configuration = AppConfiguration(
            infoDictionary: [
                "SpotifyClientID": "runtime-client",
                "SpotifyRedirectURI": "amllplayer:",
            ]
        )

        XCTAssertFalse(configuration.isSpotifyConfigured)
        XCTAssertEqual(configuration.spotifyConfigurationError, .invalidRedirectURI)
    }

    func testBuiltApplicationHasCompleteSpotifyCallback() {
        // Read the processed host-app plist, not a hand-written test dictionary.
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "SpotifyRedirectURI") as? String,
            AppConfiguration.defaultRedirectURI.absoluteString
        )
        let configuration = AppConfiguration(bundle: .main)
            .overridingSpotifyClientID("runtime-client")

        XCTAssertTrue(configuration.isSpotifyConfigured)
        XCTAssertNil(configuration.spotifyConfigurationError)
    }
}
