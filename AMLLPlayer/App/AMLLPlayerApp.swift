import SwiftUI

@main
@MainActor
struct AMLLPlayerApp: App {
    @State private var model = Self.makeModel()
    @Environment(\.scenePhase) private var appScenePhase

    private static func makeModel() -> AppModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--lyrics-ui-testing") {
            return CatalogUITestFixture.makeModel(includeLyrics: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--catalog-ui-testing") {
            return CatalogUITestFixture.makeModel()
        }
        #endif
        return AppModel(environment: .live)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .onChange(of: appScenePhase, initial: true) {
            // App-level phase aggregates all windows; one inactive iPad window
            // must not suspend a QR login in another active window.
            model.netEaseSession.setForeground(appScenePhase == .active)
        }
    }
}
