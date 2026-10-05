import Observation
import SwiftUI
import UIKit

/// One presentation owner for the floating controls and their destination sheets.
/// Opening controls does not suspend the lyric or artwork display clocks.
@MainActor @Observable
final class LyricsQuickSettingsPresentation {
    enum Destination: String, Identifiable {
        case devices, queue, lyricsSearch, appearance, lyricsSources
        var id: String { rawValue }
    }

    private(set) var isPresented = false
    var destination: Destination? {
        didSet { if oldValue != nil, destination == nil { destinationIsDismissing = true } }
    }
    private(set) var focusRevision = 0
    @ObservationIgnored private var revision = 0
    private var destinationIsDismissing = false

    var suspendsPage: Bool {
        destination == .devices || destination == .lyricsSearch
    }

    func open(reduceMotion: Bool) {
        guard destination == nil, !destinationIsDismissing else { return }
        revision += 1
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9)) {
            isPresented = true
        }
    }

    func close(reduceMotion: Bool, then target: Destination? = nil) {
        revision += 1
        let transaction = revision
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), completionCriteria: .removed) {
            isPresented = false
        } completion: { [weak self] in
            guard let self, self.revision == transaction else { return }
            self.destination = target
            if target == nil { self.focusRevision += 1 }
        }
    }

    func destinationDidDismiss() {
        destination = nil
        destinationIsDismissing = false
        focusRevision += 1
    }

    func reset() {
        revision += 1
        isPresented = false
        destination = nil
        destinationIsDismissing = false
    }
}

struct LyricsQuickSettingsButton: View {
    let presentation: LyricsQuickSettingsPresentation
    var systemImage = "ellipsis"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        Button { presentation.open(reduceMotion: reduceMotion) } label: {
            Label("render.options", systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lyricsDisplayOptions")
        .accessibilityFocused($focused)
        .onChange(of: presentation.focusRevision) { focused = true }
    }
}

/// Overlay rather than a layout inset: the lyric viewport and its renderer keep
/// their original size and identity while controls are opened or closed.
struct LyricsQuickSettingsPresenter: ViewModifier {
    @Bindable var model: AppModel
    @Bindable var presentation: LyricsQuickSettingsPresentation
    var artworkStatus: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!presentation.isPresented)
            .accessibilityHidden(presentation.isPresented)
            .overlay {
                GeometryReader { geometry in
                    if presentation.isPresented {
                        ZStack(alignment: .bottom) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { presentation.close(reduceMotion: reduceMotion) }
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("lyricsQuickSettingsOutside")
                            LyricsQuickSettingsPanel(model: model, presentation: presentation, artworkStatus: artworkStatus)
                                .frame(width: min(UIDevice.current.userInterfaceIdiom == .pad ? 560 : .infinity,
                                                  max(0, geometry.size.width - 40)))
                                // GeometryReader needs a concrete proposal. A maxHeight
                                // alone can collapse to the header's intrinsic height,
                                // leaving the scroll viewport with zero height.
                                .frame(height: max(0, geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom) * 0.6)
                                .padding(.bottom, geometry.safeAreaInsets.bottom + 12)
                                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .sheet(item: $presentation.destination, onDismiss: { presentation.destinationDidDismiss() }) { target in
                destination(target)
            }
            .onChange(of: model.selectedMusicService) { presentation.reset() }
            .onDisappear { presentation.reset() }
    }

    @ViewBuilder private func destination(_ target: LyricsQuickSettingsPresentation.Destination) -> some View {
        switch target {
        case .devices:
            DevicePickerView(model: model).task { await model.loadDevices() }
        case .queue:
            if model.selectedMusicService == .netease { NetEaseQueueView(model: model) }
            else { AppleMusicQueueView(model: model) }
        case .lyricsSearch:
            LyricsSearchView(coordinator: model.lyrics)
        case .appearance:
            NavigationStack {
                LyricsAppearanceView(preferences: model.renderPreferences, coordinator: model.lyrics)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { closeDestination } }
            }
        case .lyricsSources:
            NavigationStack {
                LyricsSettingsView(coordinator: model.lyrics)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { closeDestination } }
            }
        }
    }

    private var closeDestination: some View {
        Button("common.done") { presentation.destination = nil }
            .accessibilityIdentifier("closeLyricsQuickSettingsDestination")
    }
}

struct LyricsQuickSettingsPanel: View {
    @Bindable var model: AppModel
    let presentation: LyricsQuickSettingsPresentation
    var artworkStatus: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 100
    @GestureState private var drag: CGFloat = 0
    @AccessibilityFocusState private var titleFocused: Bool

