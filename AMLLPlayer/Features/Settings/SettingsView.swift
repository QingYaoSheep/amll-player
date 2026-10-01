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

                NavigationLink { NetEaseLoginView(model: model) } label: { Label("登录到网易云音乐", systemImage: "music.note.list") }
                .accessibilityIdentifier("neteaseLoginLink")

                MusicSourcePicker(model: model)

                LabeledContent("settings.account") {
                    Text(model.sessionState.isAuthenticated
                        ? "settings.connected" : "settings.disconnected")
                }
            }

            Section("settings.playback") {
                Label("Spotify、Apple Music 与网易云音乐", systemImage: "dot.radiowaves.left.and.right")
                Text("Spotify 控制已连接设备，Apple Music 跟随系统音乐 App，网易云在 AMLL 内播放。切走网易云会暂停并保存队列，切回后手动继续播放。")
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
