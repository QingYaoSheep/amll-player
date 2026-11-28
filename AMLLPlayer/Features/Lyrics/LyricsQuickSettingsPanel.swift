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

    func openQueue(reduceMotion: Bool) {
        guard !isPresented else { return }
        present(.queue, reduceMotion: reduceMotion)
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
            Button {
                AppHaptics.shared.play(.selection)
                presentation.open(reduceMotion: reduceMotion)
            } label: {
                Label("render.options", systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MusicContentButtonStyle())
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
    @State private var sheetDrag: CGFloat = 0
    private var floatingPanel: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var scrimOpacity: Double {
        if reduceMotion { return 0.22 }
        let progress = max(0, min(1, 1 - max(0, sheetDrag) / 280))
        return 0.24 * progress
    }

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
                            Color.black.opacity(scrimOpacity)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { presentation.close(reduceMotion: reduceMotion) }
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("lyricsQuickSettingsOutside")
                                .transition(.opacity)
                            let insets = geometry.safeAreaInsets
                            let available = max(0, geometry.size.height - insets.top - insets.bottom)
                            LyricsQuickSettingsPanel(
                                model: model,
                                presentation: presentation,
                                artworkStatus: artworkStatus,
                                floating: floatingPanel,
                                screenInsets: insets,
                                primaryHeight: available * 0.6,
                                drag: $sheetDrag
                            )
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
        .onChange(of: presentation.isPresented) { _, presented in
            if !presented { sheetDrag = 0 }
        }
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
    @Binding var drag: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 56
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
                        .scaleEffect(presentation.destination == nil || reduceMotion ? 1 : 0.97, anchor: .center)
                        .opacity(presentation.destination == nil ? 1 : 0)
                        .accessibilityElement(children: .contain)
                        .accessibilityHidden(presentation.destination != nil)
                        .allowsHitTesting(presentation.destination == nil)
                    if let target = presentation.destination {
                        destination(target)
                            .environment(\.lyricsQuickSettingsNavigation, presentation.navigation(reduceMotion: reduceMotion))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .bottom)))
                            .zIndex(1)
                    }
                }
                .animation(reduceMotion ? nil : MusicProductMotion.change, value: presentation.destination)
            }
            .frame(maxWidth: .infinity)
            // Extend the surface while leaving the scroll viewport and its
            // hit targets inside the safe area.
            .padding(surfaceInsets)
            .background {
                // Sample the page once, behind both the handle and the content.
                Color.clear
                    .modifier(QuickSettingsGlassSurface(floating: floating))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
            if !active, presentation.isPresented, drag != 0 { returnToRest() }
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
                .padding(.bottom, 22)
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
        Capsule().fill(.white.opacity(0.42)).frame(width: 38, height: 5)
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
                    let vertical = abs(value.translation.height) > abs(value.translation.width)
                    if vertical || drag != 0 {
                        // Follow the finger directly, including a reversal.
                        // Do not interpolate between gesture samples.
                        withTransaction(Transaction(animation: nil)) {
                            if value.translation.height >= 0 {
                                drag = value.translation.height
                            } else {
                                drag = -rubberband(-value.translation.height, dimension: 140, constant: 0.45)
                            }
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

    private func rubberband(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat) -> CGFloat {
        let clamped = max(0, overshoot)
        let result = (clamped * dimension * constant) / (dimension + constant * clamped)
        return min(22, result)
    }

    private var primaryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("quickSettings.title")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("lyricsQuickSettingsPanel")
                    .accessibilityFocused($titleFocused)
                if let trackSubtitle {
                    Text(trackSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            QuickSettingsCircleButton(label: "common.done", symbol: "xmark") {
                presentation.close(reduceMotion: reduceMotion)
            }
            .accessibilityIdentifier("closeLyricsQuickSettings")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var trackSubtitle: String? {
        guard let track = model.lyrics.track else { return nil }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artists = track.artists.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return artists.isEmpty ? title : title + " · " + artists.joined(separator: ", ")
    }

    private func returnToRest() {
        withAnimation(reduceMotion ? nil : LyricsQuickSettingsPresentation.motionAnimation) { drag = 0 }
    }

    private var appearance: some View {
        VStack(spacing: 8) {
            controls {
                appearanceButton("render.showLyrics", symbol: "text.quote", id: "toggleLyricsVisibility",
                                 value: setting(\.showLyrics))
                appearanceButton("render.translation", symbol: "character.bubble", id: "quickSettingsTranslation",
                                 value: setting(\.translation))
                appearanceButton("render.romanization", symbol: "abc", id: "quickSettingsRomanization",
                                 value: setting(\.romanization))
                appearanceButton("quickSettings.hdr", symbol: "sun.max.fill", id: "quickSettingsHDR",
                                 value: Binding(
                                     get: { configuration.hdr?.enabled ?? false },
                                     set: { model.renderPreferences.configuration.hdr = .init(enabled: $0) }
                                 ))
                if model.desktopLyrics.isSupported {
                    desktopLyricsButton
                }
            }
            appearanceButton("quickSettings.immersiveLyrics", symbol: "rectangle.topthird.inset.filled",
                             id: "quickSettingsImmersiveLyrics", accent: MusicProductStyle.accent,
                             value: Binding(
                                 get: { configuration.immersiveLyrics == true },
                                 set: { model.renderPreferences.configuration.immersiveLyrics = $0 }
                             ))
        }
    }

    private var desktopLyricsButton: some View {
        let pip = model.desktopLyrics
        return Button {
            AppHaptics.shared.play(.selection)
            pip.toggle()
        } label: {
            QuickSettingsControlLabel(
                title: "desktopLyrics.title", symbol: pip.isOpen ? "pip.exit" : "pip.enter",
                indicator: pip.isOpen ? "checkmark.circle.fill" : "circle",
                selected: pip.isOpen, accentColor: MusicProductStyle.accent
            )
        }
        .buttonStyle(MusicContentButtonStyle())
        .disabled(pip.isBusy || model.playbackSnapshot?.item == nil)
        .accessibilityValue(Text(LocalizedStringKey(pip.isOpen ? "quickSettings.on" : "quickSettings.off")))
        .accessibilityIdentifier("quickSettingsDesktopLyrics")
        .alert("desktopLyrics.unavailable", isPresented: Binding(get: { pip.showsStartError },
                                                                  set: { pip.showsStartError = $0 })) {
            Button("common.ok", role: .cancel) {}
        }
    }

    private func appearanceButton(_ title: LocalizedStringKey, symbol: String, id: String,
                                  accent: Color = MusicProductStyle.accent, value: Binding<Bool>,
                                  playsHaptic: Bool = true) -> some View
    {
        Button {
            let control = playsHaptic ? value.hapticSelection() : value
            control.wrappedValue.toggle()
        } label: {
            QuickSettingsControlLabel(
                title: title,
                symbol: symbol,
                indicator: value.wrappedValue ? "checkmark.circle.fill" : "circle",
                selected: value.wrappedValue,
                accentColor: accent
            )
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(LocalizedStringKey(value.wrappedValue ? "quickSettings.on" : "quickSettings.off")))
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var typography: some View {
        let isAutoSize = configuration.sizePreset != nil
        return section("quickSettings.appearance") {
            QuickSettingsCard {
                Button {
                    let next = !isAutoSize
                    withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                        model.renderPreferences.configuration.sizePreset = next ? .medium : nil
                    }
                    AppHaptics.shared.play(.selection)
                } label: {
                    QuickSettingsCardToggleRow(
                        title: "appearance.autoSize",
                        symbol: "textformat.size",
                        accent: MusicProductStyle.accent,
                        selected: isAutoSize
                    )
                }
                .buttonStyle(QuickSettingsRowButtonStyle())
                .accessibilityLabel(Text("appearance.autoSize"))
                .accessibilityValue(Text(LocalizedStringKey(isAutoSize ? "quickSettings.on" : "quickSettings.off")))
                .accessibilityAddTraits(isAutoSize ? .isSelected : [])
                .accessibilityIdentifier("quickSettingsAutoSize")

                QuickSettingsDivider(inset: 56)

                if isAutoSize {
                    Picker("render.sizePreset", selection: Binding(get: { configuration.sizePreset ?? .medium }, set: {
                        model.renderPreferences.configuration.sizePreset = $0
                    })) {
                        ForEach(AMLLLyricSizePreset.allCases, id: \.self) { preset in
                            Text(LocalizedStringKey("render.size." + preset.rawValue)).tag(preset)
                        }
                    }
                    .modifier(QuickSettingsCardPickerRow(title: "render.sizePreset", symbol: "textformat", accent: MusicProductStyle.accent))
                    .accessibilityIdentifier("quickSettingsSizePreset")
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
                    .modifier(QuickSettingsCardPickerRow(title: "render.fontSize", symbol: "textformat", accent: MusicProductStyle.accent))
                    .accessibilityIdentifier("quickSettingsFontSize")
                    .accessibilityValue(Text(String(format: "%.0f pt", configuration.fontSize)))
                }

                QuickSettingsDivider(inset: 56)

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
                .modifier(QuickSettingsCardPickerRow(title: "quickSettings.background", symbol: "paintbrush", accent: MusicProductStyle.accent))
                .accessibilityIdentifier("quickSettingsBackground")
                .accessibilityValue(Text(backgroundTitle))
            }
        }
    }

    private var playback: some View {
        section("quickSettings.playback") {
            VStack(spacing: 8) {
                if model.selectedMusicService == .netease {
                    controls {
                        route("AirPlay", symbol: "airplayaudio", to: .devices)
                        route(model.netEasePlayback.isListeningTogether ? "一起听房间" : "与好友一起听",
                              symbol: "person.2", to: .listeningRoom)
                            .accessibilityIdentifier("quickSettingsNetEaseListeningRoom")
                    }
                    if let snapshot = model.playbackSnapshot {
                        let busy = model.isPerformingAction || !model.netEasePlayback.canEditPersonalQueue
                        route("quickSettings.queue", symbol: "list.bullet", to: .queue)
                        controls {
                            appearanceButton("quickSettings.shuffle", symbol: "shuffle", id: "quickSettingsShuffle",
                                             value: Binding(get: { snapshot.shuffleEnabled }, set: { enabled in
                                                 Task { await model.setShuffle(enabled) }
                                             }), playsHaptic: false).disabled(busy)
                            QuickSettingsRepeatMenu(owner: ObjectIdentifier(model), service: model.selectedMusicService,
                                                    mode: snapshot.repeatMode, busy: busy) { mode in
                                Task { await model.setRepeat(mode) }
                            }.equatable()
                        }
                    }
                } else if model.selectedMusicService != .spotify, let snapshot = model.playbackSnapshot {
                    let busy = model.isPerformingAction
                    controls {
                        route("AirPlay", symbol: "airplayaudio", to: .devices)
                        route("quickSettings.queue", symbol: "list.bullet", to: .queue)
                        appearanceButton("quickSettings.shuffle", symbol: "shuffle", id: "quickSettingsShuffle",
                                         value: Binding(get: { snapshot.shuffleEnabled }, set: { enabled in
                                             Task { await model.setShuffle(enabled) }
                                         }), playsHaptic: false).disabled(busy)
                        QuickSettingsRepeatMenu(owner: ObjectIdentifier(model), service: model.selectedMusicService,
                                                mode: snapshot.repeatMode, busy: busy) { mode in
                            Task { await model.setRepeat(mode) }
                        }.equatable()
                    }
                } else {
                    route(model.selectedMusicService == .spotify ? "player.devices" : "AirPlay",
                          symbol: "airplayaudio", to: .devices)
                }
                sleepTimerCard
            }
            if model.selectedMusicService == .netease, model.netEasePlayback.isPersonalFM {
                Text("私人 FM 自动续播，退出后可使用随机与循环。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.60))
                    .padding(.horizontal, 4)
            }
        }
    }

    private var sleepTimerCard: some View {
        QuickSettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    QuickSettingsIconTile(
                        symbol: "moon.zzz.fill",
                        accent: MusicProductStyle.accent,
                        selected: model.sleepTimer.isActive,
                        unselectedFill: MusicProductStyle.accent.opacity(0.20)
                    )
                    Text("sleepTimer.title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    sleepTimerStatusBadge
                }

                switch model.sleepTimer.mode {
                case .off:
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { sleepTimerPresetButtons }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                            sleepTimerPresetButtons
                        }
                    }
                    sleepTimerActionButton("sleepTimer.endOfTrack", id: "quickSettingsSleepTimerEndOfTrack") {
                        AppHaptics.shared.play(.selection)
                        withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                            model.sleepTimer.startEndOfTrack(currentTrackURI: model.playbackSnapshot?.item?.uri)
                        }
                    }
                    .disabled(model.playbackSnapshot?.item?.uri == nil)
                case .until:
                    HStack(spacing: 8) {
                        sleepTimerActionButton("sleepTimer.extend5m", id: "quickSettingsSleepTimerExtend", emphasized: true) {
                            AppHaptics.shared.play(.selection)
                            withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                                model.sleepTimer.extend(minutes: 5)
                            }
                        }
                        sleepTimerActionButton("sleepTimer.cancel", id: "quickSettingsSleepTimerCancel") {
                            AppHaptics.shared.play(.selection)
                            withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                                model.sleepTimer.cancel()
                            }
                        }
                    }
                case .endOfTrack:
                    sleepTimerActionButton("sleepTimer.cancel", id: "quickSettingsSleepTimerCancel") {
                        AppHaptics.shared.play(.selection)
                        withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                            model.sleepTimer.cancel()
                        }
                    }
                }
            }
            .padding(14)
        }
        .accessibilityIdentifier("quickSettingsSleepTimer")
    }

    @ViewBuilder private var sleepTimerStatusBadge: some View {
        switch model.sleepTimer.mode {
        case .off:
            Text("sleepTimer.off")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
        case .until:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = model.sleepTimer.remainingSeconds(at: context.date) ?? 0
                Text(SleepTimerController.formattedDuration(remaining))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MusicProductStyle.accent.opacity(0.24), in: Capsule())
                    .foregroundStyle(.white)
            }
        case .endOfTrack:
            Text("sleepTimer.endOfTrackShort")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(MusicProductStyle.accent.opacity(0.24), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var sleepTimerPresetButtons: some View {
        ForEach([
            SleepTimerPreset.fifteenMinutes,
            .thirtyMinutes,
            .fortyFiveMinutes,
            .sixtyMinutes,
        ]) { preset in
            sleepTimerActionButton(
                LocalizedStringKey(preset.titleKey),
                id: "quickSettingsSleepTimer\(preset.minutes ?? 0)"
            ) {
                guard let minutes = preset.minutes else { return }
                AppHaptics.shared.play(.selection)
                withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                    model.sleepTimer.start(minutes: minutes)
                }
            }
        }
    }

    private func sleepTimerActionButton(_ title: LocalizedStringKey, id: String, emphasized: Bool = false,
                                        perform: @escaping () -> Void) -> some View
    {
        timingButton(title, id: id, emphasized: emphasized, perform: perform)
    }

    private var globalTiming: some View {
        section("quickSettings.globalDelay") {
            QuickSettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("quickSettings.globalDelay")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(String(format: "%+.1f s", model.lyrics.globalDelay))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.11), in: Capsule())
                            .accessibilityIdentifier("quickSettingsGlobalDelayValue")
                    }
                    Slider(value: Binding(get: { model.lyrics.globalDelay }, set: { model.lyrics.setGlobalDelay($0) }),
                           in: -10 ... 10, step: 0.1)
                        .accessibilityLabel(Text("quickSettings.globalDelay"))
                        .accessibilityValue(Text(String(format: "%+.1f s", model.lyrics.globalDelay)))
                        .accessibilityIdentifier("quickSettingsGlobalDelay")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { globalDelayButtons }
                        VStack(alignment: .leading, spacing: 8) { globalDelayButtons }
                    }
                }
                .padding(14)
            }
            Text("quickSettings.globalDelayHelp")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var globalDelayButtons: some View {
        timingButton("−0.1 s", id: "quickSettingsGlobalDelayMinus") { model.lyrics.setGlobalDelay(model.lyrics.globalDelay - 0.1) }
            .accessibilityLabel(Text("lyrics.offset.minus"))
        timingButton("+0.1 s", id: "quickSettingsGlobalDelayPlus") { model.lyrics.setGlobalDelay(model.lyrics.globalDelay + 0.1) }
            .accessibilityLabel(Text("lyrics.offset.plus"))
        timingButton("lyrics.offset.zero", id: "quickSettingsGlobalDelayReset", emphasized: true) { model.lyrics.setGlobalDelay(0) }
    }

    private var lyricActions: some View {
        section("quickSettings.lyrics") {
            VStack(spacing: 10) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 3),
                    spacing: 8
                ) {
                    compactActionTile("lyrics.find", symbol: "magnifyingglass", accent: MusicProductStyle.accent) {
                        presentation.show(.lyricsSearch, reduceMotion: reduceMotion)
                    }
                    .accessibilityFocused($focusedRoute, equals: .lyricsSearch)
                    .accessibilityIdentifier("quickSettingsRoute.lyricsSearch")

                    compactActionTile("lyrics.refresh", symbol: "arrow.clockwise", accent: MusicProductStyle.accent) {
                        model.lyrics.reload(force: true)
                    }

                    compactActionTile("lyrics.automatic", symbol: "arrow.uturn.backward", accent: MusicProductStyle.accent) {
                        model.lyrics.restoreAutomatic()
                    }
                }

                QuickSettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent {
                            Text(String(format: "%+.1f s", model.lyrics.selection.offset))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.11), in: Capsule())
                        } label: {
                            Text("quickSettings.offset")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(Text(String(format: "%+.1f s", model.lyrics.selection.offset)))
                        .accessibilityIdentifier("quickSettingsOffset")

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { offsetButtons }
                            VStack(alignment: .leading, spacing: 8) { offsetButtons }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .disabled(!canManageLyrics)
        .opacity(canManageLyrics ? 1 : 0.45)
    }

    @ViewBuilder private var offsetButtons: some View {
        timingButton("−0.1 s", id: "quickSettingsOffsetMinus") { model.lyrics.setOffset(model.lyrics.selection.offset - 0.1) }
            .accessibilityLabel(Text("lyrics.offset.minus"))
        timingButton("+0.1 s", id: "quickSettingsOffsetPlus") { model.lyrics.setOffset(model.lyrics.selection.offset + 0.1) }
            .accessibilityLabel(Text("lyrics.offset.plus"))
        timingButton("lyrics.offset.zero", id: "quickSettingsOffsetReset", emphasized: true) { model.lyrics.setOffset(0) }
    }

    private var more: some View {
        section("quickSettings.more") {
            QuickSettingsCard {
                Button {
                    presentation.show(.appearance, reduceMotion: reduceMotion)
                } label: {
                    QuickSettingsCardRow(title: "render.settings", symbol: "slider.horizontal.3", accent: MusicProductStyle.accent, indicator: "chevron.forward")
                }
                .buttonStyle(QuickSettingsRowButtonStyle())
                .accessibilityFocused($focusedRoute, equals: .appearance)
                .accessibilityIdentifier("quickSettingsRoute.appearance")

                QuickSettingsDivider(inset: 56)

                Button {
                    presentation.show(.lyricsSources, reduceMotion: reduceMotion)
                } label: {
                    QuickSettingsCardRow(title: "lyrics.settings", symbol: "text.badge.checkmark", accent: MusicProductStyle.accent, indicator: "chevron.forward")
                }
                .buttonStyle(QuickSettingsRowButtonStyle())
                .accessibilityFocused($focusedRoute, equals: .lyricsSources)
                .accessibilityIdentifier("quickSettingsRoute.lyricsSources")

                QuickSettingsDivider(inset: 56)

                Button {
                    AppHaptics.shared.play(.selection)
                    model.lyricsKeepScreenAwake.toggle()
                } label: {
                    QuickSettingsCardToggleRow(
                        title: "settings.keepScreenAwake",
                        symbol: "sun.max",
                        accent: MusicProductStyle.accent,
                        selected: model.lyricsKeepScreenAwake
                    )
                }
                .buttonStyle(QuickSettingsRowButtonStyle())
                .accessibilityLabel(Text("settings.keepScreenAwake"))
                .accessibilityValue(Text(LocalizedStringKey(model.lyricsKeepScreenAwake ? "quickSettings.on" : "quickSettings.off")))
                .accessibilityAddTraits(model.lyricsKeepScreenAwake ? .isSelected : [])
                .accessibilityIdentifier("quickSettingsKeepScreenAwake")

                QuickSettingsDivider(inset: 56)

                Button {
                    AppHaptics.shared.play(.selection)
                    artworkDebug.showsButton.toggle()
                } label: {
                    QuickSettingsCardToggleRow(
                        title: "quickSettings.artworkDebugButton",
                        symbol: "rectangle.on.rectangle",
                        accent: MusicProductStyle.accent,
                        selected: artworkDebug.showsButton
                    )
                }
                .buttonStyle(QuickSettingsRowButtonStyle())
                .accessibilityLabel(Text("quickSettings.artworkDebugButton"))
                .accessibilityValue(Text(LocalizedStringKey(artworkDebug.showsButton ? "quickSettings.on" : "quickSettings.off")))
                .accessibilityAddTraits(artworkDebug.showsButton ? .isSelected : [])
                .accessibilityIdentifier("quickSettingsArtworkDebugButton")

                if AppDiagnosticsVisibility.shared.isUnlocked {
                    QuickSettingsDivider(inset: 56)

                    Button {
                        UIPasteboard.general.string = LyricsCompositingDiagnostics.text(
                            configuration: configuration,
                            profile: model.renderPreferences.profile
                        )
                        withAnimation(reduceMotion ? nil : MusicProductMotion.change) {
                            compositingDiagnosticCopied = true
                        }
                    } label: {
                        QuickSettingsCardRow(
                            title: LocalizedStringKey(compositingDiagnosticCopied ? "quickSettings.diagnosticCopied" : "quickSettings.copyCompositingDiagnostics"),
                            symbol: compositingDiagnosticCopied ? "checkmark.circle.fill" : "doc.on.doc",
                            accent: MusicProductStyle.accent
                        )
                    }
                    .buttonStyle(QuickSettingsRowButtonStyle())
                    .accessibilityIdentifier("quickSettingsCopyCompositingDiagnostics")
                }
            }

            if AppDiagnosticsVisibility.shared.isUnlocked, let artworkStatus, !artworkStatus.isEmpty {
                Text(artworkStatus)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.60))
                    .padding(.horizontal, 4)
            }
            if let document = model.lyrics.document, let credit = configuration.credits.content(in: document) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("render.creditLabel." + credit.kind.rawValue))
                    Text(credit.names.joined(separator: " · "))
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.60))
                .padding(.horizontal, 4)
            }
        }
    }

    private func setting(_ key: WritableKeyPath<LyricsRenderConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { model.renderPreferences.configuration[keyPath: key] }, set: { model.renderPreferences.configuration[keyPath: key] = $0 })
    }

    private var backgroundTitle: String {
        switch configuration.backgroundMode ?? .mesh {
        case .mesh: String(localized: "Mesh 网格")
        case .meshColorMode2: String(localized: "Mesh网格（取色模式2）")
        case .pixi: String(localized: "Pixi 流动封面")
        case .flowing: String(localized: "流动背景")
        case .solid: String(localized: "纯色")
        case .gradient: String(localized: "双色渐变")
        }
    }

    private func route(_ title: LocalizedStringKey, symbol: String, accent: Color = MusicProductStyle.accent,
                       to target: LyricsQuickSettingsPresentation.Destination) -> some View
    {
        action(title, symbol: symbol, accent: accent, indicator: "chevron.forward") {
            presentation.show(target, reduceMotion: reduceMotion)
        }
        .accessibilityFocused($focusedRoute, equals: target)
        .accessibilityIdentifier("quickSettingsRoute." + target.rawValue)
    }

    private func action(_ title: LocalizedStringKey, symbol: String, accent: Color = MusicProductStyle.accent,
                        indicator: String? = nil, perform: @escaping () -> Void) -> some View
    {
        Button(action: perform) {
            QuickSettingsControlLabel(title: title, symbol: symbol, indicator: indicator, accentColor: accent)
        }
        .buttonStyle(MusicContentButtonStyle())
    }

    private func compactActionTile(_ title: LocalizedStringKey, symbol: String, accent: Color,
                                   perform: @escaping () -> Void) -> some View
    {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button(action: perform) {
            VStack(spacing: 6) {
                QuickSettingsIconTile(symbol: symbol, accent: accent, unselectedFill: accent.opacity(0.18))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(reduceTransparency ? Color(uiColor: .secondarySystemBackground) : .white.opacity(0.08), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.09), lineWidth: 0.75) }
            .contentShape(shape)
        }
        .buttonStyle(MusicContentButtonStyle())
    }

    private func timingButton(_ title: LocalizedStringKey, id: String, emphasized: Bool = false,
                              perform: @escaping () -> Void) -> some View
    {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button(action: perform) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(emphasized ? MusicProductStyle.accent : .primary)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    reduceTransparency
                        ? Color(uiColor: .tertiarySystemBackground)
                        : (emphasized ? MusicProductStyle.accent.opacity(0.16) : .white.opacity(0.09)),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(emphasized ? MusicProductStyle.accent.opacity(0.32) : .white.opacity(0.08), lineWidth: 0.5)
                }
                .contentShape(shape)
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
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .tint(MusicProductStyle.accent)
    }
}

