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
        SettingsPage {
            SettingsSection {
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
                    .settingsSurface()
            }
            if preferences.configuration.animationStyle == .appleMusic164 {
                SettingsSection("歌词风格") {
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
                        .settingsSurface()
                    ForEach(LyricsBlossomAnimationOptions.Control.allCases, id: \.rawValue) { control in
                        Picker(selection: blossomBinding(control)) {
                            ForEach(control.choices, id: \.value) { choice in
                                Text(choice.title).tag(choice.value)
                            }
                        } label: {
                            Text(control.title)
                        }.accessibilityIdentifier("blossom." + control.rawValue)
                            .accessibilityValue(control.choices.first { $0.value == blossom[keyPath: control.key] }?.title ?? "")
                            .settingsSurface()
                    }
                    Stepper(value: Binding(get: { blossom.maximumLines }, set: { count in
                        var next = blossom; next.maximumLines = count
                        preferences.configuration.appleMusicAnimation = next
                    }), in: 2 ... 3) {
                        LabeledContent("最高选择句行数", value: String(blossom.maximumLines))
                    }.disabled(!blossom.limitsSelection)
                        .accessibilityIdentifier("blossom.maximum")
                        .settingsSurface()
                }
            }
            SettingsSection("动画选项") {
                Toggle("render.blurInactive", isOn: $preferences.configuration.blurInactive.hapticSelection())
                    .settingsSurface()
                LabeledContent("歌词模糊程度", value: "\(Int(blurLevel.wrappedValue)) 级")
                Slider(value: blurLevel, in: 1 ... 10, step: 1)
                    .disabled(!preferences.configuration.blurInactive)
                    .accessibilityLabel("歌词模糊程度")
                    .accessibilityValue("\(Int(blurLevel.wrappedValue)) 级")
                    .accessibilityIdentifier("lyricBlurLevel")
                Toggle("render.emphasizeWords", isOn: $preferences.configuration.emphasizeWords.hapticSelection())
                    .settingsSurface()
                Toggle("render.spring", isOn: $preferences.configuration.enableSpring.hapticSelection())
                    .settingsSurface()
                Toggle("render.scale", isOn: $preferences.configuration.enableScale.hapticSelection())
                    .settingsSurface()
                    .accessibilityIdentifier("animationStyleScale")
                Toggle("render.hidePassedLines", isOn: $preferences.configuration.hidePassedLines.hapticSelection())
                    .settingsSurface()
                Toggle("render.marquee", isOn: $preferences.configuration.marquee.hapticSelection())
                    .settingsSurface()
                if preferences.configuration.animationStyle != .appleMusic164 {
                    LabeledContent("render.gradientWidth", value: String(format: "%.2f em", preferences.configuration.gradientWidth))
                    Slider(value: $preferences.configuration.gradientWidth, in: 0 ... 1, step: 0.05)
                        .accessibilityLabel(Text("render.gradientWidth"))
                    LabeledContent("render.advance", value: String(format: "%.1f s", preferences.configuration.advance))
                    Slider(value: $preferences.configuration.advance, in: 0 ... 1, step: 0.1)
                        .accessibilityLabel(Text("render.advance"))
                }
            }
            SettingsSection {
                LabeledContent("render.anchor", value: String(format: "%.0f%%", preferences.configuration.anchor * 100))
                Slider(value: $preferences.configuration.anchor, in: 0.2 ... 0.7, step: 0.05)
                    .accessibilityLabel(Text("render.anchor"))
            }
            SettingsSection {
                SettingsTextButton(title: "恢复当前风格默认值", icon: "arrow.counterclockwise") {
                    preferences.configuration.restoreCurrentAnimationDefaults()
                }
                    .accessibilityIdentifier("resetLyricsAnimationStyle")
            }
        }
        .tint(Color("MusicAccent"))
        .navigationTitle("精细动画调整")
    }
}
