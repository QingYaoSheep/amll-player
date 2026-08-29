import SwiftUI

@main
@MainActor
struct AMLLPlayerApp: App {
    @State private var model = AppModel(environment: .live)

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
