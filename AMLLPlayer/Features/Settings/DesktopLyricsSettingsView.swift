import SwiftUI

struct DesktopLyricsSettingsView: View {
    let model: AppModel
    @Bindable var preferences: DesktopLyricsPreferences
    @AppStorage(DesktopLyricsController.autoStartKey) private var autoStart = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let settings = preferences.settings
        return SettingsPage {
            SettingsSection("desktopLyrics.preview") {
                DesktopLyricsPreview(configuration: model.renderPreferences.configuration, settings: settings,
                                     artworkURL: model.playbackSnapshot?.item?.artworkURL)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityLabel(Text("desktopLyrics.preview"))
                    .accessibilityIdentifier("desktopLyricsPreview")
            }

            SettingsSection("desktopLyrics.appearance", footer: "desktopLyrics.aspect.help") {
                SettingsGroup {
                    Picker("desktopLyrics.mode", selection: $preferences.settings.mode.hapticSelection()) {
                        ForEach(DesktopLyricsSettings.DisplayMode.allCases, id: \.self) { mode in
                            Text(LocalizedStringKey(mode.label)).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("desktopLyricsMode")
                    SettingsDivider(inset: 16)
                    Toggle("desktopLyrics.fitHeight", isOn: $preferences.settings.fitsContent.hapticSelection())
                        .accessibilityIdentifier("desktopLyricsFitHeight")
                    SettingsDivider(inset: 16)
                    Picker("desktopLyrics.alignment", selection: $preferences.settings.alignment.hapticSelection()) {
                        ForEach(DesktopLyricsSettings.Alignment.allCases, id: \.self) { alignment in
                            Text(LocalizedStringKey(alignment.label)).tag(alignment)
                        }
                    }
                    .accessibilityIdentifier("desktopLyricsAlignment")
                    SettingsDivider(inset: 16)
                    if settings.mode == .scrolling && !settings.fitsContent {
                        Picker("desktopLyrics.aspect", selection: $preferences.settings.aspect.hapticSelection()) {
                            ForEach(DesktopLyricsSettings.Aspect.scrollingOptions, id: \.self) { aspect in
                                Text(LocalizedStringKey(aspect.label)).tag(aspect)
                            }
                        }
                        .accessibilityIdentifier("desktopLyricsAspect")
                        SettingsDivider(inset: 16)
                    }
                    SettingsSliderRow("desktopLyrics.fontSize", valueText: "\(Int(settings.fontSize)) pt",
                                      value: $preferences.settings.fontSize, in: DesktopLyricsSettings.fontRange,
                                      sliderIdentifier: "desktopLyricsFontSize")
                    if settings.mode == .singleLine {
                        SettingsDivider(inset: 16)
                        Toggle("render.translation", isOn: $preferences.settings.singleLineTranslation.hapticSelection())
                            .accessibilityIdentifier("desktopLyricsSingleLineTranslation")
                        SettingsDivider(inset: 16)
                        Toggle("render.romanization", isOn: $preferences.settings.singleLineRomanization.hapticSelection())
                            .accessibilityIdentifier("desktopLyricsSingleLineRomanization")
                    }
                }
            }

            SettingsSection("desktopLyrics.motion") {
                SettingsGroup {
                    if settings.mode == .scrolling {
                        Picker("desktopLyrics.transition", selection: $preferences.settings.transition.hapticSelection()) {
                            ForEach(DesktopLyricsSettings.Transition.allCases, id: \.self) { transition in
                                Text(LocalizedStringKey(transition.label)).tag(transition)
                            }
                        }
                        .accessibilityIdentifier("desktopLyricsTransition")
                        SettingsDivider(inset: 16)
                        SettingsSliderRow("desktopLyrics.blur", valueText: settings.blurStrength.formatted(.number.precision(.fractionLength(0 ... 1))),
                                          value: $preferences.settings.blurStrength, in: DesktopLyricsSettings.blurRange,
                                          step: 0.5, disabled: settings.transition != .blur,
                                          sliderIdentifier: "desktopLyricsBlurStrength")
                        SettingsDivider(inset: 16)
                    }
                    Toggle("desktopLyrics.wordHighlight", isOn: $preferences.settings.wordHighlight.hapticSelection())
                        .accessibilityIdentifier("desktopLyricsWordHighlight")
                }
            }

            SettingsSection {
                SettingsGroup {
                    Toggle(isOn: $autoStart.hapticSelection()) {
                        SettingsIconToggleLabel(title: "desktopLyrics.autoStart", icon: "pip.enter",
                                                color: MusicProductStyle.accent)
                    }
                    .accessibilityIdentifier("autoDesktopLyrics")
                }
                SettingsTextButton(title: "desktopLyrics.reset", icon: "arrow.counterclockwise") {
                    withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                        preferences.settings = .init()
                        autoStart = false
                    }
                    AppHaptics.shared.play(.selection)
                }
                .accessibilityIdentifier("resetDesktopLyrics")
            }
        }
        .tint(MusicProductStyle.accent)
        .navigationTitle("desktopLyrics.title")
    }
}

