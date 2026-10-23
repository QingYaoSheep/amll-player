import SwiftUI

struct AlbumArtworkBackground: View {
    let url: URL?
    let blur: Double
    var previewImage: Image?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.08)
                if !reduceTransparency {
                    if let previewImage {
                        filled(previewImage, size: geometry.size)
                    } else {
                        PlaybackArtworkImage(url: url) { image in filled(image, size: geometry.size) }
                            placeholder: { Color(white: 0.08) }
                            .id(url)
                    }
                    Color.black.opacity(0.48)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func filled(_ image: Image, size: CGSize) -> some View {
        image.resizable().scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped().blur(radius: blur, opaque: true)
    }
}

struct FullscreenLyricsPlayer: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var search = false
    @State private var devices = false
    @State private var quickSettings = LyricsQuickSettingsPresentation()
    @State private var browsing = false
    @State private var resumeToken = 0
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 1))) private var drag: CGFloat = 0
    @State private var pageVisible = false
    @State private var immersiveArtworkSource = ImmersiveLyricsArtworkSource.placeholder
    @State private var immersiveInformationHeight: CGFloat = 64
    @State private var immersiveInformationTextBottom: CGFloat?
    @State private var artworkDebug = ImmersiveArtworkDebugStore.shared
    @State private var artworkReflectionFrames = ArtworkReflectionFrames()
    @State private var showingArtworkDebug = false
    @State private var immersiveViewport = false
    private var configuration: LyricsRenderConfiguration {
        model.renderPreferences.configuration.validated()
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let source = immersiveArtworkSource.forTrack(model.playbackSnapshot?.item?.uri)
                let layout = ImmersiveLyricsLayout.isEnabled(configuration, isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                    viewport: geometry.size) ? ImmersiveLyricsLayout.resolve(viewport: geometry.size,
                        artwork: source.size, informationHeight: immersiveInformationHeight,
                        bottomInset: geometry.safeAreaInsets.bottom, isVideo: source.isVideo,
                        informationTextBottom: immersiveInformationTextBottom,
                        artworkAdjustment: artworkDebug.configuration[.video]) : nil
                ZStack {
                    if let layout, let item = model.playbackSnapshot?.item {
                        ImmersiveLyricsArtworkBackdrop(model: model, item: item, layout: layout, viewport: geometry.size,
                            active: pageVisible && scenePhase == .active && !search && !devices && !quickSettings.suspendsPage,
                            artworkSource: { source in
                                if source.trackID == model.playbackSnapshot?.item?.uri { immersiveArtworkSource = source }
                            }, frames: artworkReflectionFrames)
                    } else {
                        AlbumArtworkBackground(url: model.playbackSnapshot?.item?.artworkURL,
                                               blur: configuration.backgroundBlur)
                    }
                    if let snapshot = model.playbackSnapshot, let item = snapshot.item {
                        let columns = geometry.size.width >= 700 || (geometry.size.width > geometry.size.height && geometry.size.width >= 550)
                        VStack(spacing: layout == nil ? 8 : 0) {
                            dismissalHandle
                            if columns {
                                HStack(spacing: 24) {
                                    ScrollView {
                                        metadata(item, wide: true)
                                        if configuration.showControls {
                                            controls(snapshot).padding(.top, 16)
                                        }
                                    }
                                    .frame(width: min(360, geometry.size.width * 0.42))
                                    lyricContent(snapshot)
                                }
                                .padding(.horizontal, 24)
                            } else {
                                phoneLyrics(snapshot: snapshot, item: item, size: geometry.size, layout: layout)
                            }
                            if configuration.showControls, !columns, layout == nil {
                                controls(snapshot).padding(.horizontal, 24).padding(.bottom, 8)
                            }
                        }
                        .offset(y: reduceMotion ? 0 : drag)
                    } else {
                        ContentUnavailableView("player.noPlayback", systemImage: "music.note")
                    }
                }
                .onChange(of: layout != nil, initial: true) { _, enabled in immersiveViewport = enabled }
                .onPreferenceChange(ImmersiveInformationHeightKey.self) { height in
                    if height > 0, abs(immersiveInformationHeight - height) > 0.5 { immersiveInformationHeight = height }
                }
                .onPreferenceChange(ImmersiveInformationTextBottomKey.self) { bottom in
                    if let bottom, abs((immersiveInformationTextBottom ?? -1) - bottom) > 0.5 { immersiveInformationTextBottom = bottom }
                }
                .overlay(alignment: .topTrailing) {
                    if layout != nil {
                        ImmersiveArtworkDebugButton { showingArtworkDebug = true }
                            .padding(.top, geometry.safeAreaInsets.top + 48).padding(.trailing, 16)
                    }
                }
                .sheet(isPresented: $showingArtworkDebug) {
                    ImmersiveArtworkDebugPanel(viewport: geometry.size, video: layout?.visibleCover ?? .zero,
                        backgroundDimming: configuration.backgroundDimming ?? 0.16, frames: artworkReflectionFrames)
                        .presentationDetents([.medium, .large])
                }
            }
            .ignoresSafeArea(.container, edges: immersiveViewport ? .all : [])
            .onAppear { pageVisible = true }
            .onDisappear { pageVisible = false }
            .foregroundStyle(.white)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(immersiveViewport ? .hidden : .visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.done", systemImage: "chevron.down") { dismiss() }
                        .accessibilityIdentifier("closeLyricsPlayer")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LyricsQuickMenu(coordinator: model.lyrics) { search = true }
                    LyricsQuickSettingsButton(presentation: quickSettings, systemImage: "ellipsis.circle")
                    NavigationLink { SettingsView(model: model) } label: { Label("settings.open", systemImage: "gearshape") }
                        .accessibilityIdentifier("openSettings")
                }
            }
            .sheet(isPresented: $search) { LyricsSearchView(coordinator: model.lyrics) }
            .sheet(isPresented: $devices) { DevicePickerView(model: model) }
        }
        .preferredColorScheme(.dark)
        .modifier(LyricsQuickSettingsPresenter(model: model, presentation: quickSettings))
        .onChange(of: model.playbackSnapshot?.item?.uri) { browsing = false }
        .alert("error.title", isPresented: Binding(get: { model.presentedError != nil }, set: {
            if !$0 {
                model.presentedError = nil
            }
        })) {
            Button("common.ok", role: .cancel) { model.presentedError = nil }
        } message: { Text(model.presentedError?.localizedDescription ?? "") }
    }

    private func phoneLyrics(snapshot: PlaybackSnapshot, item: PlaybackItem, size: CGSize,
                             layout: ImmersiveLyricsLayout?) -> some View {
        GeometryReader { available in
            let headerHeight = min(size.height * 0.38, configuration.coverLayout == .normal ? 290 : 180)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if let layout {
                        Color.clear.frame(height: max(0, layout.information.minY - 44))
                            .accessibilityHidden(true)
                        ImmersiveLyricsHeader(model: model, snapshot: snapshot, item: item, presentation: quickSettings,
                            additive: layout.overlaysArtwork)
                            .frame(width: layout.information.width)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: ImmersiveInformationHeightKey.self, value: proxy.size.height)
                            } }
                            .padding(.bottom, layout.lyrics.minY - layout.information.maxY)
                    } else {
                        ScrollView { metadata(item, wide: false) }
                            .frame(height: headerHeight).padding(.bottom, 8)
                    }
                    // Stable child: retain the compatibility renderer across toggles.
                    lyricContent(snapshot, immersiveLayout: layout)
                        .frame(height: layout?.lyrics.height ?? max(1, available.size.height - headerHeight - 8))
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }

    private var dismissalHandle: some View {
        Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier(immersiveViewport ? "closeLyricsPlayer" : "lyricsDismissHandle")
            .accessibilityLabel(Text("common.done"))
            .onTapGesture { if immersiveViewport { dismiss() } }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .updating($drag) { value, state, _ in
                    if value.translation.height > abs(value.translation.width) {
                        state = max(0, value.translation.height)
                    }
                }
                .onEnded { value in
                    if value.translation.height > abs(value.translation.width),
                       value.translation.height > 90 || value.predictedEndTranslation.height > 180
                    {
                        dismiss()
                    }
                })
            .accessibilityHidden(!immersiveViewport)
            .accessibilityAddTraits(immersiveViewport ? .isButton : [])
            .accessibilityAction(.escape) { dismiss() }
    }

    @ViewBuilder private func metadata(_ item: PlaybackItem, wide: Bool) -> some View {
        let showLarge = !configuration.showLyrics || wide || configuration.coverLayout == .normal
        VStack(spacing: 10) {
            if configuration.coverLayout != .immersive || !configuration.showLyrics {
                PlaybackArtworkImage(url: item.artworkURL) { image in image.resizable().scaledToFit() }
                    placeholder: { RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)).overlay { Image(systemName: "music.note").font(.largeTitle) } }
                    .frame(width: showLarge ? (wide ? 260 : 160) : 48, height: showLarge ? (wide ? 260 : 160) : 48)
                    .clipShape(RoundedRectangle(cornerRadius: showLarge ? 16 : 8))
                    .id(item.uri)
                    .accessibilityHidden(true)
            }
            if configuration.showTitle {
                MarqueeText(text: item.title, fontSize: 22, enabled: configuration.marquee && scenePhase == .active && pageVisible && !search && !devices && !quickSettings.suspendsPage && !reduceMotion)
                    .frame(height: typeSize.isAccessibilitySize ? 80 : 32)
            }
            if configuration.showArtist {
                MarqueeText(text: item.artistLine, fontSize: 16, enabled: configuration.marquee && scenePhase == .active && pageVisible && !search && !devices && !quickSettings.suspendsPage && !reduceMotion)
                    .frame(height: typeSize.isAccessibilitySize ? 64 : 26).opacity(0.75)
            }
            if configuration.showAlbum, let album = item.albumTitle {
                Text(album).font(.caption).lineLimit(2)
            }
            if model.lyrics.selection.candidate != nil {
                Text("lyrics.match.manual").font(.caption).accessibilityIdentifier("lyricsManualLock")
            }
            if !configuration.showLyrics {
                credits
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private func lyricContent(_ snapshot: PlaybackSnapshot, immersiveLayout: ImmersiveLyricsLayout? = nil) -> some View {
        let renderConfiguration = compatibilityConfiguration(layout: immersiveLayout)
        if !configuration.showLyrics {
            Spacer(minLength: 0)
            Button("render.showLyrics") { model.renderPreferences.configuration.showLyrics = true }
            Spacer(minLength: 0)
        } else if let document = model.lyrics.document, !document.lines.isEmpty {
            VStack(spacing: 0) {
                NativeLyricsView(document: document, configuration: renderConfiguration, offset: model.lyrics.selection.offset,
                                 duration: snapshot.duration, playing: snapshot.isPlaying, active: pageVisible && scenePhase == .active && !search && !devices && !quickSettings.suspendsPage,
                                 canSeek: snapshot.restrictions.canSeek && !model.isPerformingAction,
                                 position: { model.progress() }, seek: { target in Task { await model.seek(to: target) } },
                                 resumeToken: resumeToken, browsing: { browsing = $0 },
                                 fadeTop: immersiveLayout != nil ? 0 : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("render.returnCurrent", systemImage: "location.fill") { resumeToken += 1 }
                    .buttonStyle(.bordered).accessibilityIdentifier("resumeLyricsFollowing")
                    .frame(height: 48).opacity(browsing ? 1 : 0).disabled(!browsing).accessibilityHidden(!browsing)
                credits
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 16) {
                Spacer()
                if model.lyrics.isLoading {
                    ProgressView()
                }
                Image(systemName: model.lyrics.document?.isInstrumental == true ? "pianokeys" : "text.quote").font(.largeTitle)
                Text(LocalizedStringKey("lyrics.status." + model.lyrics.status.rawValue)).multilineTextAlignment(.center)
                Button("lyrics.find") { search = true }
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func compatibilityConfiguration(layout: ImmersiveLyricsLayout?) -> LyricsRenderConfiguration {
        if let layout { return layout.lyricConfiguration(configuration) }
        var value = configuration
        value.immersiveLyrics = false
        return value
    }

    @ViewBuilder private var credits: some View {
        if let document = model.lyrics.document, let content = configuration.credits.content(in: document) {
            Text(String(localized: String.LocalizationValue("render.creditLabel." + content.kind.rawValue)) + ": " + content.names.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
        }
    }

    private func controls(_ snapshot: PlaybackSnapshot) -> some View {
        VStack(spacing: 8) {
            LyricsProgressControl(model: model, snapshot: snapshot)
            HStack(spacing: 40) {
                Button { Task { await model.skipPrevious() } } label: {
                    Label("player.previous", systemImage: "backward.fill").frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!snapshot.restrictions.canSkipPrevious || model.isPerformingAction)
                Button {
                    Task { await model.togglePlayPause() }
                } label: {
                    Label(snapshot.isPlaying ? "player.pause" : "player.play", systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }.font(.largeTitle)
                    .disabled(model.isPerformingAction || (snapshot.isPlaying ? !snapshot.restrictions.canPause : !snapshot.restrictions.canResume))
                Button { Task { await model.skipNext() } } label: {
                    Label("player.next", systemImage: "forward.fill").frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!snapshot.restrictions.canSkipNext || model.isPerformingAction)
            }.labelStyle(.iconOnly).font(.title2).buttonStyle(.plain).frame(height: 48)
            if configuration.showVolume, configuration.showLyrics, model.selectedMusicService != .spotify {
                SystemMusicVolumeView().frame(height: 44)
            }
            if configuration.showVolume, configuration.showLyrics || model.selectedMusicService == .spotify,
               let device = snapshot.device, device.supportsVolume, let volume = device.volumePercent {
                LyricsVolumeControl(model: model, device: device, volume: volume)
            }
        }
    }
}

struct LyricsProgressControl: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot
    @State private var draft = 0.0
    @State private var editing = false
    @State private var editingTrackURI: String?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !snapshot.isPlaying || scenePhase != .active)) { _ in
            VStack(spacing: 0) {
                LyricsCapsuleSlider(value: Binding(get: { editing ? draft : model.progress() }, set: { draft = $0 }), maximum: max(1, snapshot.duration)) { value in
                    if value {
                        draft = model.progress(); editingTrackURI = snapshot.item?.uri; editing = true
                    } else {
                        guard editing, let track = editingTrackURI, track == snapshot.item?.uri else {
                            editing = false; editingTrackURI = nil; return
                        }
                        let target = draft
                        editing = false; editingTrackURI = nil
                        Task { await model.seek(to: target, entry: .progress, trackURI: track) }
                    }
                }.disabled(!snapshot.restrictions.canSeek || model.isPerformingAction).accessibilityLabel(Text("render.progress"))
                HStack {
                    Button {
                        model.renderPreferences.configuration.remainingTime.toggle()
                    } label: {
                        let position = editing ? draft : model.progress()
                        Text(model.renderPreferences.configuration.remainingTime ? "−" + time(snapshot.duration - position) : time(position))
                            .frame(minWidth: 44, minHeight: 24, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(model.renderPreferences.configuration.remainingTime ? "render.remainingTime" : "render.elapsedTime"))
                    .accessibilityHint(Text("render.toggleTime"))
                    Spacer(); Text("−" + time(snapshot.duration - (editing ? draft : model.progress())))
                }
                .font(.caption.monospacedDigit()).opacity(0.7)
            }
        }
        .onChange(of: snapshot.item?.uri) { editing = false; editingTrackURI = nil; draft = 0 }
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }
}

struct LyricsVolumeControl: View {
    @Bindable var model: AppModel
    let device: PlaybackDevice
    let volume: Int
    @State private var editing = false
    @State private var draft = 0.0
    var body: some View {
        HStack {
            Image(systemName: "speaker.fill")
            LyricsCapsuleSlider(value: Binding(get: { editing ? draft : Double(volume) }, set: { draft = $0 }), maximum: 100) { value in
                if value {
                    draft = Double(volume); editing = true
                } else {
                    editing = false; Task { await model.setVolume(percent: Int(draft), deviceID: device.id) }
                }
            }.accessibilityLabel(Text("render.volume")).disabled(device.isRestricted || model.isPerformingAction)
            Image(systemName: "speaker.wave.3.fill")
        }.font(.caption)
    }
}

/// A capsule track without a resting thumb, with a larger accessible hit area.
struct LyricsCapsuleSlider: View {
    @Binding var value: Double
    var maximum: Double
    var editingChanged: (Bool) -> Void
    @State private var dragging = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, value / max(1, maximum)))
            Capsule().fill(.white.opacity(0.25))
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.55)).frame(width: geometry.size.width * fraction)
                }
                .clipShape(Capsule())
                .frame(height: dragging ? 10 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { event in
                        guard enabled else { return }
                        if !dragging {
                            dragging = true; editingChanged(true)
                        }
                        value = min(maximum, max(0, event.location.x / max(1, geometry.size.width) * maximum))
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false; editingChanged(false)
                    })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(min(100, max(0, value / max(1, maximum) * 100))))%"))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            editingChanged(true)
            value = min(maximum, max(0, value + (direction == .increment ? 1 : -1) * maximum / 20))
            editingChanged(false)
        }
    }
}
