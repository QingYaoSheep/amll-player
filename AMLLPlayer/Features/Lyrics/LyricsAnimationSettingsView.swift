import SwiftUI
import UIKit

struct LyricsAnimationSettingsView: View {
    @Bindable var preferences: LyricsRenderPreferences

    private var blossom: LyricsBlossomAnimationOptions {
        preferences.configuration.appleMusicAnimation ?? .init()
    }

    private var blurLevel: Binding<Double> {
        Binding(get: {
            Double(LyricsAnimationBlur.level(preferences.configuration.lyricBlurLevel,
                                             isPad: UIDevice.current.userInterfaceIdiom == .pad))
        }, set: { preferences.configuration.lyricBlurLevel = Int($0.rounded()) })
    }

    private func blossomBinding(_ control: LyricsBlossomAnimationOptions.Control) -> Binding<Int> {
        Binding(get: { blossom[keyPath: control.key] }, set: { value in
            var next = blossom
            next[keyPath: control.key] = value
            preferences.configuration.appleMusicAnimation = next.validated()
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("逐字动画风格", selection: Binding(
                    get: { preferences.configuration.animationStyle },
                    set: { preferences.configuration.selectAnimationStyle($0) }
                )) {
                    ForEach(LyricsAnimationStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }.pickerStyle(.menu)
                    .accessibilityIdentifier("lyricsAnimationStyle")
                    .accessibilityValue(preferences.configuration.animationStyle.title)
            } footer: {
                Text("两种风格分别保存动画选项和模糊等级。首次切换时复制其他动画选项，模糊等级使用设备默认值。")
            }
            if preferences.configuration.animationStyle == .appleMusic164 {
                Section("歌词风格") {
                    Picker("歌词和逻辑预置", selection: Binding(
                        get: { blossom.matchedPreset },
                        set: { value in
                            var next = blossom; next.apply(value)
                            preferences.configuration.appleMusicAnimation = next
                        }
                    )) {
                        ForEach(LyricsBlossomAnimationOptions.Preset.allCases) { preset in
                            Text(preset.title).tag(preset).disabled(preset == .custom)
                        }
                    }.accessibilityIdentifier("blossomPreset").accessibilityValue(blossom.matchedPreset.title)
                    ForEach(LyricsBlossomAnimationOptions.Control.allCases, id: \.rawValue) { control in
                        Picker(selection: blossomBinding(control)) {
                            ForEach(control.choices, id: \.value) { choice in
                                Text(choice.title).tag(choice.value)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(control.title)
                                Text(control.help).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("blossom." + control.rawValue)
                            .accessibilityValue(control.choices.first { $0.value == blossom[keyPath: control.key] }?.title ?? "")
                    }
                    Stepper(value: Binding(get: { blossom.maximumLines }, set: { count in
                        var next = blossom; next.maximumLines = count
                        preferences.configuration.appleMusicAnimation = next
                    }), in: 2 ... 3) {
                        LabeledContent("最高选择句行数", value: String(blossom.maximumLines))
                    }.disabled(!blossom.limitsSelection)
                        .accessibilityIdentifier("blossom.maximum")
                    Text("27 选择句逻辑不限制行数；其他逻辑可选择 2 或 3 行。单独修改选项后，预置会自动显示为自定义。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("动画选项") {
                Toggle("render.blurInactive", isOn: $preferences.configuration.blurInactive)
                LabeledContent("歌词模糊程度", value: "\(Int(blurLevel.wrappedValue)) 级")
                Slider(value: blurLevel, in: 1 ... 10, step: 1)
                    .disabled(!preferences.configuration.blurInactive)
                    .accessibilityLabel("歌词模糊程度")
                    .accessibilityValue("\(Int(blurLevel.wrappedValue)) 级")
                    .accessibilityIdentifier("lyricBlurLevel")
                Toggle("render.emphasizeWords", isOn: $preferences.configuration.emphasizeWords)
                Toggle("render.spring", isOn: $preferences.configuration.enableSpring)
                Toggle("render.scale", isOn: $preferences.configuration.enableScale)
                    .accessibilityIdentifier("animationStyleScale")
                Toggle("render.hidePassedLines", isOn: $preferences.configuration.hidePassedLines)
                Toggle("render.marquee", isOn: $preferences.configuration.marquee)
                if preferences.configuration.animationStyle != .appleMusic164 {
                    LabeledContent("render.gradientWidth", value: String(format: "%.2f em", preferences.configuration.gradientWidth))
                    Slider(value: $preferences.configuration.gradientWidth, in: 0 ... 1, step: 0.05)
                        .accessibilityLabel(Text("render.gradientWidth"))
                    LabeledContent("render.advance", value: String(format: "%.1f s", preferences.configuration.advance))
                    Slider(value: $preferences.configuration.advance, in: 0 ... 1, step: 0.1)
                        .accessibilityLabel(Text("render.advance"))
                    Text("render.advanceHelp").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("render.anchor", value: String(format: "%.0f%%", preferences.configuration.anchor * 100))
                Slider(value: $preferences.configuration.anchor, in: 0.2 ... 0.7, step: 0.05)
                    .accessibilityLabel(Text("render.anchor"))
            } footer: {
                Text("对齐位置由两种风格共用；沉浸式歌词保持 18% 对齐。")
            }
            Section {
                Button("恢复当前风格默认值") { preferences.configuration.restoreCurrentAnimationDefaults() }
                    .accessibilityIdentifier("resetLyricsAnimationStyle")
            }
            Section("风格来源") {
                Text("提前选择和渐变窗口由风格管理。16.4 和 16.4 advance 的外观参考 iPadOS 16.4 还原资料与实测截图。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .tint(Color("MusicAccent"))
        .navigationTitle("精细动画调整")
    }
}