private struct DesktopLyricsPreview: View {
    let configuration: LyricsRenderConfiguration
    let settings: DesktopLyricsSettings
    let artworkURL: URL?
    @Environment(\.scenePhase) private var phase
    @State private var startedAt = Date()
    @State private var adaptiveRatio: CGFloat?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase != .active)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            DesktopLyricsPreviewSurface(configuration: configuration, settings: settings, artworkURL: artworkURL,
                                        elapsed: elapsed, playing: phase == .active, adaptiveRatio: $adaptiveRatio)
                .id(settings.outputAspect)
        }
        .aspectRatio(settings.fitsContent ? adaptiveRatio ?? (320 / DesktopLyricsAdaptiveHeight.minimum)
                     : CGFloat(settings.outputAspect.ratio), contentMode: .fit)
        .background(Color(white: 0.075))
    }
}

private struct DesktopLyricsPreviewSurface: UIViewRepresentable {
    let configuration: LyricsRenderConfiguration
    let settings: DesktopLyricsSettings
    let artworkURL: URL?
    let elapsed: Double
    let playing: Bool
    @Binding var adaptiveRatio: CGFloat?

    func makeCoordinator() -> DesktopLyricsFrames { .init(aspect: settings.outputAspect) }

    func makeUIView(context: Context) -> DesktopLyricsSourceView {
        let view = DesktopLyricsSourceView()
        view.isUserInteractionEnabled = false
        view.install(context.coordinator.layer)
        return view
    }

    func updateUIView(_ view: DesktopLyricsSourceView, context: Context) {
        guard view.window != nil else { return }
        let position = elapsed.truncatingRemainder(dividingBy: Self.duration)
        var item = Self.item
        item.artworkURL = artworkURL
        let snapshot = PlaybackSnapshot(item: item, isPlaying: playing, position: position,
                                        duration: Self.duration, device: nil, restrictions: .unrestricted,
                                        source: .nativeAudio, sampledAtUptime: ProcessInfo.processInfo.systemUptime)
        let frame = LyricsPlaybackFrame(snapshot: snapshot, position: position, playing: playing,
                                        seekRevision: Int(elapsed / Self.duration), pending: nil,
                                        confirmation: nil, legacySeekPosition: nil)
        var appearance = configuration
        appearance.translation = true
        appearance.romanization = true
        context.coordinator.render(frame: frame, lyrics: Self.document, revision: 1, offset: 0,
                                   configuration: appearance, settings: settings, animates: true)
        if settings.fitsContent {
            let size = context.coordinator.pixelSize
            let ratio = size.width / size.height
            if adaptiveRatio != ratio {
                Task { @MainActor in adaptiveRatio = ratio }
            }
        }
    }

    private static let duration = 12.0
    private static let item = PlaybackItem(id: "preview", uri: "desktop-lyrics:preview", title: "", artists: [],
                                          albumTitle: nil, duration: duration, isEpisode: false, isAdvertisement: false)
    private static let document: LyricsDocument = {
        let samples = [
            (["風が ", "そっと ", "歌う"], "风轻轻地唱", ["Kaze ga ", "sotto ", "utau"]),
            (["月が ", "道を ", "照らす"], "月光照亮路途", ["Tsuki ga ", "michi o ", "terasu"]),
            (["波が ", "夜に ", "溶ける"], "海浪融进夜色", ["Nami ga ", "yoru ni ", "tokeru"])
        ]
        let lines = samples.enumerated().map { index, sample in
            let start = Double(index) * 4
            let words = sample.0.enumerated().map { syllable, text in
                LyricWord(text: text, start: start + Double(syllable), end: start + Double(syllable == 2 ? 4 : syllable + 1))
            }
            return LyricLine(id: "desktop-preview-\(index)", text: sample.0.joined(), start: start, end: start + 4,
                             words: words, translation: sample.1, romanization: sample.2.joined(), precision: .word)
        }
        let cues = zip(lines, samples).enumerated().map { index, pair -> RomanizationTTMLTrack.Cue in
            let (body, sample) = pair
            let start = body.start + 0.2
            let words = sample.2.enumerated().map { syllable, text in
                LyricWord(text: text, start: start + Double(syllable), end: syllable == 2 ? body.end : start + Double(syllable + 1))
            }
            let line = LyricLine(id: body.id + "-roman", text: sample.2.joined(), start: start, end: body.end,
                                 words: words, precision: .word)
            return .init(sourceLineIndex: index, line: line, tokens: [])
        }
        return LyricsDocument(candidate: .init(source: .apple, sourceID: "desktop-preview", title: "", artists: []),
                              lines: lines, language: "ja", selectionReason: "preview",
                              romanizationTTMLTrack: .init(ttml: "", cues: cues))
    }()
}
