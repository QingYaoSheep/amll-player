import Foundation

struct AppEnvironment: Sendable {
    let configuration: AppConfiguration
    let diagnostics: any DiagnosticsExporting

    static let live = AppEnvironment(
        configuration: AppConfiguration(bundle: .main),
        diagnostics: DiagnosticsStore()
    )
}
