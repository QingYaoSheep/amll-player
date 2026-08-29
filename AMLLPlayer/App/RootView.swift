import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedSection) {
            FoundationStatusView(state: model.foundationState)
                .tabItem {
                    Label("tab.foundation", systemImage: "checkmark.shield")
                }
                .tag(AppSection.foundation)

            SettingsView(configuration: model.environment.configuration)
                .tabItem {
                    Label("tab.settings", systemImage: "gearshape")
                }
                .tag(AppSection.settings)
        }
        .task {
            model.prepare()
        }
    }
}

#Preview {
    RootView(
        model: AppModel(
            environment: AppEnvironment(
                configuration: .preview,
                diagnostics: DiagnosticsStore()
            )
        )
    )
}