    private var configuration: LyricsRenderConfiguration { model.renderPreferences.configuration }
    private var canManageLyrics: Bool { model.lyrics.track != nil && model.lyrics.settings.enabled }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        appearance
                        typography
                        playback
                        lyricActions
                        more
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("lyricsQuickSettingsScroll")
                // Bootstrap with the available viewport, so lazy contents can
                // become visible before their first measurement arrives.
                .frame(height: max(0, min(contentHeight > 0 ? contentHeight : geometry.size.height,
                                          geometry.size.height - headerHeight)))
            }
            .frame(maxWidth: .infinity)
            .modifier(QuickSettingsGlassSurface())
            .modifier(QuickSettingsSDR())
            .offset(y: reduceMotion ? 0 : drag)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { titleFocused = true }
        .accessibilityAction(.escape) { presentation.close(reduceMotion: reduceMotion) }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.45)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel(Text("quickSettings.closeHint"))
                .accessibilityIdentifier("lyricsQuickSettingsHandle")
                .accessibilityAction { presentation.close(reduceMotion: reduceMotion) }
                .gesture(DragGesture(minimumDistance: 8)
                    .updating($drag) { value, state, _ in
                        if value.translation.height > abs(value.translation.width) { state = max(0, value.translation.height) }
                    }
                    .onEnded { value in
                        if value.translation.height > abs(value.translation.width),
                           value.translation.height > 60 || value.predictedEndTranslation.height > 120
                        { presentation.close(reduceMotion: reduceMotion) }
                    })
            HStack {
                Text("quickSettings.title").font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("lyricsQuickSettingsPanel")
                    .accessibilityFocused($titleFocused)
                Spacer()
                Button { presentation.close(reduceMotion: reduceMotion) } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("common.done"))
                .accessibilityIdentifier("closeLyricsQuickSettings")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var appearance: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
            Button {
                model.renderPreferences.configuration.showLyrics.toggle()
            } label: {
                Label(configuration.showLyrics ? "render.hideLyrics" : "render.showLyrics", systemImage: "text.quote")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityValue(Text(LocalizedStringKey(configuration.showLyrics ? "quickSettings.on" : "quickSettings.off")))
            .accessibilityIdentifier("toggleLyricsVisibility")
            Toggle("render.translation", isOn: setting(\.translation)).frame(minHeight: 44).accessibilityIdentifier("quickSettingsTranslation")
            Toggle("render.romanization", isOn: setting(\.romanization)).frame(minHeight: 44).accessibilityIdentifier("quickSettingsRomanization")
            Toggle("quickSettings.hdr", isOn: Binding(get: { configuration.hdr?.enabled ?? false }, set: {
                model.renderPreferences.configuration.hdr = .init(enabled: $0)
            })).frame(minHeight: 44).accessibilityIdentifier("quickSettingsHDR")
        }
        .font(.subheadline.weight(.medium))
        .tint(.green)
        .buttonStyle(.plain)
    }

    private var typography: some View {
        section("quickSettings.appearance") {
            Toggle("appearance.autoSize", isOn: Binding(get: { configuration.sizePreset != nil }, set: {
                model.renderPreferences.configuration.sizePreset = $0 ? .medium : nil
            })).frame(minHeight: 44).accessibilityIdentifier("quickSettingsAutoSize")
            if configuration.sizePreset != nil {
                Picker("render.sizePreset", selection: Binding(get: { configuration.sizePreset ?? .medium }, set: {
                    model.renderPreferences.configuration.sizePreset = $0
                })) {
                    ForEach(AMLLLyricSizePreset.allCases, id: \.self) { preset in
                        Text(LocalizedStringKey("render.size." + preset.rawValue)).tag(preset)
                    }
                }
                .frame(minHeight: 44).accessibilityIdentifier("quickSettingsSizePreset")
            } else {
                Picker("render.fontSize", selection: Binding(get: { configuration.fontSize }, set: {
                    model.renderPreferences.configuration.sizePreset = nil
                    model.renderPreferences.configuration.fontSize = $0
                })) {
                    if ![26.0, 32, 40, 48].contains(configuration.fontSize) {
                        Text(String(format: "%.0f pt", configuration.fontSize)).tag(configuration.fontSize)
                    }
                    Text("render.small").tag(26.0); Text("render.medium").tag(32.0)
                    Text("render.large").tag(40.0); Text("render.extraLarge").tag(48.0)
                }
                .frame(minHeight: 44).accessibilityIdentifier("quickSettingsFontSize")
            }
            Picker("quickSettings.background", selection: Binding(get: { configuration.backgroundMode ?? .mesh }, set: {
                model.renderPreferences.configuration.backgroundMode = $0
            })) {
                Text("Mesh 网格").tag(LyricsRenderConfiguration.BackgroundMode.mesh)
                Text("Mesh网格（取色模式2）").tag(LyricsRenderConfiguration.BackgroundMode.meshColorMode2)
                Text("Pixi 流动封面").tag(LyricsRenderConfiguration.BackgroundMode.pixi)
                Text("流动背景").tag(LyricsRenderConfiguration.BackgroundMode.flowing)
                Text("纯色").tag(LyricsRenderConfiguration.BackgroundMode.solid)
                Text("双色渐变").tag(LyricsRenderConfiguration.BackgroundMode.gradient)
            }
            .frame(minHeight: 44).accessibilityIdentifier("quickSettingsBackground")
        }
    }

    private var playback: some View {
        section("quickSettings.playback") {
            route("player.devices", symbol: "airplayaudio", to: .devices)
            if model.selectedMusicService != .spotify, let snapshot = model.playbackSnapshot {
                route("quickSettings.queue", symbol: "list.bullet", to: .queue)
                Toggle("quickSettings.shuffle", isOn: Binding(get: { snapshot.shuffleEnabled }, set: { enabled in
                    Task { await model.setShuffle(enabled) }
                })).frame(minHeight: 44).disabled(model.isPerformingAction)
                    .accessibilityIdentifier("quickSettingsShuffle")
                Picker("quickSettings.repeat", selection: Binding(get: { snapshot.repeatMode }, set: { mode in
                    Task { await model.setRepeat(mode) }
                })) {
                    ForEach(MusicRepeatMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(minHeight: 44).disabled(model.isPerformingAction)
                    .accessibilityIdentifier("quickSettingsRepeat")
            }
        }
    }

    private var lyricActions: some View {
        section("quickSettings.lyrics") {
            route("lyrics.find", symbol: "magnifyingglass", to: .lyricsSearch)
            Button("lyrics.refresh", systemImage: "arrow.clockwise") { model.lyrics.reload(force: true) }
                .frame(minHeight: 44)
            Button("lyrics.automatic", systemImage: "arrow.uturn.backward") { model.lyrics.restoreAutomatic() }
                .frame(minHeight: 44)
            LabeledContent("quickSettings.offset", value: String(format: "%+.1f s", model.lyrics.selection.offset))
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(String(format: "%+.1f s", model.lyrics.selection.offset)))
                .accessibilityIdentifier("quickSettingsOffset")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { offsetButtons }
                VStack(alignment: .leading, spacing: 4) { offsetButtons }
            }
        }.disabled(!canManageLyrics)
    }

    @ViewBuilder private var offsetButtons: some View {
        Button("−0.1 s") { model.lyrics.setOffset(model.lyrics.selection.offset - 0.1) }
            .accessibilityLabel(Text("lyrics.offset.minus")).accessibilityIdentifier("quickSettingsOffsetMinus")
            .frame(minWidth: 70, minHeight: 44)
        Button("+0.1 s") { model.lyrics.setOffset(model.lyrics.selection.offset + 0.1) }
            .accessibilityLabel(Text("lyrics.offset.plus")).accessibilityIdentifier("quickSettingsOffsetPlus")
            .frame(minWidth: 70, minHeight: 44)
        Button("lyrics.offset.zero") { model.lyrics.setOffset(0) }.frame(minHeight: 44)
            .accessibilityIdentifier("quickSettingsOffsetReset")
    }

    private var more: some View {
        section("quickSettings.more") {
            route("render.settings", symbol: "slider.horizontal.3", to: .appearance)
            route("lyrics.settings", symbol: "text.badge.checkmark", to: .lyricsSources)
            if let artworkStatus { Text(artworkStatus).font(.footnote).foregroundStyle(.secondary) }
            if let document = model.lyrics.document, let credit = configuration.credits.content(in: document) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("render.creditLabel." + credit.kind.rawValue))
                    Text(credit.names.joined(separator: " · "))
                }.font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func setting(_ key: WritableKeyPath<LyricsRenderConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { model.renderPreferences.configuration[keyPath: key] }, set: { model.renderPreferences.configuration[keyPath: key] = $0 })
    }

    private func route(_ title: LocalizedStringKey, symbol: String, to target: LyricsQuickSettingsPresentation.Destination) -> some View {
        Button { presentation.close(reduceMotion: reduceMotion, then: target) } label: {
            HStack { Label(title, systemImage: symbol); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("quickSettingsRoute." + target.rawValue)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }.font(.subheadline).buttonStyle(.plain).tint(.green)
    }
}

private struct QuickSettingsGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency { content.background(Color(uiColor: .secondarySystemBackground), in: shape) }
            else if #available(iOS 26.0, *) { content.glassEffect(.regular, in: shape) }
            else { content.background(.regularMaterial, in: shape) }
        }
        .overlay { if contrast == .increased { shape.strokeBorder(.white.opacity(0.6), lineWidth: 1) } }
    }
}

private struct QuickSettingsSDR: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.allowedDynamicRange(.standard) }
        else { content }
    }
}
