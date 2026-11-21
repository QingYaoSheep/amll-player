import Observation
import SwiftUI
import UIKit

/// Owns both levels of the docked panel, including its dismissal transition.
@MainActor @Observable
final class LyricsQuickSettingsPresentation {
    static let motionAnimation = Animation.spring(response: 0.32, dampingFraction: 0.9)
    enum Destination: String, Identifiable {
        case devices, queue, listeningRoom, lyricsSearch, appearance, lyricsSources
        var id: String { rawValue }
    }

    private(set) var isPresented = false
    private(set) var destination: Destination?
    private(set) var returnsToSettings = false
    private(set) var focusRevision = 0
    private(set) var roomFocusRevision = 0
    @ObservationIgnored private var revision = 0

    var suspendsPage: Bool {
        isPresented && (destination == .devices || destination == .lyricsSearch)
    }

    func open(reduceMotion: Bool) {
        guard !isPresented else { return }
        present(nil, reduceMotion: reduceMotion)
    }

    func show(_ target: Destination, reduceMotion: Bool) {
        guard isPresented, destination == nil else { return }
        revision += 1
        returnsToSettings = true
        withAnimation(reduceMotion ? MusicProductMotion.change : Self.motionAnimation) {
            destination = target
        }
    }

    func back(reduceMotion: Bool) {
        guard isPresented, destination != nil, returnsToSettings else { return }
        revision += 1
        withAnimation(reduceMotion ? MusicProductMotion.change : Self.motionAnimation) {
            destination = nil
        }
    }

    func openRoom(reduceMotion: Bool) {
        guard !isPresented else { return }
        present(.listeningRoom, reduceMotion: reduceMotion)
    }

    private func present(_ target: Destination?, reduceMotion: Bool) {
        revision += 1
        returnsToSettings = false
        withAnimation(reduceMotion ? MusicProductMotion.change : Self.motionAnimation) {
            destination = target
            isPresented = true
        }
    }

    func close(reduceMotion: Bool) {
        guard isPresented else { return }
        revision += 1
        let transaction = revision
        let openedFromRoom = destination == .listeningRoom && !returnsToSettings
        withAnimation(reduceMotion ? MusicProductMotion.change : Self.motionAnimation, completionCriteria: .removed) {
            isPresented = false
        } completion: { [weak self] in
            guard let self, self.revision == transaction else { return }
            self.destination = nil
            self.returnsToSettings = false
            if openedFromRoom { self.roomFocusRevision += 1 }
            else { self.focusRevision += 1 }
        }
    }

    func reset() {
        revision += 1
        isPresented = false
        destination = nil
        returnsToSettings = false
    }

    func navigation(reduceMotion: Bool) -> LyricsQuickSettingsNavigation {
        let transaction = revision
        return LyricsQuickSettingsNavigation(
            back: returnsToSettings ? { [weak self] in self?.back(reduceMotion: reduceMotion) } : nil,
            close: { [weak self] in
                guard let self, self.revision == transaction else { return }
                self.close(reduceMotion: reduceMotion)
            }
        )
    }
}

struct LyricsQuickSettingsButton: View {
    let presentation: LyricsQuickSettingsPresentation
    var systemImage = "ellipsis"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lyricsPageControlsEnabled) private var controlsEnabled
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        if controlsEnabled {
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
}

