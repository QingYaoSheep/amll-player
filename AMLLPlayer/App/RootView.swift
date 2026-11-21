import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    var roomNotification: NetEaseRoomNotificationDelegate.Response? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false
    @State private var showingWelcome = false
    @Namespace private var playerNamespace
    @State private var roomOverlay = NetEaseRoomOverlay()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            MusicBrowserView(model: model, playerNamespace: playerNamespace, openPlayer: { showingPlayer = true })
                .id(model.catalog.identity)
                .accessibilityHidden(showingPlayer)
        }
        .background { NetEaseRoomOverlayAnchor(overlay: roomOverlay, model: model) }
        .onChange(of: roomNotification, initial: true) {
            if let roomNotification { roomOverlay.open(roomNotification.destination, model: model) }
        }
        .sheet(isPresented: $showingWelcome) {
            MusicWelcomeView(model: model) {
                MusicWelcomePreferences().complete()
                showingWelcome = false
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            player
                .modifier(PlayerZoomTransition(namespace: playerNamespace, enabled: !reduceMotion))
        }
        .onChange(of: model.catalog.identity) { showingPlayer = false }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--welcome-ui-testing") { showingWelcome = true }
            else if ProcessInfo.processInfo.arguments.contains("--skip-welcome-ui-testing") { showingWelcome = false }
            else {
                showingWelcome = MusicWelcomePreferences().needsWelcome(
                    existingConnection: MusicServiceID.allCases.contains { model.isConnected(to: $0) },
                    savedSpotifyConfiguration: (try? SpotifyClientIDStore().load()) != nil)
            }
            #else
            showingWelcome = MusicWelcomePreferences().needsWelcome(
                existingConnection: MusicServiceID.allCases.contains { model.isConnected(to: $0) },
                savedSpotifyConfiguration: (try? SpotifyClientIDStore().load()) != nil)
            #endif
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
            FullscreenLyricsPlayer(model: model, usesSystemZoom: !reduceMotion)
        }
    }
}

#Preview {
    RootView(model: AppModel(environment: .make(configuration: .preview)))
}
