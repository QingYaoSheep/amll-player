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
                TextField("settings.clientID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($isEditingClientID)
                    .onSubmit { isEditingClientID = false }
                    .disabled(model.isSpotifyLoginBusy)
                    .accessibilityIdentifier("spotifyClientID")

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
                Text("settings.clientID")
            } footer: {
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
