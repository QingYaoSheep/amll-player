import SwiftUI
import UniformTypeIdentifiers

struct LyricsAppearanceView: View {
    private func flowingAdjustment(_ title: LocalizedStringKey, key: WritableKeyPath<FlowingBackgroundConfiguration, Double>,
                                   range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        let binding = Binding(get: { (preferences.configuration.flowingBackground ?? .init())[keyPath: key] }, set: { value in
            var settings = preferences.configuration.flowingBackground ?? .init()
            settings[keyPath: key] = value
            preferences.configuration.flowingBackground = settings.validated()
        })
        return SettingsSliderRow(
            title,
            valueText: String(format: "%.2g %@", binding.wrappedValue, unit),
            value: binding,
            in: range,
            step: step
        )
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func adjustment(_ title: LocalizedStringKey, key: WritableKeyPath<LyricsRenderConfiguration, Double?>,
                            fallback: Double, range: ClosedRange<Double>, step: Double = 1) -> some View {
        let binding = Binding(get: { preferences.configuration[keyPath: key] ?? fallback },
                              set: { preferences.configuration[keyPath: key] = $0 })
        return SettingsSliderRow(
            title,
            valueText: String(format: "%.2g", binding.wrappedValue),
            value: binding,
            in: range,
            step: step
        )
    }

    var body: some View {
        SettingsPage {
            LyricsAppearancePreviewCard(configuration: preferences.configuration)

            SettingsSection("appearance.quick") {
                SettingsGroup {
                    SettingsTextButton(title: "appearance.reading", icon: "textformat.size", iconColor: MusicProductStyle.accent, inGroup: true) {
                        preferences.configuration.fontSize = 32
                        preferences.configuration.sizePreset = nil
                        preferences.configuration.bold = true
                        preferences.configuration.translation = true
                        preferences.configuration.romanization = false
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "appearance.calm", icon: "waveform.path", iconColor: MusicProductStyle.accent, inGroup: true) {
                        preferences.configuration.emphasizeWords = false
                        preferences.configuration.enableScale = false
                        preferences.configuration.enableSpring = false
                    }
                    SettingsDivider()
                    SettingsDisclosureRow(title: "appearance.compatibility", icon: "rectangle.on.rectangle", iconColor: MusicProductStyle.accent) {
                        Picker("render.profile", selection: Binding(
                            get: { preferences.profile },
                            set: { preferences.activate($0) }
                        )) {
                            Text("render.profile.amll").tag(LyricsPresentationProfile.amll)
                            Text("render.profile.custom").tag(LyricsPresentationProfile.custom)
                        }
                        .settingsPickerRow("render.profile")
                    }
                }
            }

            SettingsSection("render.typography") {
                SettingsGroup {
                    Toggle("appearance.autoSize", isOn: Binding(
                        get: { preferences.configuration.sizePreset != nil },
                        set: { preferences.configuration.sizePreset = $0 ? .medium : nil }
                    ).hapticSelection())

                    SettingsDivider(inset: 16)

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
                        .settingsPickerRow("render.fontSize")
                    } else {
                        Picker("render.sizePreset", selection: Binding(
                            get: { preferences.configuration.sizePreset },
                            set: { preferences.configuration.sizePreset = $0 }
                        )) {
                            ForEach(AMLLLyricSizePreset.allCases, id: \.self) { preset in
                                Text(LocalizedStringKey("render.size." + preset.rawValue)).tag(Optional(preset))
                            }
                        }
                        .settingsPickerRow("render.sizePreset")
                    }

                    SettingsDivider(inset: 16)
                    Toggle("render.bold", isOn: $preferences.configuration.bold.hapticSelection())
                    SettingsDivider(inset: 16)
                    Toggle("render.translation", isOn: $preferences.configuration.translation.hapticSelection())
                    SettingsDivider(inset: 16)
                    Toggle("render.romanization", isOn: $preferences.configuration.romanization.hapticSelection())
                    SettingsDivider(inset: 16)

                    NavigationLink {
                        RomanizationSettingsView(coordinator: coordinator)
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        SettingsRowLabel(
                            title: "日语／韩语自动音译",
                            icon: "character.book.closed",
                            iconColor: MusicProductStyle.accent,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())

                    SettingsDivider(inset: 16)

                    SettingsDisclosureRow(title: "appearance.textDetails", icon: "textformat", iconColor: MusicProductStyle.accent) {
                        SettingsSliderRow(
                            "render.tracking",
                            valueText: String(format: "%.1f", preferences.configuration.tracking),
                            value: $preferences.configuration.tracking,
                            in: -1 ... 3,
                            step: 0.25
                        )
                        SettingsDivider(inset: 16)
                        Toggle("render.romanizationFirst", isOn: $preferences.configuration.romanizationFirst.hapticSelection())
                        if preferences.profile == .amll {
                            SettingsDivider(inset: 16)
                            adjustment("appearance.padding", key: \.horizontalPadding, fallback: 20, range: 12 ... 60, step: 2)
                            SettingsDivider(inset: 16)
                            adjustment("appearance.spacing", key: \.paragraphSpacing, fallback: 0, range: 0 ... 60, step: 2)
                            SettingsDivider(inset: 16)
                            adjustment("appearance.auxSize", key: \.auxiliaryScale, fallback: 0.5, range: 0.3 ... 1, step: 0.05)
                        }
                    }
                }
            }

            SettingsSection("render.motion") {
                SettingsGroup {
                    Toggle("render.blurInactive", isOn: $preferences.configuration.blurInactive.hapticSelection())
                    SettingsDivider(inset: 16)
                    Toggle("render.emphasizeWords", isOn: $preferences.configuration.emphasizeWords.hapticSelection())
                    SettingsDivider(inset: 16)
                    Toggle("render.spring", isOn: $preferences.configuration.enableSpring.hapticSelection())
                    SettingsDivider(inset: 16)
                    Toggle("render.scale", isOn: $preferences.configuration.enableScale.hapticSelection())
                    SettingsDivider(inset: 16)
                    NavigationLink {
                        LyricsAnimationSettingsView(preferences: preferences)
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        SettingsRowLabel(
                            title: "精细动画调整",
                            icon: "waveform.path",
                            iconColor: MusicProductStyle.accent,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .accessibilityIdentifier("lyricsAnimationSettings")
                }
            }

            SettingsSection("render.layout") {
                SettingsGroup {
                    Toggle("render.showLyrics", isOn: $preferences.configuration.showLyrics.hapticSelection())
                    if preferences.profile == .amll {
                        SettingsDivider(inset: 16)
                        Toggle("appearance.metadata", isOn: Binding(
                            get: { preferences.configuration.showMetadata ?? true },
                            set: { preferences.configuration.showMetadata = $0 }
                        ).hapticSelection())
                        SettingsDivider(inset: 16)
                        adjustment("appearance.corner", key: \.artworkCornerRadius, fallback: 12, range: 0 ... 40, step: 2)
                    }
                    SettingsDivider(inset: 16)
                    SettingsDisclosureRow(title: "appearance.pageDetails", icon: "rectangle.3.group", iconColor: MusicProductStyle.accent) {
                        if preferences.profile == .custom {
                            Picker("render.coverLayout", selection: $preferences.configuration.coverLayout) {
                                ForEach(LyricsRenderConfiguration.CoverLayout.allCases, id: \.self) { layout in
                                    Text(LocalizedStringKey("render.layout." + layout.rawValue)).tag(layout)
                                }
                            }
                            .settingsPickerRow("render.coverLayout")
                            SettingsDivider(inset: 16)
                        }
                        Toggle("render.showTitle", isOn: $preferences.configuration.showTitle.hapticSelection())
                        SettingsDivider(inset: 16)
                        Toggle("render.showArtist", isOn: $preferences.configuration.showArtist.hapticSelection())
                        SettingsDivider(inset: 16)
                        Toggle("render.showAlbum", isOn: $preferences.configuration.showAlbum.hapticSelection())
                        SettingsDivider(inset: 16)
                        Toggle("render.showControls", isOn: $preferences.configuration.showControls.hapticSelection())
                        SettingsDivider(inset: 16)
                        Toggle("render.volume", isOn: $preferences.configuration.showVolume.hapticSelection())
                        if preferences.profile == .custom {
                            SettingsDivider(inset: 16)
                            Picker("render.credits", selection: $preferences.configuration.credits) {
                                ForEach(LyricsRenderConfiguration.Credits.allCases, id: \.self) { mode in
                                    Text(LocalizedStringKey("render.credits." + mode.rawValue)).tag(mode)
                                }
                            }
                            .settingsPickerRow("render.credits")
                        }
                    }
                }
            }

            SettingsSection("render.background") {
                SettingsGroup {
                    Picker("背景模式", selection: Binding(
                        get: { preferences.configuration.backgroundMode ?? .mesh },
                        set: { preferences.configuration.backgroundMode = $0 }
                    )) {
                        Text("Mesh 网格").tag(LyricsRenderConfiguration.BackgroundMode.mesh)
                        Text("Mesh网格（取色模式2）").tag(LyricsRenderConfiguration.BackgroundMode.meshColorMode2)
                        Text("Pixi 流动封面").tag(LyricsRenderConfiguration.BackgroundMode.pixi)
                        Text("流动背景").tag(LyricsRenderConfiguration.BackgroundMode.flowing)
                        Text("纯色").tag(LyricsRenderConfiguration.BackgroundMode.solid)
                        Text("双色渐变").tag(LyricsRenderConfiguration.BackgroundMode.gradient)
                    }
                    .settingsPickerRow("背景模式", icon: "paintbrush", iconColor: MusicProductStyle.accent)

                    if preferences.profile == .amll {
                        SettingsDivider(inset: 16)
                        adjustment("appearance.dimming", key: \.backgroundDimming, fallback: 0.16, range: 0 ... 0.8, step: 0.04)
                    }

                    if (preferences.configuration.backgroundMode ?? .mesh).isMesh {
                        SettingsDivider(inset: 16)
                        SettingsSliderRow(
                            "render.backgroundBlur",
                            valueText: String(format: "%.0f pt", preferences.configuration.backgroundBlur),
                            value: $preferences.configuration.backgroundBlur,
                            in: 0 ... 80,
                            step: 5
                        )
                    } else if preferences.configuration.backgroundMode == .flowing {
                        SettingsDivider(inset: 16)
                        flowingAdjustment("旋转速度", key: \.rotationSpeed, range: 0 ... 6, step: 0.25, unit: String(localized: "°/秒"))
                        SettingsDivider(inset: 16)
                        flowingAdjustment("扭曲强度", key: \.distortion, range: 0 ... 8, step: 0.5, unit: "%")
                        SettingsDivider(inset: 16)
                        flowingAdjustment("高斯模糊程度", key: \.blur, range: 0 ... 80, step: 5, unit: "pt")
                        SettingsDivider()
                        SettingsTextButton(title: "恢复流动背景默认值", icon: "arrow.counterclockwise", iconColor: MusicProductStyle.accent, inGroup: true) {
                            preferences.configuration.flowingBackground = .init()
                        }
                    } else if preferences.configuration.backgroundMode != .pixi {
                        SettingsDivider(inset: 16)
                        ColorPicker("背景颜色", selection: backgroundColorBinding(\.backgroundColor), supportsOpacity: false)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 48)
                        if preferences.configuration.backgroundMode == .gradient {
                            SettingsDivider(inset: 16)
                            ColorPicker("底部颜色", selection: backgroundColorBinding(\.backgroundGradientEnd), supportsOpacity: false)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(minHeight: 48)
                        }
                    }
                }
            }

            SettingsSection("高级视觉") {
                SettingsGroup {
                    SettingsDisclosureRow(title: "歌词内容遮罩", icon: "eye.slash", iconColor: MusicProductStyle.accent) {
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
                        .settingsPickerRow("标记词显示")
                    }

                    SettingsDivider()

                    SettingsDisclosureRow(title: "歌词高光", icon: "sun.max.fill", iconColor: MusicProductStyle.accent) {
                        Toggle("当前句 HDR 高光", isOn: Binding(
                            get: { preferences.configuration.hdr?.enabled ?? false },
                            set: { preferences.configuration.hdr = .init(enabled: $0) }
                        ).hapticSelection())
                        SettingsDivider(inset: 16)
                        LyricsHDRStatusView()
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }

                    SettingsDivider()

                    SettingsDisclosureRow(title: "动态专辑封面", icon: "sparkles.rectangle.stack", iconColor: MusicProductStyle.accent) {
                        Toggle("启用动态封面", isOn: Binding(
                            get: { preferences.configuration.animatedArtwork?.enabled ?? false },
                            set: { value in
                                var settings = preferences.configuration.animatedArtwork ?? .init()
                                settings.enabled = value
                                preferences.configuration.animatedArtwork = settings
                            }
                        ).hapticSelection())
                        SettingsDivider(inset: 16)
                        Toggle("允许蜂窝网络加载", isOn: Binding(
                            get: { preferences.configuration.animatedArtwork?.allowCellular ?? false },
                            set: { value in
                                var settings = preferences.configuration.animatedArtwork ?? .init()
                                settings.allowCellular = value
                                preferences.configuration.animatedArtwork = settings
                            }
                        ).hapticSelection())
                        SettingsDivider(inset: 16)
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
                        .settingsPickerRow("封面布局")
                        SettingsDivider()
                        SettingsTextButton(title: "清理动态封面缓存", icon: "trash", role: .destructive, inGroup: true) {
                            confirmClearArtwork = true
                        }
                    }
                }
            }

            SettingsTextButton(title: "render.reset", icon: "arrow.counterclockwise", role: .destructive) {
                confirmReset = true
            }
        }
        .animation(reduceMotion ? nil : SettingsMotion.change, value: preferences.configuration.sizePreset)
        .animation(reduceMotion ? nil : SettingsMotion.change, value: preferences.configuration.backgroundMode)
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

private struct LyricsAppearancePreviewCard: View {
    let configuration: LyricsRenderConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsCorners.hero, style: .continuous)
        let fontSize = CGFloat(configuration.resolvedFontSize(width: 320, height: 600))
        let auxSize = max(12, min(18, fontSize * CGFloat(configuration.auxiliaryScale ?? 0.52)))

        VStack(alignment: .leading, spacing: 6) {
            if configuration.romanization && configuration.romanizationFirst {
                Text("render.romanization")
                    .font(.system(size: auxSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .transition(.opacity)
            }

            Text("render.sample")
                .font(.system(size: fontSize, weight: configuration.bold ? .bold : .regular))
                .tracking(configuration.tracking)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: false, vertical: true)

            if configuration.romanization && !configuration.romanizationFirst {
                Text("render.romanization")
                    .font(.system(size: auxSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .transition(.opacity)
            }

            if configuration.translation {
                Text("render.translation")
                    .font(.system(size: auxSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [Color(red: 0.14, green: 0.14, blue: 0.22), Color(red: 0.08, green: 0.09, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: shape
        )
        .overlay {
            shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .animation(reduceMotion ? nil : SettingsMotion.change, value: configuration)
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
                SettingsGroup {
                    if let coordinator {
                        Text(coordinator.romanizationStatus.isEmpty ? "等待歌词" : coordinator.romanizationStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        SettingsDivider(inset: 16)
                    }
                    SettingsTextButton(title: "重新生成当前歌词", icon: "arrow.clockwise", iconColor: MusicProductStyle.accent, inGroup: true) {
                        coordinator?.regenerateRomanization()
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "准备导出当前罗马音 TTML", icon: "doc", iconColor: MusicProductStyle.accent, inGroup: true) {
                        guard let ttml = coordinator?.document?.romanizationTTMLTrack?.ttml else {
                            message = String(localized: "当前歌词没有生成的罗马音 TTML")
                            return
                        }
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("romanization.ttml")
                            try Data(ttml.utf8).write(to: url, options: .atomic)
                            exportedTTMLFile = url
                            message = String(localized: "罗马音 TTML 已准备好导出")
                        } catch { message = String(localized: "TTML 导出失败") }
                    }
                    if let exportedTTMLFile {
                        SettingsDivider()
                        ShareLink(item: exportedTTMLFile) {
                            SettingsRowLabel(title: "分享罗马音 TTML", icon: "square.and.arrow.up", iconColor: MusicProductStyle.accent)
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "清理生成缓存", icon: "trash", iconColor: MusicProductStyle.accent, inGroup: true) {
                        Task {
                            do {
                                try await LyricsRomanizationEngine.shared.clearGeneratedCache()
                                coordinator?.regenerateRomanization()
                                message = String(localized: "生成缓存已清理")
                            } catch { message = String(localized: "缓存清理失败") }
                        }
                    }
                }
            }

            SettingsSection("读音纠错") {
                SettingsGroup {
                    SettingsTextButton(title: "导入纠错字典", icon: "square.and.arrow.down", iconColor: MusicProductStyle.accent, inGroup: true) {
                        importing = true
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "准备导出纠错字典", icon: "square.and.arrow.up", iconColor: MusicProductStyle.accent, inGroup: true) {
                        Task {
                            do {
                                let data = try await LyricsRomanizationEngine.shared.exportOverrides()
                                let url = FileManager.default.temporaryDirectory.appendingPathComponent("romanization-overrides.json")
                                try data.write(to: url, options: .atomic)
                                exportedFile = url
                                message = String(localized: "纠错字典已准备好导出")
                            } catch { message = String(localized: "导出失败") }
                        }
                    }
                    if let exportedFile {
                        SettingsDivider()
                        ShareLink(item: exportedFile) {
                            SettingsRowLabel(title: "分享纠错字典", icon: "square.and.arrow.up", iconColor: MusicProductStyle.accent)
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "重置纠错字典", icon: "arrow.counterclockwise", role: .destructive, inGroup: true) {
                        confirmResetOverrides = true
                    }
                }
            }

            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
        .navigationTitle("自动音译")
        .confirmationDialog("删除已导入的读音纠错？", isPresented: $confirmResetOverrides, titleVisibility: .visible) {
            Button("重置纠错字典", role: .destructive) {
                Task {
                    do {
                        try await LyricsRomanizationEngine.shared.resetOverrides()
                        coordinator?.regenerateRomanization()
                        message = String(localized: "纠错字典已重置")
                    } catch { message = String(localized: "重置失败") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { selection in
            guard case let .success(url) = selection else { message = String(localized: "导入已取消"); return }
            Task {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    try await LyricsRomanizationEngine.shared.importOverrides(data)
                    coordinator?.regenerateRomanization()
                    message = String(localized: "纠错字典已导入")
                } catch { message = String(localized: "字典格式错误，现有纠错保留") }
            }
        }
    }
}
