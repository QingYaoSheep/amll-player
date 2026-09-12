import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false
    @Namespace private var playerNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesTabAccessory: Bool {
        if #available(iOS 26.0, *) {
            return model.catalog.active
        }
        return false
    }

    var body: some View {
        Group {
            if model.catalog.active {
                SpotifyBrowserView(model: model, playerNamespace: playerNamespace, openPlayer: { showingPlayer = true })
                    .id(model.catalog.identity)
            } else {
                NavigationStack { SpotifyPlayerView(model: model) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if !usesTabAccessory, let snapshot = model.playbackSnapshot,
               snapshot.item != nil,
               model.sessionState.isAuthenticated
            {
                MiniPlayerBar(model: model, snapshot: snapshot, openPlayer: { showingPlayer = true })
                    .matchedTransitionSource(id: "nowPlaying", in: playerNamespace)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            player
                .modifier(PlayerZoomTransition(namespace: playerNamespace, enabled: !reduceMotion))
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
                set: {
                    if !$0 {
                        model.presentedError = nil
                    }
                }
            ),
            presenting: model.presentedError
        ) { _ in
            Button("common.ok", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }

    @ViewBuilder private var player: some View {
        if model.renderPreferences.profile == .amll {
            AMLLLyricsPlayer(model: model, usesSystemZoom: !reduceMotion)
        } else {
            FullscreenLyricsPlayer(model: model)
        }
    }
}

#Preview {
    RootView(model: AppModel(environment: .make(configuration: .preview)))
}
