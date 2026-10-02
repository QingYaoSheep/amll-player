import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                NavigationLink { MusicAccountsView(model: model) } label: {
                    SettingsItem(title: "账号与音乐来源", subtitle: model.selectedMusicService.title + " · " + model.connectionSummary(model.selectedMusicService), symbol: "person.crop.circle", color: .red)
                }.accessibilityIdentifier("musicAccountsLink")
                NavigationLink { MusicPlaybackSettingsView(model: model) } label: {
                    SettingsItem(title: "播放", subtitle: "音质、设备与播放方式", symbol: "play.fill", color: .pink)
                }
            }
            Section {
                NavigationLink { LyricsAppearanceView(preferences: model.renderPreferences, coordinator: model.lyrics) } label: {
                    SettingsItem(title: "歌词与外观", subtitle: "字号、背景与显示效果", symbol: "textformat.size", color: .purple)
                }
                NavigationLink { LyricsSettingsView(coordinator: model.lyrics) } label: {
                    SettingsItem(title: "歌词来源与匹配", subtitle: "来源顺序、匹配与时间偏移", symbol: "quote.bubble", color: .indigo)
                }
                NavigationLink { MusicStorageView(model: model) } label: {
                    SettingsItem(title: "存储与缓存", subtitle: "管理歌词、封面与音译缓存", symbol: "internaldrive", color: .orange)
                }
            }
            Section {
                NavigationLink { MusicHelpView(model: model) } label: {
                    SettingsItem(title: "帮助与故障排查", subtitle: "使用说明与连接检查", symbol: "questionmark.circle", color: .blue)
                }
                NavigationLink { MusicAboutView() } label: {
                    SettingsItem(title: "关于 AMLL", subtitle: "版本、更新记录与开源许可", symbol: "info.circle", color: .gray)
                }
            }
        }
        .navigationTitle("tab.settings")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct SettingsItem: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(color, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(.vertical, 4).frame(minHeight: 44)
    }
}

struct MusicAccountsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("当前音乐来源") {
                MusicSourcePicker(model: model)
                Text("切换来源后浏览对应内容。切走网易云会暂停，切回后手动继续播放。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("连接音乐服务") {
                ForEach(MusicServiceID.allCases) { service in
                    NavigationLink { MusicLoginDestination(model: model, service: service) } label: {
                        SettingsItem(title: service.title, subtitle: model.connectionSummary(service),
                            symbol: service == .spotify ? "dot.radiowaves.left.and.right" : "music.note",
                            color: service == .spotify ? .green : .red)
                    }
                    .accessibilityIdentifier(service.rawValue + "LoginLink")
                }
            }
        }.navigationTitle("账号与音乐来源")
    }
}

struct MusicPlaybackSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("播放方式") {
                Text(model.selectedMusicService.title).font(.headline)
                Text(MusicWelcomeView.explanation(model.selectedMusicService)).foregroundStyle(.secondary)
            }
            if model.selectedMusicService == .netease {
                Section("音质") {
                    Picker("请求音质", selection: Binding(get: { model.netEasePlayback.quality }, set: { model.netEasePlayback.quality = $0 })) {
                        ForEach(NetEaseQuality.allCases) { quality in Text(quality.title).tag(quality) }
                    }
                    Text("从下一首生效。实际音质取决于账号权限和设备解码能力。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("播放设备") {
                NavigationLink("选择播放设备") { DevicePickerView(model: model) }
                    .disabled(!model.currentServiceConnected)
            }
        }.navigationTitle("播放")
    }
}

struct MusicStorageView: View {
    @Bindable var model: AppModel
    @State private var artworkBytes: Int64 = 0
    @State private var romanBytes: Int64 = 0
    @State private var imageBytes: Int64 = 0
    @State private var lyricsBytes: Int64?
    @State private var clearing: String?
    @State private var failure: String?
    var body: some View {
        Form {
            Section("缓存占用") {
                LabeledContent("歌词缓存", value: lyricsBytes.map(format) ?? "暂不可统计")
                LabeledContent("动态封面", value: format(artworkBytes))
                LabeledContent("生成音译", value: format(romanBytes))
                LabeledContent("浏览封面（内存）", value: format(imageBytes))
            }
            Section {
                Button("清理歌词缓存", role: .destructive) { clearing = "lyrics" }
                Button("清理动态封面缓存", role: .destructive) { clearing = "artwork" }
                Button("清理生成音译缓存", role: .destructive) { clearing = "roman" }
                Button("清理浏览封面缓存", role: .destructive) { clearing = "images" }
            } footer: {
                Text("仅删除可重新获取的内容。保留登录、歌单、读音纠错、人工匹配和逐曲偏移；正在显示的内容可能保留至下次加载。")
            }
            if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
        }
        .navigationTitle("存储与缓存")
        .task { await refresh() }
        .confirmationDialog("清理所选缓存？", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            Button("清理缓存", role: .destructive) {
                let target = clearing; clearing = nil
                Task {
                    do {
                        switch target {
                        case "lyrics": model.lyrics.clearCache()
                        case "artwork": ArtworkMediaCache.shared.clear()
                        case "roman": try await LyricsRomanizationEngine.shared.clearGeneratedCache()
                        case "images": CatalogImageCache.shared.clear()
                        default: break
                        }
                        await refresh()
                    } catch { failure = error.localizedDescription }
                }
            }
        }
    }
    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func refresh() async {
        artworkBytes = ArtworkMediaCache.shared.byteCount
        imageBytes = Int64(CatalogImageCache.shared.byteCount)
        lyricsBytes = model.lyrics.cachedByteCount
        romanBytes = (try? await LyricsRomanizationEngine.shared.generatedCacheByteCount()) ?? 0
    }
}

struct MusicHelpView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("开始使用") {
                Text("先连接音乐来源，再浏览歌单或搜索歌曲。开始播放后，点击底部播放器打开歌词。")
                ForEach(MusicServiceID.allCases) { service in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(service.title).font(.headline)
                        Text(MusicWelcomeView.explanation(service)).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            Section("连接与故障排查") {
                NavigationLink("管理音乐来源") { MusicAccountsView(model: model) }
                NavigationLink("Apple Music 连接诊断") { AppleMusicDiagnosticsView(model: model) }
                NavigationLink("Spotify 配置帮助") { SpotifyLoginView(model: model) }
                NavigationLink("歌词获取与匹配") { LyricsSettingsView(coordinator: model.lyrics) }
                Text("连接失败时先检查网络，再返回服务页面重新检查。技术详情可展开查看；诊断不要包含 Cookie、令牌或临时播放地址。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #if DEBUG
            Section("开发工具") { NavigationLink("render.debug") { LyricsRenderPreview() } }
            #endif
        }.navigationTitle("帮助与故障排查")
    }
}

struct MusicAboutView: View {
    private let root = "https://github.com/QingYaoSheep/amll-player"
    var body: some View {
        Form {
            Section {
                Label("AMLL", systemImage: "music.note").font(.title2.bold())
                Text("发现音乐，跟随歌词。").foregroundStyle(.secondary)
                LabeledContent("settings.version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            Section("开源") {
                Link("更新记录", destination: URL(string: root + "/blob/swiftui-native/Docs/CHANGELOG.md")!)
                Link("settings.sourceCode", destination: URL(string: root)!)
                Link("开源许可与来源归属", destination: URL(string: root + "/blob/swiftui-native/THIRD_PARTY_NOTICES.md")!)
            }
        }.navigationTitle("关于 AMLL")
    }
}
