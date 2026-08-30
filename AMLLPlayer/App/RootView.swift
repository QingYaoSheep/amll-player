import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSettings = false

    var body: some View {
        SpotifyPlayerView(model: model) {
            isShowingSettings = true
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if let snapshot = model.playbackSnapshot,
               snapshot.item != nil,
               model.sessionState.isAuthenticated
            {
                MiniPlayerBar(model: model, snapshot: snapshot)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model)
        }
        .task {
            model.prepare()
            model.handleScenePhase(scenePhase)
        }
        .onChange(of: scenePhase) { _, newValue in
            model.handleScenePhase(newValue)
        }
        .onOpenURL { url in
            model.handleOpenURL(url)
        }
        .alert(
            "error.title",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            ),
            presenting: model.presentedError
        ) { _ in
            Button("common.ok", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }
}

#Preview {
    RootView(model: AppModel(environment: .make(configuration: .preview)))
}
