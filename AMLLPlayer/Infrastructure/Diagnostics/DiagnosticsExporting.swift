import Foundation

protocol DiagnosticsExporting: Sendable {
    func record(category: String, message: String) async
    func exportDiagnostics() async throws -> URL
}
