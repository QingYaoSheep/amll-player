import SwiftUI
import UniformTypeIdentifiers

struct LyricsAppearanceView: View {
    private func flowingAdjustment(_ title: String, key: WritableKeyPath<FlowingBackgroundConfiguration, Double>,
                                   range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        let binding = Binding(get: { (preferences.configuration.flowingBackground ?? .init())[keyPath: key] }, set: { value in
            var settings = preferences.configuration.flowingBackground ?? .init()
            settings[keyPath: key] = value
            preferences.configuration.flowingBackground = settings.validated()
        })
        return VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: "%.2g %@", binding.wrappedValue, unit))
            Slider(value: binding, in: range, step: step).accessibilityLabel(Text(title))
        }
        .settingsSurface()
    }
    private func backgroundColorBinding(_ key: WritableKeyPath<LyricsRenderConfiguration, LyricsRenderConfiguration.BackgroundColor?>) -> Binding<Color> {
        Binding(get: { (preferences.configuration[keyPath: key] ?? .sourceDefault).swiftUIColor }, set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            preferences.configuration[keyPath: key] = .init(red: Double(red), green: Double(green), blue: Double(blue))
        })
    }

    @Bindable var preferences: LyricsRenderPreferences
    var coordinator: LyricsCoordinator? = nil
    @State private var confirmReset = false
    @State private var confirmClearArtwork = false

    private func adjustment(_ title: LocalizedStringKey, key: WritableKeyPath<LyricsRenderConfiguration, Double?>, fallback: Double, range: ClosedRange<Double>, step: Double = 1) -> some View {
        let binding = Binding(get: { preferences.configuration[keyPath: key] ?? fallback },
                              set: { preferences.configuration[keyPath: key] = $0 })
        return VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: "%.2g", binding.wrappedValue))
            Slider(value: binding, in: range, step: step).accessibilityLabel(Text(title))
        }
        .settingsSurface()
    }

    var body: some View {
        SettingsPage {
            SettingsSection("appearance.quick") {
                SettingsTextButton(title: "appearance.reading", icon: "textformat.size") {
                    preferences.configuration.fontSize = 32
                    preferences.configuration.sizePreset = nil
                    preferences.configuration.bold = true
                    preferences.configuration.translation = true
                    preferences.configuration.romanization = false
                }
                SettingsTextButton(title: "appearance.calm", icon: "waveform.path") {
                    preferences.configuration.emphasizeWords = false
                    preferences.configuration.enableScale = false
                    preferences.configuration.enableSpring = false
                }
                DisclosureGroup("appearance.compatibility") {
                    Picker("render.profile", selection: Binding(
                        get: { preferences.profile },
                        set: { preferences.activate($0) }
                    )) {
                        Text("render.profile.amll").tag(LyricsPresentationProfile.amll)
                        Text("render.profile.custom").tag(LyricsPresentationProfile.custom)
                    }
                }
                .settingsSurface()
            }
            SettingsSection("render.typography") {
                Text("render.sample").font(.system(size: preferences.configuration.resolvedFontSize(width: 320, height: 600), weight: preferences.configuration.bold ? .bold : .regular))
                    .tracking(preferences.configuration.tracking).frame(minHeight: 70)
                    .settingsSurface()
                Toggle("appearance.autoSize", isOn: Binding(
                    get: { preferences.configuration.sizePreset != nil },
                    set: { preferences.configuration.sizePreset = $0 ? .medium : nil }
                ).hapticSelection())
                .settingsSurface()
                if preferences.configuration.sizePreset == nil {
                    Picker("render.fontSize", selection: Binding(
                        get: { preferences.configuration.fontSize },
                        set: {
                            // A concrete size is an explicit override of AMLL's
                            // responsive preset. Clear the preset so the choice
                            // is visible immediately and survives the next frame.
                            preferences.configuration.fontSize = $0
                            preferences.configuration.sizePreset = nil
                        }
                    )) {
                        Text("render.small").tag(26.0); Text("render.medium").tag(32.0)
                        Text("render.large").tag(40.0); Text("render.extraLarge").tag(48.0)
                    }
                } else {
                    Picker("render.sizePreset", selection: Binding(
                        get: { preferences.configuration.sizePreset },
                        set: { preferences.configuration.sizePreset = $0 }
                    )) {
                        ForEach(AMLLLyricSizePreset.allCases, id: \.self) { preset in
                            Text(LocalizedStringKey("render.size." + preset.rawValue)).tag(Optional(preset))
                        }
                    }
                }
                Toggle("render.bold", isOn: $preferences.configuration.bold.hapticSelection())
                    .settingsSurface()
                Toggle("render.translation", isOn: $preferences.configuration.translation.hapticSelection())
                    .settingsSurface()
                Toggle("render.romanization", isOn: $preferences.configuration.romanization.hapticSelection())
                    .settingsSurface()
                NavigationLink {
                    RomanizationSettingsView(coordinator: coordinator)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    SettingsActionLabel(title: "日语／韩语自动音译", icon: "character.book.closed", navigates: true)
                }
                DisclosureGroup("appearance.textDetails") {
                    LabeledContent("render.tracking", value: String(format: "%.1f", preferences.configuration.tracking))
                    Slider(value: $preferences.configuration.tracking, in: -1 ... 3, step: 0.25).accessibilityLabel(Text("render.tracking"))
                    Toggle("render.romanizationFirst", isOn: $preferences.configuration.romanizationFirst.hapticSelection())
                    if preferences.profile == .amll {
                        adjustment("appearance.padding", key: \.horizontalPadding, fallback: 20, range: 12 ... 60, step: 2)
                        adjustment("appearance.spacing", key: \.paragraphSpacing, fallback: 0, range: 0 ... 60, step: 2)
                        adjustment("appearance.auxSize", key: \.auxiliaryScale, fallback: 0.5, range: 0.3 ... 1, step: 0.05)
                    }
                }
                .settingsSurface()
            }
            SettingsSection("render.motion") {
                Toggle("render.blurInactive", isOn: $preferences.configuration.blurInactive.hapticSelection())
                    .settingsSurface()
                Toggle("render.emphasizeWords", isOn: $preferences.configuration.emphasizeWords.hapticSelection())
                    .settingsSurface()
                Toggle("render.spring", isOn: $preferences.configuration.enableSpring.hapticSelection())
                    .settingsSurface()
                Toggle("render.scale", isOn: $preferences.configuration.enableScale.hapticSelection())
                    .settingsSurface()
                NavigationLink {
                    LyricsAnimationSettingsView(preferences: preferences)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    SettingsActionLabel(title: "精细动画调整", icon: "waveform.path", navigates: true)
                }
                .accessibilityIdentifier("lyricsAnimationSettings")
            }
            SettingsSection("render.layout") {
                Toggle("render.showLyrics", isOn: $preferences.configuration.showLyrics.hapticSelection())
                    .settingsSurface()
                if preferences.profile == .amll {
                    Toggle("appearance.metadata", isOn: Binding(
                        get: { preferences.configuration.showMetadata ?? true },
                        set: { preferences.configuration.showMetadata = $0 }
                    ).hapticSelection())
                    adjustment("appearance.corner", key: \.artworkCornerRadius, fallback: 12, range: 0 ... 40, step: 2)
                }
                DisclosureGroup("appearance.pageDetails") {
                    if preferences.profile == .custom {
                        Picker("render.coverLayout", selection: $preferences.configuration.coverLayout) {
                            ForEach(LyricsRenderConfiguration.CoverLayout.allCases, id: \.self) { layout in
                                Text(LocalizedStringKey("render.layout." + layout.rawValue)).tag(layout)
                            }
                        }
                    }
                    Toggle("render.showTitle", isOn: $preferences.configuration.showTitle.hapticSelection())
                    Toggle("render.showArtist", isOn: $preferences.configuration.showArtist.hapticSelection())
                    Toggle("render.showAlbum", isOn: $preferences.configuration.showAlbum.hapticSelection())
                    Toggle("render.showControls", isOn: $preferences.configuration.showControls.hapticSelection())
                    Toggle("render.volume", isOn: $preferences.configuration.showVolume.hapticSelection())
                    if preferences.profile == .custom {
                        Picker("render.credits", selection: $preferences.configuration.credits) {
                            ForEach(LyricsRenderConfiguration.Credits.allCases, id: \.self) { mode in
                                Text(LocalizedStringKey("render.credits." + mode.rawValue)).tag(mode)
                            }
                        }
                    }
                }
                .settingsSurface()
            }
            SettingsSection("render.background") {
                Picker("背景模式", selection: Binding(get: { preferences.configuration.backgroundMode ?? .mesh },
                                                  set: { preferences.configuration.backgroundMode = $0 }))
                {
                    Text("Mesh 网格").tag(LyricsRenderConfiguration.BackgroundMode.mesh)
                    Text("Mesh网格（取色模式2）").tag(LyricsRenderConfiguration.BackgroundMode.meshColorMode2)
                    Text("Pixi 流动封面").tag(LyricsRenderConfiguration.BackgroundMode.pixi)
                    Text("流动背景").tag(LyricsRenderConfiguration.BackgroundMode.flowing)
                    Text("纯色").tag(LyricsRenderConfiguration.BackgroundMode.solid)
                    Text("双色渐变").tag(LyricsRenderConfiguration.BackgroundMode.gradient)
                }
                if preferences.profile == .amll {
                    adjustment("appearance.dimming", key: \.backgroundDimming, fallback: 0.16, range: 0 ... 0.8, step: 0.04)
                }
                if (preferences.configuration.backgroundMode ?? .mesh).isMesh {
                    LabeledContent("render.backgroundBlur", value: String(format: "%.0f pt", preferences.configuration.backgroundBlur))
                    Slider(value: $preferences.configuration.backgroundBlur, in: 0 ... 80, step: 5).accessibilityLabel(Text("render.backgroundBlur"))
                } else if preferences.configuration.backgroundMode == .flowing {
                    flowingAdjustment("旋转速度", key: \.rotationSpeed, range: 0 ... 6, step: 0.25, unit: "°/秒")
                    flowingAdjustment("扭曲强度", key: \.distortion, range: 0 ... 8, step: 0.5, unit: "%")
                    flowingAdjustment("高斯模糊程度", key: \.blur, range: 0 ... 80, step: 5, unit: "pt")
                    SettingsTextButton(title: "恢复流动背景默认值", icon: "arrow.counterclockwise") { preferences.configuration.flowingBackground = .init() }
                } else if preferences.configuration.backgroundMode != .pixi {
                    ColorPicker("背景颜色", selection: backgroundColorBinding(\.backgroundColor), supportsOpacity: false)
                    if preferences.configuration.backgroundMode == .gradient {
                        ColorPicker("底部颜色", selection: backgroundColorBinding(\.backgroundGradientEnd), supportsOpacity: false)
                    }
                }
            }
            SettingsSection("高级视觉") {
                DisclosureGroup("歌词内容遮罩") {
                    Picker("标记词显示", selection: Binding(
                        get: { preferences.configuration.obsceneWordMask?.mode ?? .disabled },
                        set: { mode in
                            var value = preferences.configuration.obsceneWordMask ?? .init()
                            value.mode = mode
                            preferences.configuration.obsceneWordMask = value
                        }
                    )) {
                        Text("原文").tag(AMLLObsceneWordMask.Mode.disabled)
                        Text("保留首尾").tag(AMLLObsceneWordMask.Mode.partial)
                        Text("全部遮罩").tag(AMLLObsceneWordMask.Mode.full)
                    }
                }
                .settingsSurface()
                DisclosureGroup("歌词高光") {
                    Toggle("当前句 HDR 高光", isOn: Binding(
                        get: { preferences.configuration.hdr?.enabled ?? false },
                        set: { preferences.configuration.hdr = .init(enabled: $0) }
                    ).hapticSelection())
                    LyricsHDRStatusView().frame(minHeight: 44)
                }
                .settingsSurface()
                DisclosureGroup("动态专辑封面") {
                    Toggle("启用动态封面", isOn: Binding(
                        get: { preferences.configuration.animatedArtwork?.enabled ?? false },
                        set: { value in
                            var settings = preferences.configuration.animatedArtwork ?? .init()
                            settings.enabled = value
                            preferences.configuration.animatedArtwork = settings
                        }
                    ).hapticSelection())
                    Toggle("允许蜂窝网络加载", isOn: Binding(
                        get: { preferences.configuration.animatedArtwork?.allowCellular ?? false },
                        set: { value in
                            var settings = preferences.configuration.animatedArtwork ?? .init()
                            settings.allowCellular = value
                            preferences.configuration.animatedArtwork = settings
                        }
                    ).hapticSelection())
                    Picker("封面布局", selection: Binding(
                        get: { preferences.configuration.animatedArtwork?.presentation ?? .square },
                        set: { value in
                            var settings = preferences.configuration.animatedArtwork ?? .init()
                            settings.presentation = value
                            preferences.configuration.animatedArtwork = settings
                        }
                    )) {
                        Text("方形封面").tag(AnimatedArtworkConfiguration.Presentation.square)
                        Text("竖屏沉浸封面").tag(AnimatedArtworkConfiguration.Presentation.immersive)
                    }
                    SettingsTextButton(title: "清理动态封面缓存", icon: "trash", role: .destructive) { confirmClearArtwork = true }
                }
                .settingsSurface()
            }
            SettingsTextButton(title: "render.reset", icon: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("render.settings")
        .navigationBarTitleDisplayMode(.inline)
        .lyricsQuickSettingsDestination("render.settings")
        .confirmationDialog("清理动态封面缓存？", isPresented: $confirmClearArtwork, titleVisibility: .visible) {
            Button("清理缓存", role: .destructive) { ArtworkMediaCache.shared.clear() }
        }
        .confirmationDialog("appearance.resetHelp", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("render.reset", role: .destructive) { preferences.restoreAMLLDefaults() }
        }
    }
}

private struct RomanizationSettingsView: View {
    var coordinator: LyricsCoordinator?
    @State private var importing = false
    @State private var exportedFile: URL?
    @State private var exportedTTMLFile: URL?
    @State private var message = ""
    @State private var confirmResetOverrides = false

    var body: some View {
        SettingsPage {
            SettingsSection("自动音译") {
                if let coordinator {
                    Text(coordinator.romanizationStatus.isEmpty ? "等待歌词" : coordinator.romanizationStatus)
                        .font(.footnote)
                }
                SettingsTextButton(title: "重新生成当前歌词", icon: "arrow.clockwise") { coordinator?.regenerateRomanization() }
                SettingsTextButton(title: "准备导出当前罗马音 TTML", icon: "doc") {
                    guard let ttml = coordinator?.document?.romanizationTTMLTrack?.ttml else {
                        message = "当前歌词没有生成的罗马音 TTML"
                        return
                    }
                    do {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("romanization.ttml")
                        try Data(ttml.utf8).write(to: url, options: .atomic)
                        exportedTTMLFile = url
                        message = "罗马音 TTML 已准备好导出"
                    } catch { message = "TTML 导出失败" }
                }
                if let exportedTTMLFile {
                    ShareLink(item: exportedTTMLFile) {
                        SettingsActionLabel(title: "分享罗马音 TTML", icon: "square.and.arrow.up")
                    }
                }
                SettingsTextButton(title: "清理生成缓存", icon: "trash") {
                    Task {
                        do {
                            try await LyricsRomanizationEngine.shared.clearGeneratedCache()
                            coordinator?.regenerateRomanization()
                            message = "生成缓存已清理"
                        } catch { message = "缓存清理失败" }
                    }
                }
            }
            SettingsSection("读音纠错") {
                SettingsTextButton(title: "导入纠错字典", icon: "square.and.arrow.down") { importing = true }
                SettingsTextButton(title: "准备导出纠错字典", icon: "square.and.arrow.up") {
                    Task {
                        do {
                            let data = try await LyricsRomanizationEngine.shared.exportOverrides()
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("romanization-overrides.json")
                            try data.write(to: url, options: .atomic)
                            exportedFile = url
                            message = "纠错字典已准备好导出"
                        } catch { message = "导出失败" }
                    }
                }
                if let exportedFile {
                    ShareLink(item: exportedFile) {
                        SettingsActionLabel(title: "分享纠错字典", icon: "square.and.arrow.up")
                    }
                }
                SettingsTextButton(title: "重置纠错字典", icon: "arrow.counterclockwise", role: .destructive) {
                    confirmResetOverrides = true
                }
            }
            if !message.isEmpty { Text(message).font(.footnote) }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("自动音译")
        .confirmationDialog("删除已导入的读音纠错？", isPresented: $confirmResetOverrides, titleVisibility: .visible) {
            Button("重置纠错字典", role: .destructive) {
                Task {
                    do {
                        try await LyricsRomanizationEngine.shared.resetOverrides()
                        coordinator?.regenerateRomanization()
                        message = "纠错字典已重置"
                    } catch { message = "重置失败" }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { selection in
            guard case let .success(url) = selection else { message = "导入已取消"; return }
            Task {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    try await LyricsRomanizationEngine.shared.importOverrides(data)
                    coordinator?.regenerateRomanization()
                    message = "纠错字典已导入"
                } catch { message = "字典格式错误，现有纠错保留" }
            }
        }
    }
}
