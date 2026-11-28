import XCTest

@testable import AMLLPlayer

final class DiagnosticsStoreTests: XCTestCase {
    func testRedactsAuthorizationAndTokenValues() {
        let source = "Authorization: Bearer sensitive-value access_token=another-value code_verifier=pkce-secret"
        let redacted = DiagnosticsStore.redact(source)

        XCTAssertFalse(redacted.contains("sensitive-value"))
        XCTAssertFalse(redacted.contains("another-value"))
        XCTAssertFalse(redacted.contains("pkce-secret"))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    func testExportContainsOnlyRedactedEvent() async throws {
        let store = DiagnosticsStore()
        await store.record(category: "spotify", message: "client_id=sensitive-value")

        let exportURL = try await store.exportDiagnostics()
        let contents = try String(contentsOf: exportURL, encoding: .utf8)

        XCTAssertFalse(contents.contains("sensitive-value"))
        XCTAssertTrue(contents.contains("<redacted>"))
    }

    func testRedactsCookiesAndAppleMusicUserTokens() async throws {
        let source = "Cookie: MUSIC_U=secret-cookie; MUSIC_A=secret-a\nSet-Cookie: MUSIC_U=another-secret; Path=/\nMedia-User-Token: am-secret-token"
        let redacted = DiagnosticsStore.redact(source)

        XCTAssertFalse(redacted.contains("secret-cookie"))
        XCTAssertFalse(redacted.contains("secret-a"))
        XCTAssertFalse(redacted.contains("another-secret"))
        XCTAssertFalse(redacted.contains("am-secret-token"))
        XCTAssertTrue(redacted.contains("<redacted>"))

        let store = DiagnosticsStore()
        await store.record(category: "auth", message: "Media-User-Token=am-token-123")
        let firstURL = try await store.exportDiagnostics()
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        let secondURL = try await store.exportDiagnostics()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        try? FileManager.default.removeItem(at: secondURL)
    }
}
