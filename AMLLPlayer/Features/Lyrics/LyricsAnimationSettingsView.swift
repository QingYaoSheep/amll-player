import SwiftUI

struct LyricsAnimationSettingsView: View {
    @Bindable var preferences: LyricsRenderPreferences

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
                }.accessibilityIdentifier("lyricsAnimationStyle")
            } footer: {
                Text("风格作用于逐字与整行动效。两种风格分别保存动画选项，首次切换时复制当前设置。")
            }
            Section("动画选项") {
                Toggle("render.blurInactive", isOn: $preferences.configuration.blurInactive)
                Toggle("render.emphasizeWords", isOn: $preferences.configuration.emphasizeWords)
                Toggle("render.spring", isOn: $preferences.configuration.enableSpring)
                Toggle("render.scale", isOn: $preferences.configuration.enableScale)
                Toggle("render.hidePassedLines", isOn: $preferences.configuration.hidePassedLines)
                Toggle("render.marquee", isOn: $preferences.configuration.marquee)
                LabeledContent("render.gradientWidth", value: String(format: "%.2f em", preferences.configuration.gradientWidth))
                Slider(value: $preferences.configuration.gradientWidth, in: 0 ... 1, step: 0.05)
                    .accessibilityLabel(Text("render.gradientWidth"))
                LabeledContent("render.advance", value: String(format: "%.1f s", preferences.configuration.advance))
                Slider(value: $preferences.configuration.advance, in: 0 ... 1, step: 0.1)
                    .accessibilityLabel(Text("render.advance"))
                Text("render.advanceHelp").font(.footnote).foregroundStyle(.secondary)
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
                Text("Apple Music 16.4 风格基于 LyricsBlossom 的已核实动画资料适配。尚未确认的动效沿用 AMLL，不代表 Apple Music 官方实现。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("精细动画调整")
    }
}
