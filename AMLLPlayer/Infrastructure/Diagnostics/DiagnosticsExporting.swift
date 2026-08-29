import Foundation

protocol DiagnosticsExporting: Sendable {
    func exportDiagnostics() async throws -> URL
}
