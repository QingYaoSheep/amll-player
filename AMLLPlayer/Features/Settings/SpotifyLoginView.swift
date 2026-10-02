import SwiftUI

struct SpotifyLoginView: View {
    @Bindable var model: AppModel
    @State private var clientID: String
    @FocusState private var isEditingClientID: Bool

    init(model: AppModel) {
        self.model = model
        _clientID = State(initialValue: model.environment.configuration.spotifyClientID ?? "")
    }

    var body: some View {
        Form {
            Section {
                Label(model.sessionState.isAuthenticated ? "已连接 Spotify" : "连接 Spotify", systemImage: "music.note")
                if SpotifyClientIDStore.normalized(clientID) == nil {
                    Text("此安装包需要先配置 Spotify Client ID，再登录你的账号。").font(.subheadline).foregroundStyle(.secondary)
                }
                NavigationLink("高级配置与连接帮助") {
                    Form {
                        Section("settings.clientID") {
                TextField("settings.clientID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($isEditingClientID)
                    .onSubmit { isEditingClientID = false }
                    .disabled(model.isSpotifyLoginBusy)
                    .accessibilityIdentifier("spotifyClientID")
                        }
                        Section("配置说明") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.login.saveHelp")
                    Text("settings.login.apiHelp")
                    Text(AppConfiguration.defaultRedirectURI.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Text("settings.login.bundleHelp")
                    Text(Bundle.main.bundleIdentifier ?? "net.stevexmh.amllplayer")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Text("settings.login.finishHelp")
                    Link(
                        "settings.login.dashboard",
                        destination: URL(string: "https://developer.spotify.com/dashboard")!
                    )
                    Link(
                        "settings.login.documentation",
                        destination: URL(
                            string: "https://developer.spotify.com/documentation/web-api/concepts/apps"
                        )!
                    )
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(nil)
                        }
                    }.navigationTitle("Spotify 配置")
                }.accessibilityIdentifier("spotifyAdvancedConfiguration")


                Button {
                    isEditingClientID = false
                    Task { await model.authorizeInBrowser(clientID: clientID) }
                } label: {
                    Label("settings.login.authorize", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    SpotifyClientIDStore.normalized(clientID) == nil
                        || model.isSpotifyLoginBusy || model.isPerformingAction
                        || isConnectedWithThisClient
                )
                .accessibilityIdentifier("spotifyAuthorize")

                if model.isSpotifyLoginBusy {
                    ProgressView("player.authorizing")
                } else if isConnectedWithThisClient {
                    Label("settings.connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if model.sessionState.isAuthenticated {
                    Button("settings.logout", role: .destructive) {
                        model.logout()
                    }
                    .disabled(model.isSpotifyLoginBusy || model.isPerformingAction)
                }
            } header: {
                Text("音乐账号")
            } footer: {
                Text("登录后控制 Spotify 设备上的播放。AMLL 不在本机播放 Spotify 音频。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.login.spotify")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }

    private var isConnectedWithThisClient: Bool {
        model.sessionState.isAuthenticated
            && SpotifyClientIDStore.normalized(clientID)
                == model.environment.configuration.spotifyClientID
    }
}
