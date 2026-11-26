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
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(SpotifyClientIDStore.normalized(clientID) == nil || unavailable)
                    .accessibilityIdentifier("spotifyAuthorize")
                }

                if model.sessionState.isAuthenticated || model.environment.configuration.spotifyClientID != nil {
                    SettingsGroup {
                        if model.environment.configuration.spotifyClientID != nil {
                            Button {
                                isEditingClientID = false
                                if showConfiguration { clientID = model.environment.configuration.spotifyClientID ?? "" }
                                withAnimation(reduceMotion ? nil : SettingsMotion.disclosure) { showConfiguration.toggle() }
                            } label: {
                                SettingsRowLabel(
                                    title: showConfiguration ? "收起配置" : "编辑 Spotify 配置",
                                    icon: "slider.horizontal.3",
                                    iconColor: MusicServiceID.spotify.brandColor
                                )
                            }
                            .buttonStyle(SettingsRowButtonStyle())
                            .disabled(unavailable)
                            .accessibilityIdentifier("spotifyAdvancedConfiguration")
                        }

                        if model.environment.configuration.spotifyClientID != nil && model.sessionState.isAuthenticated {
                            SettingsDivider()
                        }

                        if model.sessionState.isAuthenticated {
                            Button(role: .destructive) {
                                model.logout()
                                needsRetry = false
                            } label: {
                                SettingsRowLabel(
                                    title: "settings.logout",
                                    icon: "rectangle.portrait.and.arrow.right",
                                    role: .destructive
                                )
                            }
                            .buttonStyle(SettingsRowButtonStyle())
                            .disabled(unavailable)
                            .accessibilityIdentifier("spotifySignOut")
                        }
                    }
                }
            }
            if showConfiguration {
                configuration
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .navigationTitle("settings.login.spotify")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isConnectedWithThisClient) { _, connected in
            if connected { needsRetry = false }
        }
        .alert("更换 Spotify Client ID？", isPresented: $confirmClientChange) {
            Button("更换并登录", role: .destructive, action: signIn)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("更换后会断开当前 Spotify 账号，需要重新登录。")
        }
    }

    private var configuration: some View {
        SettingsSection("Spotify 配置") {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.clientID")
                        .font(.subheadline.weight(.semibold))
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                SettingsDivider(inset: 16)

                SettingsInfoRow(
                    title: "回调地址",
                    value: AppConfiguration.defaultRedirectURI.absoluteString,
                    monospacedValue: true,
                    selectable: true
                )

                SettingsDivider(inset: 16)

                SettingsInfoRow(
                    title: "Bundle ID",
                    value: Bundle.main.bundleIdentifier ?? "net.stevexmh.amllplayer",
                    monospacedValue: true,
                    selectable: true
                )

                SettingsDivider()

                Link(destination: URL(string: "https://developer.spotify.com/dashboard")!) {
                    SettingsRowLabel(
                        title: "settings.login.dashboard",
                        icon: "arrow.up.right",
                        iconColor: MusicServiceID.spotify.brandColor,
                        navigates: true
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                SettingsDivider()

                Link(destination: URL(string: "https://developer.spotify.com/documentation/web-api/concepts/apps")!) {
                    SettingsRowLabel(
                        title: "settings.login.documentation",
                        icon: "book",
                        iconColor: .blue,
                        navigates: true
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
            }
        }
        .disabled(unavailable)
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