/// Navigation chrome applied only to the root of an embedded destination.
/// Pushed views keep their own back button and toolbar.
struct LyricsQuickSettingsNavigation {
    let back: (() -> Void)?
    let close: () -> Void
    var backLabel: LocalizedStringKey = "quickSettings.back"
    var backIdentifier = "backLyricsQuickSettingsDestination"

    func child(back: @escaping () -> Void) -> Self {
        Self(back: back, close: close, backLabel: "quickSettings.backOneLevel",
             backIdentifier: "backLyricsQuickSettingsChild")
    }
}

extension EnvironmentValues {
    @Entry var lyricsQuickSettingsNavigation: LyricsQuickSettingsNavigation? = nil
}

extension View {
    func lyricsQuickSettingsDestination(_ title: LocalizedStringKey, showsEditButton: Bool = false) -> some View {
        modifier(LyricsQuickSettingsDestinationChrome(title: title, showsEditButton: showsEditButton))
    }
}

private struct QuickSettingsCircleButton: View {
    let label: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(reduceTransparency ? Color(uiColor: .tertiarySystemBackground) : .white.opacity(0.12), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityLabel(Text(label))
    }
}

private struct LyricsQuickSettingsDestinationChrome: ViewModifier {
    let title: LocalizedStringKey
    let showsEditButton: Bool
    @Environment(\.lyricsQuickSettingsNavigation) private var navigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AccessibilityFocusState private var titleFocused: Bool

