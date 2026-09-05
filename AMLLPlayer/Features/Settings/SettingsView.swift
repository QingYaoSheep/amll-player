import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("settings.login") {
                NavigationLink {
                    SpotifyLoginView(model: model)
                } label: {
                    Label("settings.login.spotify", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("spotifyLoginLink")

                LabeledContent("settings.account") {
                    Text(model.sessionState.isAuthenticated
                        ? "settings.connected" : "settings.disconnected")
                }
            }

            Section("settings.playback") {
                Label("settings.spotifyOnly", systemImage: "dot.radiowaves.left.and.right")
                Text("settings.noLocalPlayback")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("lyrics.title") {
                NavigationLink("lyrics.settings") { LyricsSettingsView(coordinator: model.lyrics) }
            }

            Section("settings.about") {
                LabeledContent("settings.version", value: appVersion)
                Link(
                    "settings.sourceCode",
                    destination: URL(string: "https://github.com/QingYaoSheep/amll-player")!
                )
            }
        }
        .navigationTitle("tab.settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
