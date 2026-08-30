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
}
