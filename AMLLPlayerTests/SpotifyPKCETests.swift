import XCTest
@testable import AMLLPlayer

final class SpotifyPKCETests: XCTestCase {
    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        XCTAssertEqual(
            SpotifyPKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierIsURLSafeAndLongEnough() throws {
        let verifier = try SpotifyPKCE.verifier()

        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertNotNil(
            verifier.range(
                of: #"^[A-Za-z0-9_-]+$"#,
                options: .regularExpression
            )
        )
    }
}
