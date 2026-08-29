import SwiftUI

struct SettingsView: View {
    let configuration: AppConfiguration

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.spotify") {
                    LabeledContent("settings.clientID") {
                        Text(configurationStatusKey)
                        .foregroundStyle(
                            configuration.isSpotifyConfigured ? .green : .secondary
                        )
                    }

                    LabeledContent(
                        "settings.redirectURI",
                        value: configuration.spotifyRedirectURI.absoluteString
                    )
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
        configuration.isSpotifyConfigured ? "settings.configured" : "settings.notConfigured"
    }
}
