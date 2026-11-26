import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(AppHaptics.preferenceKey) private var hapticsEnabled = true
    @State private var exportingSettings = false
    @State private var showingSettingsExporter = false
    @State private var settingsDocument: AppSettingsDocument?
    @State private var settingsExportError: String?

    var body: some View {
        SettingsPage {
            NavigationLink {
                MusicAccountsView(model: model)
            } label: {
                SettingsAccountHeader(
                    service: model.selectedMusicService, name: accountName, avatar: accountAvatar,
                    status: model.settingsConnectionStatus(model.selectedMusicService), connected: model.currentServiceConnected,
                    action: model.currentServiceConnected ? "管理账号" : "连接账号"
                )
            }
            .accessibilityIdentifier("musicAccountsLink")

            SettingsSection("播放与歌词") {
                NavigationLink { MusicPlaybackSettingsView(model: model) } label: {
                    SettingsActionLabel(title: "播放", icon: "play.fill", navigates: true)
                }
                NavigationLink {
                    LyricsAppearanceView(preferences: model.renderPreferences, coordinator: model.lyrics)
                } label: {
                    SettingsActionLabel(title: "歌词与外观", icon: "textformat.size", navigates: true)
                }
                NavigationLink { LyricsSettingsView(coordinator: model.lyrics) } label: {
                    SettingsActionLabel(title: "歌词来源与匹配", icon: "quote.bubble", navigates: true)
                }
                Toggle(isOn: $hapticsEnabled.hapticSelection()) {
                    Label("settings.haptics", systemImage: "hand.tap")
                }
                .settingsSurface()
                .accessibilityIdentifier("appHapticsEnabled")
            }

            SettingsSection("存储") {
                NavigationLink { MusicStorageView(model: model) } label: {
                    SettingsActionLabel(title: "存储与缓存", icon: "internaldrive", navigates: true)
                }
                Button {
                    Task { await exportSettings() }
                } label: {
                    SettingsActionLabel(title: "导出所有设置", icon: "square.and.arrow.up", busy: exportingSettings)
                }
                .disabled(exportingSettings)
                .accessibilityIdentifier("exportAllSettings")
            }

            SettingsSection("支持") {
                NavigationLink { MusicHelpView(model: model) } label: {
                    SettingsActionLabel(title: "帮助与故障排查", icon: "questionmark.circle", navigates: true)
                }
                NavigationLink { MusicAboutView() } label: {
                    SettingsActionLabel(title: "关于 AMLL", icon: "info.circle", navigates: true)
                }
                DisclosureGroup("开发与调试") {
                    NavigationLink {
                        ImmersiveArtworkDebugPanel(
                            backgroundDimming: model.renderPreferences.configuration.validated().backgroundDimming ?? 0.16
                        )
                    } label: {
                        Label("沉浸封面层级调试（临时）", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
                .settingsSurface()
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("tab.settings")
        .navigationBarTitleDisplayMode(.large)
        .fileExporter(isPresented: $showingSettingsExporter, document: settingsDocument, contentType: .json,
                      defaultFilename: "AMLL-设置") { result in
            if case .failure(let error) = result { settingsExportError = error.localizedDescription }
        }
        .onChange(of: showingSettingsExporter) { _, showing in
            if !showing { settingsDocument = nil }
        }
        .alert("无法导出设置", isPresented: Binding(get: { settingsExportError != nil }, set: { showing in
            if !showing { settingsExportError = nil }
        })) {
            Button("好", role: .cancel) { settingsExportError = nil }
        } message: {
            Text(settingsExportError ?? "")
        }
    }

    private var accountName: String? {
        guard model.currentServiceConnected else { return nil }
        switch model.selectedMusicService {
        case .spotify: return model.catalog.profile?.displayName
        case .appleMusic: return nil
        case .netease: return model.netEaseSession.profile?.name
        }
    }

    private var accountAvatar: URL? {
        guard model.currentServiceConnected else { return nil }
        switch model.selectedMusicService {
        case .spotify: return model.catalog.profile?.avatarURL
        case .appleMusic: return nil
        case .netease: return model.netEaseSession.profile?.avatar
        }
    }

    private func exportSettings() async {
        guard !exportingSettings else { return }
        exportingSettings = true
        defer { exportingSettings = false }
        do {
            let overrides = try await LyricsRomanizationEngine.shared.exportOverrides()
            let snapshot = try AppSettingsExport(
                model: model, artwork: .shared,
                pronunciationOverrides: JSONDecoder().decode([String: [String: String]].self, from: overrides))
            settingsDocument = AppSettingsDocument(data: try snapshot.encoded())
            showingSettingsExporter = true
        } catch {
            settingsExportError = error.localizedDescription
        }
    }
}

struct MusicAccountsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsSection {
                MusicSourcePicker(model: model).settingsSurface()
            }
            SettingsSection("音乐账号") {
                ForEach(MusicServiceID.allCases) { service in
                    NavigationLink {
                        MusicLoginDestination(model: model, service: service)
                    } label: {
                        SettingsActionLabel(
                            title: LocalizedStringKey(service.title), icon: service.settingsIcon,
                            detail: model.settingsConnectionStatus(service), navigates: true
                        )
                    }
                    .accessibilityIdentifier(service.rawValue + "LoginLink")
                }
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("账号与音乐来源")
    }
}

struct MusicPlaybackSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsSection {
                LabeledContent("当前音乐来源", value: model.selectedMusicService.title).settingsSurface()
                if model.selectedMusicService == .netease {
                    NetEaseQualityPicker(model: model)
                }
                if model.currentServiceConnected {
                    NavigationLink { DevicePickerView(model: model).task { await model.loadDevices() } } label: {
                        SettingsActionLabel(title: "选择播放设备", icon: "airplayaudio", navigates: true)
                    }
                } else {
                    NavigationLink { MusicLoginDestination(model: model, service: model.selectedMusicService) } label: {
                        SettingsActionLabel(title: "连接账号", icon: "person.crop.circle", navigates: true)
                    }
                }
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("播放")
    }
}

struct NetEaseQualityPicker: View {
    @Bindable var model: AppModel
    @State private var showTiming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("播放音质", selection: Binding(get: { model.netEasePlayback.quality }, set: { quality in
                guard quality != model.netEasePlayback.quality else { return }
                model.netEasePlayback.quality = quality
                withAnimation(reduceMotion ? nil : MusicProductMotion.change) { showTiming = true }
            })) {
                ForEach(NetEaseQuality.allCases) { quality in Text(quality.title).tag(quality) }
            }
            .settingsPickerRow("播放音质")
            .settingsSurface()
            if showTiming {
                Text("新音质从下一首开始生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
    }
}

struct MusicStorageView: View {
    @Bindable var model: AppModel
    @State private var artworkBytes: Int64 = 0
    @State private var romanBytes: Int64 = 0
    @State private var imageBytes: Int64 = 0
    @State private var lyricsBytes: Int64?
    @State private var clearing: Cache?
    @State private var isClearing = false
    @State private var failure: String?

    private enum Cache: String, CaseIterable, Identifiable {
        case lyrics, artwork, roman, images
        var id: Self { self }

        var name: LocalizedStringKey {
            switch self {
            case .lyrics: "歌词缓存"
            case .artwork: "动态封面缓存"
            case .roman: "生成音译缓存"
            case .images: "浏览封面缓存"
            }
        }

        var clearTitle: LocalizedStringKey {
            switch self {
            case .lyrics: "清理歌词缓存"
            case .artwork: "清理动态封面缓存"
            case .roman: "清理生成音译缓存"
            case .images: "清理浏览封面缓存"
            }
        }
    }

    var body: some View {
        SettingsPage {
            SettingsSection("缓存占用") {
                ForEach(Cache.allCases) { cache in
                    LabeledContent(cache.name, value: size(of: cache)).settingsSurface()
                }
            }
            SettingsSection {
                ForEach(Cache.allCases) { cache in
                    Button(role: .destructive) { clearing = cache } label: {
                        SettingsActionLabel(title: cache.clearTitle, icon: "trash", style: .destructive)
                    }
                }
                .disabled(isClearing)
                if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("存储与缓存")
        .task { await refresh() }
        .confirmationDialog(
            "清理所选缓存？",
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            titleVisibility: .visible,
            presenting: clearing
        ) { cache in
            Button("清理缓存", role: .destructive) {
                isClearing = true
                Task { await clear(cache) }
            }
        } message: { cache in
            Text(cache.name)
        }
    }

    private func size(of cache: Cache) -> String {
        switch cache {
        case .lyrics: lyricsBytes.map(format) ?? String(localized: "暂不可统计")
        case .artwork: format(artworkBytes)
        case .roman: format(romanBytes)
        case .images: format(imageBytes)
        }
    }

    private func clear(_ cache: Cache) async {
        defer { isClearing = false }
        failure = nil
        do {
            switch cache {
            case .lyrics: model.lyrics.clearCache()
            case .artwork: ArtworkMediaCache.shared.clear()
            case .roman: try await LyricsRomanizationEngine.shared.clearGeneratedCache()
            case .images: CatalogImageCache.shared.clear()
            }
            await refresh()
        } catch {
            failure = error.localizedDescription
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
        SettingsPage {
            SettingsSection("音乐账号") {
                NavigationLink { MusicAccountsView(model: model) } label: {
                    SettingsActionLabel(title: "管理音乐来源", icon: "person.crop.circle", navigates: true)
                }
                NavigationLink { AppleMusicDiagnosticsView(model: model) } label: {
                    SettingsActionLabel(title: "Apple Music 连接诊断", icon: "stethoscope", navigates: true)
                }
                NavigationLink { SpotifyLoginView(model: model, startsWithConfiguration: true) } label: {
                    SettingsActionLabel(title: "Spotify 配置帮助", icon: "gearshape", navigates: true)
                }
            }
            SettingsSection("播放与歌词") {
                NavigationLink { LyricsSettingsView(coordinator: model.lyrics) } label: {
                    SettingsActionLabel(title: "歌词来源与匹配", icon: "quote.bubble", navigates: true)
                }
                NavigationLink { PlaybackSeekDiagnosticsView() } label: {
                    SettingsActionLabel(title: "播放跳转诊断", icon: "waveform", navigates: true)
                }
            }
            #if DEBUG
            SettingsSection("开发工具") {
                NavigationLink { LyricsRenderPreview() } label: {
                    SettingsActionLabel(title: "render.debug", icon: "waveform.path", navigates: true)
                }
            }
            #endif
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("帮助与故障排查")
    }
}

struct MusicAboutView: View {
    private let root = "https://github.com/QingYaoSheep/amll-player"

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 10) {
                Label("AMLL", systemImage: "music.note").font(.title2.bold())
                LabeledContent("settings.version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            .settingsSurface(radius: 24)
            SettingsSection("开源") {
                Link(destination: URL(string: root + "/blob/swiftui-native/Docs/CHANGELOG.md")!) {
                    SettingsActionLabel(title: "更新记录", icon: "clock.arrow.circlepath", navigates: true)
                }
                Link(destination: URL(string: root)!) {
                    SettingsActionLabel(title: "settings.sourceCode", icon: "chevron.left.forwardslash.chevron.right", navigates: true)
                }
                Link(destination: URL(string: root + "/blob/swiftui-native/THIRD_PARTY_NOTICES.md")!) {
                    SettingsActionLabel(title: "开源许可与来源归属", icon: "doc.text", navigates: true)
                }
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("关于 AMLL")
    }
}
