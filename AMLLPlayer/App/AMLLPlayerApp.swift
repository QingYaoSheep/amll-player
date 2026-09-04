import SwiftUI

@main
@MainActor
struct AMLLPlayerApp: App {
    @State private var model = Self.makeModel()

    private static func makeModel() -> AppModel {
        #if DEBUG
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
    }
}
