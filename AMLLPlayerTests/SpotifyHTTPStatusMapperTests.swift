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
}