/// Overlay rather than a layout inset: the lyric viewport and its renderer keep
/// their original size and identity while controls are opened or closed.
struct LyricsQuickSettingsPresenter: ViewModifier {
    @Bindable var model: AppModel
    @Bindable var presentation: LyricsQuickSettingsPresentation
    var artworkStatus: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var floatingPanel: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    func body(content: Content) -> some View {
        ZStack {
            content.ignoresSafeArea(.keyboard)
                .accessibilityHidden(presentation.isPresented)
                .allowsHitTesting(!presentation.isPresented)
            // The modal hit plane is a sibling of the live page. Disabling
            // hit testing on the page before attaching an overlay can also
            // disable SwiftUI controls installed by that overlay.
            Group {
                GeometryReader { geometry in
                    // Keep the transition's parent mounted. Otherwise the
                    // conditional container can remove the panel before its
                    // own insertion/removal transition gets to run.
                    ZStack(alignment: .bottom) {
                        if presentation.isPresented {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { presentation.close(reduceMotion: reduceMotion) }
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("lyricsQuickSettingsOutside")
                            let insets = geometry.safeAreaInsets
                            let available = max(0, geometry.size.height - insets.top - insets.bottom)
                            LyricsQuickSettingsPanel(model: model, presentation: presentation, artworkStatus: artworkStatus,
                                floating: floatingPanel, screenInsets: insets, primaryHeight: available * 0.6)
                                .frame(width: floatingPanel ? min(560, max(0, geometry.size.width - 40)) : geometry.size.width)
                                // GeometryReader needs a concrete proposal. A maxHeight
                                // alone can collapse to the header's intrinsic height,
                                // leaving the scroll viewport with zero height.
                                .frame(height: available * (presentation.destination == nil ? 0.6 : 0.8))
                                .animation(reduceMotion ? nil : LyricsQuickSettingsPresentation.motionAnimation,
                                           value: presentation.destination)
                                .padding(.bottom, floatingPanel ? insets.bottom + 12 : 0)
                                .transition(reduceMotion ? .opacity : .offset(y: geometry.size.height))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
            // A drag on our floating handle belongs to this panel, not the
            // full-screen player's system zoom dismissal underneath it.
            .interactiveDismissDisabled(presentation.isPresented)
            .onChange(of: model.selectedMusicService) { presentation.reset() }
            .onDisappear { presentation.reset() }
    }
}

struct LyricsQuickSettingsPanel: View {
    @Bindable var model: AppModel
    let presentation: LyricsQuickSettingsPresentation
    var artworkStatus: String? = nil
    let floating: Bool
    let screenInsets: EdgeInsets
    let primaryHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 56
    @State private var drag: CGFloat = 0
    @State private var compositingDiagnosticCopied = false
    @State private var artworkDebug = ImmersiveArtworkDebugStore.shared
    @GestureState private var dragIsActive = false
    @AccessibilityFocusState private var titleFocused: Bool
    @AccessibilityFocusState private var focusedRoute: LyricsQuickSettingsPresentation.Destination?

    private var configuration: LyricsRenderConfiguration { model.renderPreferences.configuration }
    private var canManageLyrics: Bool { model.lyrics.track != nil && model.lyrics.settings.enabled }
    private var surfaceInsets: EdgeInsets {
        floating ? EdgeInsets() : EdgeInsets(top: 0, leading: screenInsets.leading,
                                              bottom: screenInsets.bottom, trailing: screenInsets.trailing)
    }

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                handle
                ZStack(alignment: .top) {
                    primaryContent(height: max(0, primaryHeight - 44))
                        .opacity(presentation.destination == nil ? 1 : 0)
                        .accessibilityHidden(presentation.destination != nil)
                        .allowsHitTesting(presentation.destination == nil)
                    if let target = presentation.destination {
                        destination(target)
                            .environment(\.lyricsQuickSettingsNavigation, presentation.navigation(reduceMotion: reduceMotion))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }
                .animation(MusicProductMotion.change, value: presentation.destination)
            }
            .frame(maxWidth: .infinity)
            // Extend the surface while leaving the scroll viewport and its
            // hit targets inside the safe area.
            .padding(surfaceInsets)
            .modifier(QuickSettingsGlassSurface(floating: floating))
            .padding(EdgeInsets(top: 0, leading: -surfaceInsets.leading,
                                bottom: -surfaceInsets.bottom, trailing: -surfaceInsets.trailing))
            .modifier(QuickSettingsSDR())
            .offset(y: reduceMotion ? 0 : drag)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { if presentation.destination == nil { titleFocused = true } }
        .onChange(of: presentation.destination) { old, new in
            if new == nil, presentation.isPresented { focusedRoute = old }
            else { focusedRoute = nil }
        }
        .onChange(of: dragIsActive) { _, active in
            // onEnded is not called for a system-cancelled gesture. Gesture
            // activity resets on cancellation, but the released offset must
            // remain intact if a successful dismissal is already underway.
            if !active, presentation.isPresented, drag > 0 { returnToRest() }
        }
        .accessibilityAction(.escape) { presentation.close(reduceMotion: reduceMotion) }
    }

    private func primaryContent(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            primaryHeader
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appearance
                    typography
                    playback
                    globalTiming
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
            .frame(height: max(0, min(contentHeight > 0 ? contentHeight : height, height - headerHeight)))
        }
    }

    @ViewBuilder private func destination(_ target: LyricsQuickSettingsPresentation.Destination) -> some View {
        switch target {
        case .devices:
            DevicePickerView(model: model).task { await model.loadDevices() }
        case .queue:
            if model.selectedMusicService == .netease { NetEaseQueueView(model: model) }
            else { AppleMusicQueueView(model: model) }
        case .listeningRoom:
            NetEaseRoomView(model: model)
        case .lyricsSearch:
            LyricsSearchView(coordinator: model.lyrics)
        case .appearance:
            NavigationStack {
                LyricsAppearanceView(preferences: model.renderPreferences, coordinator: model.lyrics)
            }
        case .lyricsSources:
            NavigationStack { LyricsSettingsView(coordinator: model.lyrics) }
        }
    }

    private var handle: some View {
        Capsule().fill(.white.opacity(0.45)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel(Text("quickSettings.closeHint"))
                .accessibilityIdentifier("lyricsQuickSettingsHandle")
                .accessibilityAction { presentation.close(reduceMotion: reduceMotion) }
                // Measure against the screen, not the handle that moves with
                // this gesture, so following the finger cannot reduce its delta.
                .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .updating($dragIsActive) { _, active, _ in active = true }
                    .onChanged { value in
                        if value.translation.height > abs(value.translation.width) || drag > 0 {
                            // Follow the finger directly, including a reversal.
                            // Do not interpolate between gesture samples.
                            withTransaction(Transaction(animation: nil)) {
                                drag = max(0, value.translation.height)
                            }
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > abs(value.translation.width),
                           value.translation.height > 60 || value.predictedEndTranslation.height > 120
                        {
                            // Keep the released position through removal so
                            // the exit continues downward instead of snapping
                            // back when GestureState would reset to zero.
                            presentation.close(reduceMotion: reduceMotion)
                        } else {
                            returnToRest()
                        }
                    })
    }

    private var primaryHeader: some View {
        HStack {
            Text("quickSettings.title").font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("lyricsQuickSettingsPanel")
                .accessibilityFocused($titleFocused)
            Spacer()
            Button { presentation.close(reduceMotion: reduceMotion) } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .buttonStyle(MusicContentButtonStyle())
            .accessibilityLabel(Text("common.done"))
            .accessibilityIdentifier("closeLyricsQuickSettings")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func returnToRest() {
        withAnimation(reduceMotion ? nil : LyricsQuickSettingsPresentation.motionAnimation) { drag = 0 }
    }

    private var appearance: some View {
        controls {
            appearanceButton("render.showLyrics", symbol: "text.quote", id: "toggleLyricsVisibility", value: setting(\.showLyrics))
            appearanceButton("render.translation", symbol: "character.bubble", id: "quickSettingsTranslation", value: setting(\.translation))
            appearanceButton("render.romanization", symbol: "abc", id: "quickSettingsRomanization", value: setting(\.romanization))
            appearanceButton("quickSettings.hdr", symbol: "sun.max.fill", id: "quickSettingsHDR", value: Binding(get: { configuration.hdr?.enabled ?? false }, set: {
                model.renderPreferences.configuration.hdr = .init(enabled: $0)
            }))
            appearanceButton("quickSettings.immersiveLyrics", symbol: "rectangle.topthird.inset.filled", id: "quickSettingsImmersiveLyrics", value: Binding(get: { configuration.immersiveLyrics == true }, set: {
                model.renderPreferences.configuration.immersiveLyrics = $0
            }))
        }
    }

    private func appearanceButton(_ title: LocalizedStringKey, symbol: String, id: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            QuickSettingsControlLabel(title: title, symbol: symbol,
                indicator: value.wrappedValue ? "checkmark.circle.fill" : "circle", selected: value.wrappedValue)
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(LocalizedStringKey(value.wrappedValue ? "quickSettings.on" : "quickSettings.off")))
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var typography: some View {
        section("quickSettings.appearance") {
            controls {
                appearanceButton("appearance.autoSize", symbol: "textformat.size", id: "quickSettingsAutoSize", value: Binding(get: { configuration.sizePreset != nil }, set: {
                    model.renderPreferences.configuration.sizePreset = $0 ? .medium : nil
                }))
            }
            if configuration.sizePreset != nil {
                Picker("render.sizePreset", selection: Binding(get: { configuration.sizePreset ?? .medium }, set: {
                    model.renderPreferences.configuration.sizePreset = $0
                })) {
                    ForEach(AMLLLyricSizePreset.allCases, id: \.self) { preset in
                        Text(LocalizedStringKey("render.size." + preset.rawValue)).tag(preset)
                    }
                }
                .modifier(QuickSettingsValueSurface()).accessibilityIdentifier("quickSettingsSizePreset")
                .accessibilityValue(Text(LocalizedStringKey("render.size." + (configuration.sizePreset ?? .medium).rawValue)))
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
                .modifier(QuickSettingsValueSurface()).accessibilityIdentifier("quickSettingsFontSize")
                .accessibilityValue(Text(String(format: "%.0f pt", configuration.fontSize)))
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
            .modifier(QuickSettingsValueSurface()).accessibilityIdentifier("quickSettingsBackground")
            .accessibilityValue(Text(backgroundTitle))
        }
    }

    private var playback: some View {
        section("quickSettings.playback") {
            controls {
                route(model.selectedMusicService == .spotify ? "player.devices" : "AirPlay", symbol: "airplayaudio", to: .devices)
                if model.selectedMusicService == .netease {
                    route(model.netEasePlayback.isListeningTogether ? "一起听房间" : "与好友一起听",
                          symbol: "person.2", to: .listeningRoom)
                        .accessibilityIdentifier("quickSettingsNetEaseListeningRoom")
                }
                if model.selectedMusicService != .spotify, let snapshot = model.playbackSnapshot {
                    let busy = model.isPerformingAction || (model.selectedMusicService == .netease && !model.netEasePlayback.canEditPersonalQueue)
                    route("quickSettings.queue", symbol: "list.bullet", to: .queue)
                    appearanceButton("quickSettings.shuffle", symbol: "shuffle", id: "quickSettingsShuffle", value: Binding(get: { snapshot.shuffleEnabled }, set: { enabled in
                        Task { await model.setShuffle(enabled) }
                    })).disabled(busy)
                    QuickSettingsRepeatMenu(owner: ObjectIdentifier(model), service: model.selectedMusicService,
                                            mode: snapshot.repeatMode, busy: busy) { mode in
                        Task { await model.setRepeat(mode) }
                    }.equatable()
                }
            }
            if model.selectedMusicService == .netease, model.netEasePlayback.isPersonalFM {
                Text("私人 FM 自动续播，退出后可使用随机与循环。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var globalTiming: some View {
        section("quickSettings.globalDelay") {
            Text(String(format: "%+.1f s", model.lyrics.globalDelay)).monospacedDigit()
                .accessibilityIdentifier("quickSettingsGlobalDelayValue")
            Slider(value: Binding(get: { model.lyrics.globalDelay }, set: { model.lyrics.setGlobalDelay($0) }),
                   in: -10 ... 10, step: 0.1)
                .accessibilityLabel(Text("quickSettings.globalDelay"))
                .accessibilityValue(Text(String(format: "%+.1f s", model.lyrics.globalDelay)))
                .accessibilityIdentifier("quickSettingsGlobalDelay")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { globalDelayButtons }
                VStack(alignment: .leading, spacing: 8) { globalDelayButtons }
            }
            Text("quickSettings.globalDelayHelp").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var globalDelayButtons: some View {
        timingButton("−0.1 s", id: "quickSettingsGlobalDelayMinus") { model.lyrics.setGlobalDelay(model.lyrics.globalDelay - 0.1) }
            .accessibilityLabel(Text("lyrics.offset.minus"))
        timingButton("+0.1 s", id: "quickSettingsGlobalDelayPlus") { model.lyrics.setGlobalDelay(model.lyrics.globalDelay + 0.1) }
            .accessibilityLabel(Text("lyrics.offset.plus"))
        timingButton("lyrics.offset.zero", id: "quickSettingsGlobalDelayReset") { model.lyrics.setGlobalDelay(0) }
    }

    private var lyricActions: some View {
        section("quickSettings.lyrics") {
            controls {
                route("lyrics.find", symbol: "magnifyingglass", to: .lyricsSearch)
                action("lyrics.refresh", symbol: "arrow.clockwise") { model.lyrics.reload(force: true) }
                action("lyrics.automatic", symbol: "arrow.uturn.backward") { model.lyrics.restoreAutomatic() }
            }
            LabeledContent("quickSettings.offset", value: String(format: "%+.1f s", model.lyrics.selection.offset))
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(String(format: "%+.1f s", model.lyrics.selection.offset)))
                .accessibilityIdentifier("quickSettingsOffset")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { offsetButtons }
                VStack(alignment: .leading, spacing: 8) { offsetButtons }
            }
        }.disabled(!canManageLyrics)
    }

    @ViewBuilder private var offsetButtons: some View {
        timingButton("−0.1 s", id: "quickSettingsOffsetMinus") { model.lyrics.setOffset(model.lyrics.selection.offset - 0.1) }
            .accessibilityLabel(Text("lyrics.offset.minus"))
        timingButton("+0.1 s", id: "quickSettingsOffsetPlus") { model.lyrics.setOffset(model.lyrics.selection.offset + 0.1) }
            .accessibilityLabel(Text("lyrics.offset.plus"))
        timingButton("lyrics.offset.zero", id: "quickSettingsOffsetReset") { model.lyrics.setOffset(0) }
    }

    private var more: some View {
        section("quickSettings.more") {
            controls {
                appearanceButton("quickSettings.artworkDebugButton", symbol: "rectangle.on.rectangle", id: "quickSettingsArtworkDebugButton",
                    value: Binding(get: { artworkDebug.showsButton }, set: { artworkDebug.showsButton = $0 }))
                route("render.settings", symbol: "slider.horizontal.3", to: .appearance)
                route("lyrics.settings", symbol: "text.badge.checkmark", to: .lyricsSources)
                action(LocalizedStringKey(compositingDiagnosticCopied ? "quickSettings.diagnosticCopied" : "quickSettings.copyCompositingDiagnostics"),
                       symbol: "doc.on.doc") {
                    UIPasteboard.general.string = LyricsCompositingDiagnostics.text(configuration: configuration,
                        profile: model.renderPreferences.profile)
                    compositingDiagnosticCopied = true
                }
                .accessibilityIdentifier("quickSettingsCopyCompositingDiagnostics")
            }
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

    private var backgroundTitle: String {
        switch configuration.backgroundMode ?? .mesh {
        case .mesh: "Mesh 网格"
        case .meshColorMode2: "Mesh网格（取色模式2）"
        case .pixi: "Pixi 流动封面"
        case .flowing: "流动背景"
        case .solid: "纯色"
        case .gradient: "双色渐变"
        }
    }

    private func route(_ title: LocalizedStringKey, symbol: String, to target: LyricsQuickSettingsPresentation.Destination) -> some View {
        action(title, symbol: symbol, indicator: "chevron.forward") {
            presentation.show(target, reduceMotion: reduceMotion)
        }
        .accessibilityFocused($focusedRoute, equals: target)
        .accessibilityIdentifier("quickSettingsRoute." + target.rawValue)
    }

    private func action(_ title: LocalizedStringKey, symbol: String, indicator: String? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            QuickSettingsControlLabel(title: title, symbol: symbol, indicator: indicator)
        }
        .buttonStyle(MusicContentButtonStyle())
    }

    private func timingButton(_ title: LocalizedStringKey, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).fixedSize(horizontal: true, vertical: false)
                .modifier(QuickSettingsValueSurface())
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityIdentifier(id)
    }

    private func controls<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                 count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8, content: content)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }.font(.subheadline).buttonStyle(.plain).tint(MusicProductStyle.accent)
    }
}

/// Navigation chrome applied only to the root of an embedded destination.
/// Pushed views keep their own back button and toolbar.
struct LyricsQuickSettingsNavigation {
    let back: (() -> Void)?
    let close: () -> Void
}

extension EnvironmentValues {
    @Entry var lyricsQuickSettingsNavigation: LyricsQuickSettingsNavigation? = nil
}

extension View {
    func lyricsQuickSettingsDestination() -> some View {
        modifier(LyricsQuickSettingsDestinationChrome())
    }
}

private struct LyricsQuickSettingsDestinationChrome: ViewModifier {
    @Environment(\.lyricsQuickSettingsNavigation) private var navigation

    func body(content: Content) -> some View {
        if let navigation {
            content
                .scrollContentBackground(.hidden)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .tint(MusicProductStyle.accent)
                .toolbar {
                    if let back = navigation.back {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("quickSettings.back", systemImage: "chevron.backward", action: back)
                                .labelStyle(.iconOnly)
                                .tint(.primary)
                                .accessibilityIdentifier("backLyricsQuickSettingsDestination")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("common.done", systemImage: "xmark", action: navigation.close)
                            .labelStyle(.iconOnly)
                            .tint(.primary)
                            .accessibilityIdentifier("closeLyricsQuickSettingsDestination")
                    }
                }
        } else {
            content
        }
    }
}

// Progress snapshots update while this native menu is open. Only control state
// changes may rebuild its binding and presentation, not the advancing clock.
private struct QuickSettingsRepeatMenu: View, Equatable {
    let owner: ObjectIdentifier
    let service: MusicServiceID
    let mode: MusicRepeatMode
    let busy: Bool
    let select: @MainActor @Sendable (MusicRepeatMode) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.service == rhs.service && lhs.mode == rhs.mode && lhs.busy == rhs.busy
    }

    var body: some View {
        Menu {
            ForEach(MusicRepeatMode.allCases, id: \.self) { option in
                Button { select(option) } label: {
                    if mode == option { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
                .accessibilityIdentifier("quickSettingsRepeatOption." + option.rawValue)
            }
        } label: {
            QuickSettingsControlLabel(title: "quickSettings.repeat", symbol: "repeat",
                detail: mode.title, indicator: "chevron.up.chevron.down", selected: mode != .off)
        }
        .disabled(busy)
        .accessibilityLabel(Text("quickSettings.repeat"))
        .accessibilityIdentifier("quickSettingsRepeat")
        .accessibilityValue(Text(mode.title))
    }
}

struct QuickSettingsControlLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var detail: String? = nil
    var indicator: String? = nil
    var selected = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let indicator {
                Image(systemName: indicator).font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? MusicProductStyle.accent : .secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .foregroundStyle(.primary)
        .background(reduceTransparency ? Color(uiColor: .secondarySystemBackground) :
            colorScheme == .dark ? .white.opacity(0.09) : Color(uiColor: .tertiarySystemFill), in: shape)
        .background { if selected { shape.fill(MusicProductStyle.filledAccent.opacity(0.24)) } }
        .overlay { shape.strokeBorder(selected ? MusicProductStyle.accent.opacity(0.7) : .white.opacity(0.08)) }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.48)
    }
}

private struct QuickSettingsValueSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.padding(.horizontal, 12).frame(minHeight: 44)
            .background(reduceTransparency ? Color(uiColor: .tertiarySystemBackground) : .white.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct QuickSettingsGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let floating: Bool

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: floating ? 28 : 32,
                                           bottomLeadingRadius: floating ? 28 : 0,
                                           bottomTrailingRadius: floating ? 28 : 0,
                                           topTrailingRadius: floating ? 28 : 32)
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
