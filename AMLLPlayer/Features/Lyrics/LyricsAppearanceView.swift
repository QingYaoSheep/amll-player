import SwiftUI
import UniformTypeIdentifiers

struct LyricsAppearanceView: View {
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

    private func adjustment(_ title: LocalizedStringKey, key: WritableKeyPath<LyricsRenderConfiguration, Double?>, fallback: Double, range: ClosedRange<Double>, step: Double = 1) -> some View {
        let binding = Binding(get: { preferences.configuration[keyPath: key] ?? fallback },
                              set: { preferences.configuration[keyPath: key] = $0 })
        return VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: "%.2g", binding.wrappedValue))
            Slider(value: binding, in: range, step: step).accessibilityLabel(Text(title))
        }
    }

    var body: some View {
        Form {
            Section("appearance.quick") {
                Text("appearance.quickHelp").font(.footnote).foregroundStyle(.secondary)
                Button("appearance.reading") {
                    preferences.configuration.fontSize = 32
                    preferences.configuration.sizePreset = nil
                    preferences.configuration.bold = true
                    preferences.configuration.translation = true
                    preferences.configuration.romanization = false
                }
                Button("appearance.calm") {
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
                    Text("render.profile.help").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("render.typography") {
                Text("render.sample").font(.system(size: preferences.configuration.resolvedFontSize(width: 320, height: 600), weight: preferences.configuration.bold ? .bold : .regular))
                    .tracking(preferences.configuration.tracking).frame(minHeight: 70)
                Text("appearance.previewHelp").font(.caption).foregroundStyle(.secondary)
                Toggle("appearance.autoSize", isOn: Binding(get: { preferences.configuration.sizePreset != nil }, set: { preferences.configuration.sizePreset = $0 ? .medium : nil }))
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
                Toggle("render.bold", isOn: $preferences.configuration.bold)
                Toggle("render.translation", isOn: $preferences.configuration.translation)
                Toggle("render.romanization", isOn: $preferences.configuration.romanization)
                NavigationLink("日语／韩语自动音译") {
                    RomanizationSettingsView(coordinator: coordinator)
                }
                DisclosureGroup("appearance.textDetails") {
                    LabeledContent("render.tracking", value: String(format: "%.1f", preferences.configuration.tracking))
                    Slider(value: $preferences.configuration.tracking, in: -1 ... 3, step: 0.25).accessibilityLabel(Text("render.tracking"))
                    Toggle("render.romanizationFirst", isOn: $preferences.configuration.romanizationFirst)
                    if preferences.profile == .amll {
                        adjustment("appearance.padding", key: \.horizontalPadding, fallback: 20, range: 12 ... 60, step: 2)
                        adjustment("appearance.spacing", key: \.paragraphSpacing, fallback: 0, range: 0 ... 60, step: 2)
                        adjustment("appearance.auxSize", key: \.auxiliaryScale, fallback: 0.5, range: 0.3 ... 1, step: 0.05)
                    }
                }
            }
            Section("render.motion") {
                Toggle("render.blurInactive", isOn: $preferences.configuration.blurInactive)
                Toggle("render.emphasizeWords", isOn: $preferences.configuration.emphasizeWords)
                Toggle("render.spring", isOn: $preferences.configuration.enableSpring)
                Toggle("render.scale", isOn: $preferences.configuration.enableScale)
                DisclosureGroup("appearance.motionDetails") {
                    Toggle("render.hidePassedLines", isOn: $preferences.configuration.hidePassedLines)
                    Toggle("render.marquee", isOn: $preferences.configuration.marquee)
                    LabeledContent("render.gradientWidth", value: String(format: "%.2f em", preferences.configuration.gradientWidth))
                    Slider(value: $preferences.configuration.gradientWidth, in: 0 ... 1, step: 0.05)
                        .accessibilityLabel(Text("render.gradientWidth"))
                    LabeledContent("render.advance", value: String(format: "%.1f s", preferences.configuration.advance))
                    Slider(value: $preferences.configuration.advance, in: 0 ... 1, step: 0.1).accessibilityLabel(Text("render.advance"))
                    LabeledContent("render.anchor", value: String(format: "%.0f%%", preferences.configuration.anchor * 100))
                    Slider(value: $preferences.configuration.anchor, in: 0.2 ... 0.7, step: 0.05).accessibilityLabel(Text("render.anchor"))
                    Text("render.advanceHelp").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("render.layout") {
                Toggle("render.showLyrics", isOn: $preferences.configuration.showLyrics)
                if preferences.profile == .amll {
                    Toggle("appearance.metadata", isOn: Binding(get: { preferences.configuration.showMetadata ?? true }, set: { preferences.configuration.showMetadata = $0 }))
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
                    Toggle("render.showTitle", isOn: $preferences.configuration.showTitle)
                    Toggle("render.showArtist", isOn: $preferences.configuration.showArtist)
                    Toggle("render.showAlbum", isOn: $preferences.configuration.showAlbum)
                    Toggle("render.showControls", isOn: $preferences.configuration.showControls)
                    Toggle("render.volume", isOn: $preferences.configuration.showVolume)
                    if preferences.profile == .custom {
                        Picker("render.credits", selection: $preferences.configuration.credits) {
                            ForEach(LyricsRenderConfiguration.Credits.allCases, id: \.self) { mode in
                                Text(LocalizedStringKey("render.credits." + mode.rawValue)).tag(mode)
                            }
                        }
                    }
                }
            }
            Section("render.background") {
                Picker("背景模式", selection: Binding(get: { preferences.configuration.backgroundMode ?? .mesh },
                                                  set: { preferences.configuration.backgroundMode = $0 }))
                {
                    Text("Mesh 网格").tag(LyricsRenderConfiguration.BackgroundMode.mesh)
                    Text("Pixi 流动封面").tag(LyricsRenderConfiguration.BackgroundMode.pixi)
                    Text("纯色").tag(LyricsRenderConfiguration.BackgroundMode.solid)
                    Text("双色渐变").tag(LyricsRenderConfiguration.BackgroundMode.gradient)
                }
                if preferences.profile == .amll {
                    adjustment("appearance.dimming", key: \.backgroundDimming, fallback: 0.16, range: 0 ... 0.8, step: 0.04)
                }
                if preferences.configuration.backgroundMode == nil || preferences.configuration.backgroundMode == .mesh {
                    LabeledContent("render.backgroundBlur", value: String(format: "%.0f pt", preferences.configuration.backgroundBlur))
                    Slider(value: $preferences.configuration.backgroundBlur, in: 0 ... 80, step: 5).accessibilityLabel(Text("render.backgroundBlur"))
                    Text("render.backgroundHelp").font(.footnote).foregroundStyle(.secondary)
                } else if preferences.configuration.backgroundMode == .pixi {
                    Text("Pixi 使用原版多层封面、固定模糊和形变滤镜；歌词动效不受背景帧率影响。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ColorPicker("背景颜色", selection: backgroundColorBinding(\.backgroundColor), supportsOpacity: false)
                    if preferences.configuration.backgroundMode == .gradient {
                        ColorPicker("底部颜色", selection: backgroundColorBinding(\.backgroundGradientEnd), supportsOpacity: false)
                    }
                    Text("纯色默认使用原版 #111111；渐变从顶部颜色过渡至底部颜色。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("高级视觉") {
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
                    Text("仅处理歌词来源明确标记的不雅词，使用 * 遮罩；不会自动识别词语或修改原始歌词。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                DisclosureGroup("歌词高光") {
                    Toggle("当前句 HDR 高光", isOn: Binding(
                        get: { preferences.configuration.hdr?.enabled ?? false },
                        set: { preferences.configuration.hdr = .init(enabled: $0) }
                    ))
                    LyricsHDRStatusView().frame(minHeight: 44)
                    Text("仅当前句已唱部分使用扩展亮度，上限为 SDR 白的 2 倍。关闭 HDR 后仍保留文字混色；不会提高系统亮度。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                DisclosureGroup("动态专辑封面") {
                    Toggle("启用动态封面", isOn: Binding(
                        get: { preferences.configuration.animatedArtwork?.enabled ?? false },
                        set: { value in
                            var settings = preferences.configuration.animatedArtwork ?? .init()
                            settings.enabled = value
                            preferences.configuration.animatedArtwork = settings
                        }
                    ))
                    Toggle("允许蜂窝网络加载", isOn: Binding(
                        get: { preferences.configuration.animatedArtwork?.allowCellular ?? false },
                        set: { value in
                            var settings = preferences.configuration.animatedArtwork ?? .init()
                            settings.allowCellular = value
                            preferences.configuration.animatedArtwork = settings
                        }
                    ))
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
                    if preferences.configuration.animatedArtwork?.presentation == .immersive {
                        Toggle("封面倒影", isOn: Binding(
                            get: { preferences.configuration.animatedArtwork?.reflection ?? false },
                            set: { value in
                                var settings = preferences.configuration.animatedArtwork ?? .init()
                                settings.reflection = value
                                preferences.configuration.animatedArtwork = settings
                            }
                        ))
                        Text("从同一视频的底部画面生成柔和倒影；不会额外播放一份视频。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("默认仅在 Wi-Fi 下加载，缓存上限 200 MB。方形布局仅使用方形视频；沉浸布局选择竖形视频，在竖屏背景显示。无对应资源、离线或减少动态效果时回退静态图，横屏恢复普通布局。封面视频始终静音。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("清理动态封面缓存", role: .destructive) { ArtworkMediaCache.shared.clear() }
                }
            }
            Button("render.reset", role: .destructive) { confirmReset = true }
        }
        .navigationTitle("render.settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("appearance.resetHelp", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("render.reset", role: .destructive) { preferences.restoreAMLLDefaults() }
        }
    }
}

private struct RomanizationSettingsView: View {
    var coordinator: LyricsCoordinator?
    @State private var importing = false
    @State private var exportedFile: URL?
    @State private var message = ""

    var body: some View {
        Form {
            Section("自动音译") {
                Text("日语和韩语歌词优先离线生成逐词音译。无法可靠生成时使用歌词来源提供的音译。显示仍由上一级的音译开关控制。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let coordinator {
                    Text(coordinator.romanizationStatus.isEmpty ? "等待歌词" : coordinator.romanizationStatus)
                        .font(.footnote)
                }
                Button("重新生成当前歌词") { coordinator?.regenerateRomanization() }
                Button("清理生成缓存") {
                    Task {
                        do {
                            try await LyricsRomanizationEngine.shared.clearGeneratedCache()
                            coordinator?.regenerateRomanization()
                            message = "生成缓存已清理"
                        } catch { message = "缓存清理失败" }
                    }
                }
            }
            Section("读音纠错") {
                Text("支持 Mineradio 的 ja／ko JSON 字典。导入失败时保留当前字典；修改不会改写原歌词。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("导入纠错字典") { importing = true }
                Button("准备导出纠错字典") {
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
                if let exportedFile { ShareLink("分享纠错字典", item: exportedFile) }
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
            if !message.isEmpty { Text(message).font(.footnote) }
        }
        .navigationTitle("自动音译")
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