    func body(content: Content) -> some View {
        if let navigation {
            VStack(spacing: 0) {
                header(navigation)
                content
                    .scrollContentBackground(.hidden)
                    .modifier(ImmersiveLyricsScrollEdge(active: true))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Keep the title outside the scroll viewport. The panel's glass
            // supplies the only background, even when the list is scrolled.
            .toolbar(.hidden, for: .navigationBar)
            .tint(MusicProductStyle.accent)
        } else {
            content
        }
    }

    private func header(_ navigation: LyricsQuickSettingsNavigation) -> some View {
        HStack(spacing: 8) {
            if let back = navigation.back {
                QuickSettingsCircleButton(label: navigation.backLabel, symbol: "chevron.backward", action: back)
                    .accessibilityIdentifier(navigation.backIdentifier)
            } else {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
            Text(title)
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("lyricsQuickSettingsDestinationTitle")
                .accessibilityFocused($titleFocused)
                .onAppear { titleFocused = true }
            if showsEditButton {
                EditButton()
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 32)
                    .background(reduceTransparency ? Color(uiColor: .tertiarySystemBackground) : .white.opacity(0.12), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                    .frame(minHeight: 44)
                    .buttonStyle(MusicContentButtonStyle())
            }
            QuickSettingsCircleButton(label: "common.done", symbol: "xmark", action: navigation.close)
                .accessibilityIdentifier("closeLyricsQuickSettingsDestination")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
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
            QuickSettingsControlLabel(
                title: "quickSettings.repeat",
                symbol: "repeat",
                detail: mode.title,
                indicator: "chevron.up.chevron.down",
                selected: mode != .off,
                accentColor: MusicProductStyle.accent
            )
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
    var accentColor: Color = MusicProductStyle.accent
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 10) {
            QuickSettingsIconTile(
                symbol: symbol,
                accent: accentColor,
                selected: selected,
                unselectedFill: .white.opacity(0.11),
                size: 30,
                cornerRadius: 9
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let indicator {
                Image(systemName: indicator)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? accentColor : .white.opacity(0.45))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .foregroundStyle(.primary)
        .background(
            reduceTransparency
                ? Color(uiColor: .secondarySystemBackground)
                : (colorScheme == .dark ? .white.opacity(0.08) : Color(uiColor: .tertiarySystemFill)),
            in: shape
        )
        .background { if selected { shape.fill(accentColor.opacity(0.22)) } }
        .overlay {
            shape.strokeBorder(selected ? accentColor.opacity(0.42) : .white.opacity(0.09), lineWidth: 0.75)
        }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.48)
        .animation(reduceMotion ? nil : MusicProductMotion.change, value: selected)
    }
}

private struct QuickSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reduceTransparency ? Color(uiColor: .secondarySystemBackground) : .white.opacity(0.08), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(contrast == .increased ? 0.36 : 0.10), lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .contentShape(shape)
    }
}

private struct QuickSettingsDivider: View {
    var inset: CGFloat = 56

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.09))
            .frame(height: 0.5)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

