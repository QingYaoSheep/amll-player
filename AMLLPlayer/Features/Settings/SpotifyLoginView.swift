import SwiftUI

struct SpotifyLoginView: View {
    @Bindable var model: AppModel
    @State private var clientID: String
    @State private var showConfiguration: Bool
    @State private var needsRetry = false
    @State private var confirmClientChange = false
    @FocusState private var isEditingClientID: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, startsWithConfiguration: Bool = false) {
        self.model = model
        let configuredID = model.environment.configuration.spotifyClientID ?? ""
        _clientID = State(initialValue: configuredID)
        _showConfiguration = State(initialValue: startsWithConfiguration || SpotifyClientIDStore.normalized(configuredID) == nil)
    }

    var body: some View {
        SettingsPage {
            SettingsAccountHeader(
                service: .spotify, name: profile?.displayName, avatar: profile?.avatarURL,
                status: status, connected: model.sessionState.isAuthenticated
            )
            SettingsSection {
                if !isConnectedWithThisClient || model.isSpotifyLoginBusy {
                    Button(action: prepareSignIn) {
                        SettingsActionLabel(
                            title: model.isSpotifyLoginBusy ? "player.authorizing" : needsRetry ? "重试 Spotify 登录" : "登录 Spotify",
                            icon: "safari", busy: model.isSpotifyLoginBusy, style: .primary
                        )
                    }
                    .disabled(SpotifyClientIDStore.normalized(clientID) == nil || unavailable)
                    .accessibilityIdentifier("spotifyAuthorize")
                }

                if model.sessionState.isAuthenticated {
                    Button(role: .destructive) {
                        model.logout()
                        needsRetry = false
                    } label: {
                        SettingsActionLabel(title: "settings.logout", icon: "rectangle.portrait.and.arrow.right", style: .destructive)
                    }
                    .disabled(unavailable)
                    .accessibilityIdentifier("spotifySignOut")
                }
            }
            if model.environment.configuration.spotifyClientID != nil {
                Button {
                    isEditingClientID = false
                    if showConfiguration { clientID = model.environment.configuration.spotifyClientID ?? "" }
                    withAnimation(reduceMotion ? nil : MusicProductMotion.change) { showConfiguration.toggle() }
                } label: {
                    SettingsActionLabel(title: showConfiguration ? "收起配置" : "编辑 Spotify 配置", icon: "slider.horizontal.3")
                }
                .disabled(unavailable)
                .accessibilityIdentifier("spotifyAdvancedConfiguration")
            }
            if showConfiguration {
                configuration.transition(.opacity)
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("settings.login.spotify")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isConnectedWithThisClient) { _, connected in
            if connected { needsRetry = false }
        }
        .confirmationDialog("更换 Spotify Client ID？", isPresented: $confirmClientChange, titleVisibility: .visible) {
            Button("更换并登录", role: .destructive, action: signIn)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("更换后会断开当前 Spotify 账号，需要重新登录。")
        }
    }

    private var configuration: some View {
        SettingsSection("Spotify 配置") {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.clientID").font(.subheadline.weight(.semibold))
                TextField("settings.clientID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($isEditingClientID)
                    .onSubmit { isEditingClientID = false }
                    .accessibilityIdentifier("spotifyClientID")
                if SpotifyClientIDStore.normalized(clientID) == nil {
                    Text("从 Spotify 开发者后台复制 Client ID 到这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsSurface()
            configurationValue("回调地址", AppConfiguration.defaultRedirectURI.absoluteString)
            configurationValue("Bundle ID", Bundle.main.bundleIdentifier ?? "net.stevexmh.amllplayer")
            Link(destination: URL(string: "https://developer.spotify.com/dashboard")!) {
                SettingsActionLabel(title: "settings.login.dashboard", icon: "arrow.up.right")
            }
            Link(destination: URL(string: "https://developer.spotify.com/documentation/web-api/concepts/apps")!) {
                SettingsActionLabel(title: "settings.login.documentation", icon: "book")
            }
        }
        .disabled(unavailable)
    }

    private func configurationValue(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(value).font(.footnote.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
        }
        .settingsSurface()
    }

    private var profile: MusicProfile? {
        model.selectedMusicService == .spotify && model.sessionState.isAuthenticated ? model.catalog.profile : nil
    }

    private var status: String {
        if model.isSpotifyLoginBusy { return String(localized: "player.authorizing") }
        if needsRetry { return String(localized: "登录未完成") }
        return model.settingsConnectionStatus(.spotify)
    }

    private var unavailable: Bool { model.isSpotifyLoginBusy || model.isPerformingAction }

    private func prepareSignIn() {
        isEditingClientID = false
        if model.sessionState.isAuthenticated && !isConnectedWithThisClient {
            confirmClientChange = true
        } else {
            signIn()
        }
    }

    private func signIn() {
        guard !unavailable else { return }
        let submittedID = clientID
        needsRetry = false
        Task {
            await model.authorizeInBrowser(clientID: submittedID)
            needsRetry = !isConnectedWithThisClient
        }
    }

    private var isConnectedWithThisClient: Bool {
        model.sessionState.isAuthenticated
            && SpotifyClientIDStore.normalized(clientID) == model.environment.configuration.spotifyClientID
    }
}
