import SwiftUI

struct MusicWelcomeView: View {
    @Bindable var model: AppModel
    var complete: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "music.note").font(.system(size: 44)).foregroundStyle(MusicProductStyle.accent).accessibilityHidden(true)
                    Text("音乐与歌词，从这里开始").font(.largeTitle.bold())
                    Text("连接你使用的音乐服务，浏览喜欢的音乐，打开同步歌词。")
                        .font(.body).foregroundStyle(.secondary)
                    ForEach(MusicServiceID.allCases) { service in
                        NavigationLink {
                            MusicLoginDestination(model: model, service: service)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) { Button("完成", action: complete) }
                                }
                        } label: {
                            SettingsItem(title: service.title, subtitle: Self.explanation(service),
                                symbol: "music.note", color: service == .spotify ? .green : .red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { model.selectMusicService(service) })
                    }
                    Button("稍后设置", action: complete)
                        .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("skipMusicWelcome")
                }.padding(24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后设置", action: complete) } }
        }
        .tint(MusicProductStyle.accent)
        .interactiveDismissDisabled()
        .onChange(of: model.currentServiceConnected) { _, connected in if connected { complete() } }
    }
    static func explanation(_ service: MusicServiceID) -> String {
        switch service {
        case .spotify: "控制 Spotify 连接设备上的播放，同步歌曲和歌词。"
        case .appleMusic: "跟随系统音乐 App，同步当前歌曲与歌词。"
        case .netease: "在 AMLL 内播放，支持后台与锁屏控制。"
        }
    }
}