private struct QuickSettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? .white.opacity(0.08) : .clear)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : MusicProductMotion.feedback, value: configuration.isPressed)
    }
}

private struct QuickSettingsIconTile: View {
    let symbol: String
    let accent: Color
    var selected = false
    var unselectedFill: Color? = nil
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 8.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(selected ? accent : (unselectedFill ?? accent.opacity(0.22)))
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(selected ? .white : accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct QuickSettingsCardRow: View {
    let title: LocalizedStringKey
    let symbol: String
    var accent: Color = MusicProductStyle.accent
    var indicator: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            QuickSettingsIconTile(symbol: symbol, accent: accent)

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let indicator {
                Image(systemName: indicator)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct QuickSettingsCardToggleRow: View {
    let title: LocalizedStringKey
    let symbol: String
    var accent: Color = MusicProductStyle.accent
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            QuickSettingsIconTile(symbol: symbol, accent: accent, selected: selected, unselectedFill: accent.opacity(0.20))

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? accent : .white.opacity(0.35))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : MusicProductMotion.change, value: selected)
    }
}

private struct QuickSettingsCardPickerRow: ViewModifier {
    let title: LocalizedStringKey
    let symbol: String
    let accent: Color
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        HStack(spacing: 12) {
            QuickSettingsIconTile(symbol: symbol, accent: accent)

            layout {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                content.labelsHidden()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
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
