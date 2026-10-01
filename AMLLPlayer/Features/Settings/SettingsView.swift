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

                NavigationLink { AppleMusicLoginView(model: model) } label: {
                    Label("登录到 Apple Music", systemImage: "music.note")
                }
                .accessibilityIdentifier("appleMusicLoginLink")

                MusicSourcePicker(model: model)

                LabeledContent("settings.account") {
                    Text(model.sessionState.isAuthenticated
                        ? "settings.connected" : "settings.disconnected")
                }
            }

            Section("settings.playback") {
                Label("Spotify 与 Apple Music", systemImage: "dot.radiowaves.left.and.right")
                Text("Spotify 控制已连接设备，Apple Music 跟随系统音乐 App。切换来源不会自动播放、暂停或重建队列。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("lyrics.title") {
                NavigationLink { LyricsAppearanceView(preferences: model.renderPreferences, coordinator: model.lyrics) } label: {
                    Label("render.settings", systemImage: "textformat.size")
                }
                NavigationLink { LyricsSettingsView(coordinator: model.lyrics) } label: {
                    Label("lyrics.settings", systemImage: "music.note.list")
                }
                #if DEBUG
                    NavigationLink("render.debug") { LyricsRenderPreview() }
                #endif
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
