import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.spotify") {
                    LabeledContent("settings.clientID") {
                        Text(configurationStatusKey)
                            .foregroundStyle(
                                model.environment.configuration.isSpotifyConfigured
                                    ? .green : .secondary
                            )
                    }

                    LabeledContent(
                        "settings.redirectURI",
                        value: model.environment.configuration.spotifyRedirectURI.absoluteString
                    )

                    LabeledContent("settings.account") {
                        Text(accountStatusKey)
                    }

                    if model.sessionState.isAuthenticated {
                        Button("settings.logout", role: .destructive) {
                            model.logout()
                        }
                    }
                }

                Section("settings.playback") {
                    Label("settings.spotifyOnly", systemImage: "dot.radiowaves.left.and.right")
                    Text("settings.noLocalPlayback")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("settings.about") {
                    LabeledContent("settings.version", value: appVersion)
                    Link(
                        "settings.sourceCode",
                        destination: URL(
                            string: "https://github.com/QingYaoSheep/amll-player"
                        )!
                    )
                }
            }
            .navigationTitle("tab.settings")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var configurationStatusKey: LocalizedStringKey {
        model.environment.configuration.isSpotifyConfigured
            ? "settings.configured" : "settings.notConfigured"
    }

    private var accountStatusKey: LocalizedStringKey {
        model.sessionState.isAuthenticated ? "settings.connected" : "settings.disconnected"
    }
}
