import SwiftUI

struct LyricsAppearanceView: View {
    @Bindable var preferences: LyricsRenderPreferences
    var body: some View {
        Form {
            Section("render.profile") {
                Picker("render.profile", selection: Binding(
                    get: { preferences.profile },
                    set: { preferences.activate($0) }
                )) {
                    Text("render.profile.appleMusic26").tag(LyricsPresentationProfile.appleMusic26)
                    Text("render.profile.custom").tag(LyricsPresentationProfile.custom)
                }
                Text("render.profile.help").font(.footnote).foregroundStyle(.secondary)
            }
            Section("render.typography") {
                Text("render.sample").font(.system(size: preferences.configuration.fontSize, weight: preferences.configuration.bold ? .bold : .medium))
                    .tracking(preferences.configuration.tracking).frame(minHeight: 70)
                Picker("render.fontSize", selection: $preferences.configuration.fontSize) {
                    Text("render.small").tag(26.0); Text("render.medium").tag(32.0)
                    Text("render.large").tag(40.0); Text("render.extraLarge").tag(48.0)
                }
                Toggle("render.bold", isOn: $preferences.configuration.bold)
                LabeledContent("render.tracking", value: String(format: "%.1f", preferences.configuration.tracking))
                Slider(value: $preferences.configuration.tracking, in: -1 ... 3, step: 0.25).accessibilityLabel(Text("render.tracking"))
                Toggle("render.translation", isOn: $preferences.configuration.translation)
                Toggle("render.romanization", isOn: $preferences.configuration.romanization)
                Toggle("render.romanizationFirst", isOn: $preferences.configuration.romanizationFirst)
            }
            Section("render.motion") {
                Toggle("render.blurInactive", isOn: $preferences.configuration.blurInactive)
                Toggle("render.emphasizeWords", isOn: $preferences.configuration.emphasizeWords)
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
            Section("render.layout") {
                Toggle("render.showLyrics", isOn: $preferences.configuration.showLyrics)
                Picker("render.coverLayout", selection: $preferences.configuration.coverLayout) {
                    ForEach(LyricsRenderConfiguration.CoverLayout.allCases, id: \.self) { layout in
                        Text(LocalizedStringKey("render.layout." + layout.rawValue)).tag(layout)
                    }
                }
                Toggle("render.showTitle", isOn: $preferences.configuration.showTitle)
                Toggle("render.showArtist", isOn: $preferences.configuration.showArtist)
                Toggle("render.showAlbum", isOn: $preferences.configuration.showAlbum)
                Toggle("render.showControls", isOn: $preferences.configuration.showControls)
                Toggle("render.volume", isOn: $preferences.configuration.showVolume)
                Picker("render.credits", selection: $preferences.configuration.credits) {
                    ForEach(LyricsRenderConfiguration.Credits.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey("render.credits." + mode.rawValue)).tag(mode)
                    }
                }
            }
            Section("render.background") {
                LabeledContent("render.backgroundBlur", value: String(format: "%.0f pt", preferences.configuration.backgroundBlur))
                Slider(value: $preferences.configuration.backgroundBlur, in: 0 ... 80, step: 5).accessibilityLabel(Text("render.backgroundBlur"))
                Text("render.backgroundHelp").font(.footnote).foregroundStyle(.secondary)
            }
            Button("render.reset") { preferences.restoreAMLLDefaults() }
        }
        .navigationTitle("render.settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
