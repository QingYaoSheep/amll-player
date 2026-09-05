import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false

    var body: some View {
        Group {
            if model.catalog.active {
                SpotifyBrowserView(model: model)
                    .id(model.catalog.identity)
            } else {
                NavigationStack { SpotifyPlayerView(model: model) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if let snapshot = model.playbackSnapshot,
               snapshot.item != nil,
               model.sessionState.isAuthenticated
            {
                MiniPlayerBar(model: model, snapshot: snapshot, openPlayer: { showingPlayer = true })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            if model.renderPreferences.profile == .appleMusic26 {
                AppleMusicLyricsPlayer(model: model)
            } else {
                FullscreenLyricsPlayer(model: model)
            }
        }
        .onChange(of: model.catalog.identity) { showingPlayer = false }
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
