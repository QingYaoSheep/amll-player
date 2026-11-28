import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(AppHaptics.preferenceKey) private var hapticsEnabled = true
    @State private var exportingSettings = false
    @State private var importingSettings = false
    @State private var showingSettingsExporter = false
    @State private var showingSettingsImporter = false
    @State private var settingsDocument: AppSettingsDocument?
    @State private var settingsExportError: String?
    @State private var showingImportSuccess = false

    var body: some View {
        SettingsPage {
            NavigationLink {
                MusicAccountsView(model: model)
            } label: {
                SettingsAccountHeader(
                    service: model.selectedMusicService,
                    name: accountName,
                    avatar: accountAvatar,
                    status: model.settingsConnectionStatus(model.selectedMusicService),
                    connected: model.currentServiceConnected,
                    showsChevron: true,
                    serviceStatuses: MusicServiceID.allCases.map { ($0, model.isConnected(to: $0)) }
                )
            }
            .buttonStyle(SettingsButtonStyle())
            .accessibilityIdentifier("musicAccountsLink")

            SettingsSection("播放与歌词") {
                SettingsGroup {
                    NavigationLink { MusicPlaybackSettingsView(model: model) } label: {
                        SettingsRowLabel(
                            title: "settings.playbackTitle",
                            icon: "play.fill",
                            iconColor: MusicProductStyle.accent,
                            value: model.selectedMusicService.title,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    NavigationLink {
                        LyricsAppearanceView(preferences: model.renderPreferences, coordinator: model.lyrics)
                    } label: {
                        SettingsRowLabel(
                            title: "歌词与外观",
                            icon: "textformat.size",
                            iconColor: MusicProductStyle.accent,
                            value: appearanceSummary,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    NavigationLink { LyricsSettingsView(coordinator: model.lyrics) } label: {
                        SettingsRowLabel(
                            title: "歌词来源与匹配",
                            icon: "quote.bubble",
                            iconColor: MusicProductStyle.accent,
                            value: lyricsSummary,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .accessibilityIdentifier("lyricsSourceSettingsLink")

                    if model.desktopLyrics.isSupported {
                        SettingsDivider()

                        NavigationLink {
                            DesktopLyricsSettingsView(model: model, preferences: model.desktopLyricsPreferences)
                        } label: {
                            SettingsRowLabel(title: "desktopLyrics.title", icon: "pip.enter",
                                             iconColor: MusicProductStyle.accent, navigates: true)
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .accessibilityIdentifier("desktopLyricsSettingsLink")
                    }

                    SettingsDivider()

                    Toggle(isOn: $model.lockScreenLyricsEnabled.hapticSelection()) {
                        SettingsIconToggleLabel(title: "lockScreenLyrics.title", icon: "lock.rectangle",
                                                color: MusicProductStyle.accent)
                    }
                    .accessibilityIdentifier("lockScreenLyricsEnabled")
                    if model.lockScreenLyricsEnabled {
                        SettingsDivider()
                        Toggle(isOn: $model.lockScreenLyricsShowsTranslation.hapticSelection()) {
                            SettingsIconToggleLabel(title: "lockScreenLyrics.translation", icon: "translate",
                                                    color: MusicProductStyle.accent)
                        }
                        .accessibilityIdentifier("lockScreenLyricsTranslation")

                        SettingsDivider()
                        Toggle(isOn: $model.lockScreenLyricsShowsRomanization.hapticSelection()) {
                            SettingsIconToggleLabel(title: "lockScreenLyrics.romanization", icon: "textformat",
                                                    color: MusicProductStyle.accent)
                        }
                        .accessibilityIdentifier("lockScreenLyricsRomanization")

                        if AMLLBuildCapabilities.supportsSilentBackgroundKeepAlive {
                            SettingsDivider()
                            Toggle(isOn: $model.lockScreenLyricsKeepAliveEnabled.hapticSelection()) {
                                SettingsIconToggleLabel(title: "lockScreenLyrics.keepAlive", icon: "waveform",
                                                        color: MusicProductStyle.accent)
                            }
                            .accessibilityIdentifier("lockScreenLyricsKeepAlive")

                            Text("lockScreenLyrics.keepAliveHint")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 64)
                                .padding(.trailing, 18)
                                .padding(.bottom, 12)
                        }
                    }

                    SettingsDivider()

                    Toggle(isOn: $hapticsEnabled.hapticSelection()) {
                        SettingsIconToggleLabel(title: "settings.haptics", icon: "hand.tap", color: MusicProductStyle.accent)
                    }
                    .accessibilityIdentifier("appHapticsEnabled")

                    SettingsDivider()

                    Toggle(isOn: $model.lyricsKeepScreenAwake.hapticSelection()) {
                        SettingsIconToggleLabel(title: "settings.keepScreenAwake", icon: "sun.max", color: MusicProductStyle.accent)
                    }
                    .accessibilityIdentifier("lyricsKeepScreenAwake")
                }
            }

            SettingsSection("存储") {
                SettingsGroup {
                    NavigationLink { MusicStorageView(model: model) } label: {
                        SettingsRowLabel(
                            title: "存储与缓存",
                            icon: "internaldrive",
                            iconColor: MusicProductStyle.accent,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    Button {
                        Task { await exportSettings() }
                    } label: {
                        SettingsRowLabel(
                            title: "导出所有设置",
                            icon: "square.and.arrow.up",
                            iconColor: MusicProductStyle.accent,
                            busy: exportingSettings
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .disabled(exportingSettings || importingSettings)
                    .accessibilityIdentifier("exportAllSettings")

                    SettingsDivider()

                    Button {
                        showingSettingsImporter = true
                    } label: {
                        SettingsRowLabel(
                            title: "settings.import",
                            icon: "square.and.arrow.down",
                            iconColor: MusicProductStyle.accent,
                            busy: importingSettings
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .disabled(exportingSettings || importingSettings)
                    .accessibilityIdentifier("importAllSettings")
                }
            }

            SettingsSection("支持") {
                SettingsGroup {
                    NavigationLink { MusicHelpView(model: model) } label: {
                        SettingsRowLabel(
                            title: "帮助与故障排查",
                            icon: "questionmark.circle",
                            iconColor: MusicProductStyle.accent,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    NavigationLink { MusicAboutView() } label: {
                        SettingsRowLabel(
                            title: "关于 AMLL",
                            icon: "info.circle",
                            iconColor: MusicProductStyle.accent,
                            value: appVersion,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    SettingsDisclosureRow(title: "开发与调试", icon: "wrench.and.screwdriver", iconColor: MusicProductStyle.accent) {
                        NavigationLink {
                            ImmersiveArtworkDebugPanel(
                                backgroundDimming: model.renderPreferences.configuration.validated().backgroundDimming ?? 0.16
                            )
                        } label: {
                            SettingsRowLabel(
                                title: "沉浸封面层级调试（临时）",
                                icon: "slider.horizontal.3",
                                iconColor: MusicProductStyle.accent,
                                navigates: true
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                }
            }
        }
        .navigationTitle("tab.settings")
        .navigationBarTitleDisplayMode(.large)
        .fileExporter(isPresented: $showingSettingsExporter, document: settingsDocument, contentType: .json,
                      defaultFilename: String(localized: "settings.exportFilename")) { result in
            if case .failure(let error) = result { settingsExportError = error.localizedDescription }
        }
        .fileImporter(isPresented: $showingSettingsImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                Task { await importSettings(from: url) }
            case let .failure(error):
                settingsExportError = error.localizedDescription
            }
        }
        .onChange(of: showingSettingsExporter) { _, showing in
            if !showing { settingsDocument = nil }
        }
        .alert("无法导出设置", isPresented: Binding(get: { settingsExportError != nil }, set: { showing in
            if !showing { settingsExportError = nil }
        })) {
            Button("common.ok", role: .cancel) { settingsExportError = nil }
        } message: {
            Text(settingsExportError ?? "")
        }
        .alert("settings.importSuccessTitle", isPresented: $showingImportSuccess) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("settings.importSuccessMessage")
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

    private var appearanceSummary: String {
        let config = model.renderPreferences.configuration
        if let preset = config.sizePreset {
            return String(localized: String.LocalizationValue("render.size." + preset.rawValue))
        }
        return String(format: "%.0f pt", config.fontSize)
    }

    private var lyricsSummary: String {
        guard model.lyrics.settings.enabled else { return String(localized: "settings.lyrics.off") }
        return model.lyrics.settings.priority.first?.name ?? ""
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func exportSettings() async {
        guard !exportingSettings else { return }
        exportingSettings = true
        defer { exportingSettings = false }
        do {
            let overrides = try await LyricsRomanizationEngine.shared.exportOverrides()
            let snapshot = try AppSettingsExport(
                model: model,
                pronunciationOverrides: JSONDecoder().decode([String: [String: String]].self, from: overrides))
            settingsDocument = AppSettingsDocument(data: try snapshot.encoded())
            showingSettingsExporter = true
        } catch {
            settingsExportError = error.localizedDescription
        }
    }

    private func importSettings(from url: URL) async {
        guard !importingSettings else { return }
        importingSettings = true
        defer { importingSettings = false }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode(AppSettingsExport.self, from: data)
            try await imported.apply(to: model)
            AppHaptics.shared.play(.success)
            showingImportSuccess = true
        } catch {
            settingsExportError = String(localized: "settings.importErrorMessage") + "\n" + error.localizedDescription
        }
    }
}

struct MusicAccountsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsGroup {
                    MusicSourcePicker(model: model)
                }
            }
            SettingsSection("音乐账号") {
                SettingsGroup {
                    ForEach(Array(MusicServiceID.allCases.enumerated()), id: \.element.id) { index, service in
                        if index > 0 { SettingsDivider() }
                        NavigationLink {
                            MusicLoginDestination(model: model, service: service)
                        } label: {
                            SettingsRowLabel(
                                title: LocalizedStringKey(service.title),
                                icon: service.settingsIcon,
                                iconColor: service.brandColor,
                                subtitle: model.settingsConnectionStatus(service),
                                navigates: true
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .accessibilityIdentifier(service.rawValue + "LoginLink")
                    }
                }
            }
        }
        .navigationTitle("账号与音乐来源")
    }
}

struct MusicPlaybackSettingsView: View {
    @Bindable var model: AppModel
    @State private var showTiming = false

    var body: some View {
        SettingsPage {
            SettingsSection(footer: showTiming ? "新音质从下一首开始生效。" : nil) {
                SettingsGroup {
                    SettingsInfoRow(
                        title: "当前音乐来源",
                        value: model.selectedMusicService.title,
                        icon: model.selectedMusicService.settingsIcon,
                        iconColor: model.selectedMusicService.brandColor
                    )
                    if model.selectedMusicService == .netease {
                        SettingsDivider()
                        NetEaseQualityPicker(model: model, showTiming: $showTiming)
                    }
                    SettingsDivider()
                    if model.currentServiceConnected {
                        NavigationLink { DevicePickerView(model: model).task { await model.loadDevices() } } label: {
                            SettingsRowLabel(
                                title: "选择播放设备",
                                icon: "airplayaudio",
                                iconColor: MusicProductStyle.accent,
                                navigates: true
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    } else {
                        NavigationLink { MusicLoginDestination(model: model, service: model.selectedMusicService) } label: {
                            SettingsRowLabel(
                                title: "连接账号",
                                icon: "person.crop.circle",
                                iconColor: MusicProductStyle.accent,
                                navigates: true
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                }
            }
        }
        .navigationTitle("settings.playbackTitle")
    }
}

struct NetEaseQualityPicker: View {
    @Bindable var model: AppModel
    var showTiming: Binding<Bool>? = nil
    @State private var localShowTiming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let timingBinding = showTiming ?? $localShowTiming
        VStack(alignment: .leading, spacing: 4) {
            Picker("播放音质", selection: Binding(get: { model.netEasePlayback.quality }, set: { quality in
                guard quality != model.netEasePlayback.quality else { return }
                model.netEasePlayback.quality = quality
                withAnimation(reduceMotion ? nil : SettingsMotion.change) { timingBinding.wrappedValue = true }
            })) {
                ForEach(NetEaseQuality.allCases) { quality in Text(quality.title).tag(quality) }
            }
            .settingsPickerRow("播放音质", icon: "waveform", iconColor: MusicProductStyle.accent)
            if showTiming == nil, localShowTiming {
                Text("新音质从下一首开始生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

        var icon: String {
            switch self {
            case .lyrics: "quote.bubble"
            case .artwork: "sparkles.rectangle.stack"
            case .roman: "character.book.closed"
            case .images: "photo.stack"
            }
        }

        var color: Color {
            switch self {
            case .lyrics: MusicProductStyle.accent
            case .artwork: MusicProductStyle.accent.opacity(0.72)
            case .roman: MusicProductStyle.accent.opacity(0.48)
            case .images: MusicProductStyle.accent.opacity(0.28)
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
            SettingsGroup(radius: SettingsCorners.hero) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.storage.total")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(format(totalBytes))
                            .font(.title.bold())
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }

                    storageBreakdownBar

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], alignment: .leading, spacing: 6) {
                        ForEach(Cache.allCases) { cache in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(cache.color)
                                    .frame(width: 8, height: 8)
                                Text(cache.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(18)
            }

            SettingsSection("缓存占用") {
                SettingsGroup {
                    ForEach(Array(Cache.allCases.enumerated()), id: \.element.id) { index, cache in
                        if index > 0 { SettingsDivider() }
                        HStack(spacing: 14) {
                            SettingsIconBadge(systemImage: cache.icon, color: MusicProductStyle.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cache.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(size(of: cache))
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button(role: .destructive) { clearing = cache } label: {
                                Text("settings.storage.clear")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .disabled(isClearing || isZero(cache))
                            .accessibilityLabel(cache.clearTitle)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    }
                }
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                }
            }
        }
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

    private var storageBreakdownBar: some View {
        let segments = Cache.allCases.compactMap { cache -> (Cache, Int64)? in
            let count = bytes(of: cache) ?? 0
            return count > 0 ? (cache, count) : nil
        }
        return GeometryReader { proxy in
            let total = max(1, totalBytes)
            let gap: CGFloat = segments.count > 1 ? 2 : 0
            let available = max(0, proxy.size.width - CGFloat(max(0, segments.count - 1)) * gap)
            HStack(spacing: gap) {
                if segments.isEmpty {
                    Capsule().fill(Color.primary.opacity(0.08))
                } else {
                    ForEach(segments, id: \.0.id) { cache, count in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(cache.color)
                            .frame(width: max(4, available * (CGFloat(count) / CGFloat(total))))
                    }
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .background(Color.primary.opacity(0.06), in: Capsule())
        .animation(reduceMotion ? nil : SettingsMotion.change, value: totalBytes)
        .accessibilityHidden(true)
    }

    private var totalBytes: Int64 {
        (lyricsBytes ?? 0) + artworkBytes + romanBytes + imageBytes
    }

    private func bytes(of cache: Cache) -> Int64? {
        switch cache {
        case .lyrics: lyricsBytes
        case .artwork: artworkBytes
        case .roman: romanBytes
        case .images: imageBytes
        }
    }

    private func isZero(_ cache: Cache) -> Bool {
        guard let count = bytes(of: cache) else { return false }
        return count <= 0
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
    @State private var exportingDiagnostics = false
    @State private var diagnosticsURL: URL?

    private var diagnosticsUnlocked: Bool {
        AppDiagnosticsVisibility.shared.isUnlocked
    }

    var body: some View {
        SettingsPage {
            SettingsSection("音乐账号") {
                SettingsGroup {
                    NavigationLink { MusicAccountsView(model: model) } label: {
                        SettingsRowLabel(title: "settings.manageSources", icon: "person.crop.circle", iconColor: MusicProductStyle.accent, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    NavigationLink { SpotifyLoginView(model: model, startsWithConfiguration: true) } label: {
                        SettingsRowLabel(title: "Spotify 配置帮助", icon: "gearshape", iconColor: MusicServiceID.spotify.brandColor, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    if diagnosticsUnlocked {
                        SettingsDivider()

                        NavigationLink { AppleMusicDiagnosticsView(model: model) } label: {
                            SettingsRowLabel(title: "Apple Music 连接诊断", icon: "stethoscope", iconColor: MusicProductStyle.accent, navigates: true)
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                }
            }
            SettingsSection("播放与歌词") {
                SettingsGroup {
                    NavigationLink { LyricsSettingsView(coordinator: model.lyrics) } label: {
                        SettingsRowLabel(title: "歌词来源与匹配", icon: "quote.bubble", iconColor: MusicProductStyle.accent, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    if diagnosticsUnlocked {
                        SettingsDivider()

                        NavigationLink { PlaybackSeekDiagnosticsView() } label: {
                            SettingsRowLabel(title: "播放跳转诊断", icon: "waveform", iconColor: MusicProductStyle.accent, navigates: true)
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                }
            }
            if diagnosticsUnlocked {
                SettingsSection("开发工具") {
                    SettingsGroup {
                        #if DEBUG
                        NavigationLink { LyricsRenderPreview() } label: {
                            SettingsRowLabel(title: "render.debug", icon: "waveform.path", iconColor: MusicProductStyle.accent, navigates: true)
                        }
                        .buttonStyle(SettingsRowButtonStyle())

                        SettingsDivider()
                        #endif

                        if let diagnosticsURL {
                            ShareLink(item: diagnosticsURL) {
                                SettingsRowLabel(title: "diagnostics.shareExported", icon: "square.and.arrow.up", iconColor: MusicProductStyle.accent)
                            }
                            .buttonStyle(SettingsRowButtonStyle())
                        } else {
                            Button {
                                Task {
                                    exportingDiagnostics = true
                                    diagnosticsURL = try? await model.environment.diagnostics.exportDiagnostics()
                                    exportingDiagnostics = false
                                }
                            } label: {
                                SettingsRowLabel(title: "diagnostics.exportSanitized", icon: "doc.text.magnifyingglass", iconColor: MusicProductStyle.accent, busy: exportingDiagnostics)
                            }
                            .buttonStyle(SettingsRowButtonStyle())
                            .disabled(exportingDiagnostics)
                        }
                    }
                }
            }
        }
        .navigationTitle("帮助与故障排查")
    }
}

struct MusicAboutView: View {
    private let root = "https://github.com/QingYaoSheep/amll-player"
    @State private var versionTapCount = 0
    @State private var diagnosticStatusMessage: String?

    var body: some View {
        SettingsPage {
            SettingsGroup(radius: SettingsCorners.hero) {
                HStack(spacing: 14) {
                    Image("LaunchMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AMLL")
                            .font(.title2.bold())
                        HStack(spacing: 6) {
                            Text("settings.version")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(versionString)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        if let diagnosticStatusMessage {
                            Text(LocalizedStringKey(diagnosticStatusMessage))
                                .font(.caption2)
                                .foregroundStyle(MusicProductStyle.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
                .contentShape(Rectangle())
                .onTapGesture {
                    versionTapCount += 1
                    if versionTapCount >= 5 {
                        versionTapCount = 0
                        let unlocked = AppDiagnosticsVisibility.shared.toggle()
                        AppHaptics.shared.play(.success)
                        diagnosticStatusMessage = unlocked ? "about.diagnosticsUnlocked" : "about.diagnosticsLocked"
                    }
                }
            }

            SettingsSection("开源") {
                SettingsGroup {
                    NavigationLink { MusicOfflineLicensesView() } label: {
                        SettingsRowLabel(title: "开源许可与来源归属", icon: "doc.text", iconColor: MusicProductStyle.accent, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    NavigationLink { MusicPrivacySummaryView() } label: {
                        SettingsRowLabel(title: "about.privacySummary", icon: "hand.raised", iconColor: MusicProductStyle.accent, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    Link(destination: URL(string: root + "/releases")!) {
                        SettingsRowLabel(title: "更新记录", icon: "clock.arrow.circlepath", iconColor: MusicProductStyle.accent, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    Link(destination: URL(string: root + "/issues")!) {
                        SettingsRowLabel(title: "about.feedback", icon: "exclamationmark.bubble", iconColor: MusicProductStyle.accent, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider()

                    Link(destination: URL(string: root)!) {
                        SettingsRowLabel(title: "settings.sourceCode", icon: "chevron.left.forwardslash.chevron.right", iconColor: MusicProductStyle.accent, navigates: true)
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                }
            }
        }
        .navigationTitle("关于 AMLL")
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}

private struct MusicOfflineLicensesView: View {
    private struct LicenseFile: Identifiable {
        let name: String
        let body: String
        var id: String { name }
    }

    private let noticesText: String = {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return ""
    }()

    private let licenseFiles: [LicenseFile] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "Licenses")
            ?? Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil)
            ?? []
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return LicenseFile(name: url.deletingPathExtension().lastPathComponent, body: content)
            }
    }()

    var body: some View {
        SettingsPage {
            if !noticesText.isEmpty {
                SettingsSection("about.thirdPartyNotices") {
                    SettingsGroup {
                        Text(noticesText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(16)
                    }
                }
            }
            ForEach(licenseFiles) { license in
                SettingsSection {
                    SettingsGroup {
                        DisclosureGroup(license.name) {
                            Text(license.body)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .padding(.top, 8)
                        }
                        .padding(16)
                    }
                }
            }
        }
        .navigationTitle("开源许可与来源归属")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MusicPrivacySummaryView: View {
    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("about.privacyLocalHeadline")
                            .font(.headline)
                        Text("about.privacyLocalBody")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                }
            }
        }
        .navigationTitle("about.privacySummary")
        .navigationBarTitleDisplayMode(.inline)
    }
}
