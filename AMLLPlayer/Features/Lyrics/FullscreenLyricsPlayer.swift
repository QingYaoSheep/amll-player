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
                        AsyncImage(url: url) { image in filled(image, size: geometry.size) }
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
    @State private var browsing = false
    @State private var resumeToken = 0
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 1))) private var drag: CGFloat = 0
    @State private var pageVisible = false
    private var configuration: LyricsRenderConfiguration {
        model.renderPreferences.configuration.validated()
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    AlbumArtworkBackground(url: model.playbackSnapshot?.item?.artworkURL, blur: configuration.backgroundBlur)
                    if let snapshot = model.playbackSnapshot, let item = snapshot.item {
                        let columns = geometry.size.width >= 700 || (geometry.size.width > geometry.size.height && geometry.size.width >= 550)
                        VStack(spacing: 8) {
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
                                ScrollView { metadata(item, wide: false) }
                                    .frame(maxHeight: min(geometry.size.height * 0.38, configuration.coverLayout == .normal ? 290 : 180))
                                lyricContent(snapshot)
                            }
                            if configuration.showControls, !columns {
                                controls(snapshot).padding(.horizontal, 24).padding(.bottom, 8)
                            }
                        }
                        .offset(y: reduceMotion ? 0 : drag)
                    } else {
                        ContentUnavailableView("player.noPlayback", systemImage: "music.note")
                    }
                }
            }
            .onAppear { pageVisible = true }
            .onDisappear { pageVisible = false }
            .foregroundStyle(.white)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.done", systemImage: "chevron.down") { dismiss() }
                        .accessibilityIdentifier("closeLyricsPlayer")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LyricsQuickMenu(coordinator: model.lyrics) { search = true }
                    Menu {
                        Button(configuration.showLyrics ? "render.hideLyrics" : "render.showLyrics", systemImage: "text.quote") {
                            model.renderPreferences.configuration.showLyrics.toggle()
                        }
                        Button("player.devices", systemImage: "airplayaudio") {
                            devices = true; Task { await model.loadDevices() }
                        }
                        NavigationLink("render.settings") { LyricsAppearanceView(preferences: model.renderPreferences) }
                        NavigationLink("lyrics.settings") { LyricsSettingsView(coordinator: model.lyrics) }
                    } label: { Label("render.options", systemImage: "ellipsis.circle") }
                        .accessibilityIdentifier("lyricsDisplayOptions")
                    NavigationLink { SettingsView(model: model) } label: { Label("settings.open", systemImage: "gearshape") }
                        .accessibilityIdentifier("openSettings")
                }
            }
            .sheet(isPresented: $search) { LyricsSearchView(coordinator: model.lyrics) }
            .sheet(isPresented: $devices) { DevicePickerView(model: model) }
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.playbackSnapshot?.item?.uri) { browsing = false }
        .alert("error.title", isPresented: Binding(get: { model.presentedError != nil }, set: {
            if !$0 {
                model.presentedError = nil
            }
        })) {
            Button("common.ok", role: .cancel) { model.presentedError = nil }
        } message: { Text(model.presentedError?.localizedDescription ?? "") }
    }

    private var dismissalHandle: some View {
        Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("lyricsDismissHandle")
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
            .accessibilityHidden(true)
    }

    @ViewBuilder private func metadata(_ item: PlaybackItem, wide: Bool) -> some View {
        let showLarge = !configuration.showLyrics || wide || configuration.coverLayout == .normal
        VStack(spacing: 10) {
            if configuration.coverLayout != .immersive || !configuration.showLyrics {
                AsyncImage(url: item.artworkURL) { image in image.resizable().scaledToFit() }
                    placeholder: { RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)).overlay { Image(systemName: "music.note").font(.largeTitle) } }
                    .frame(width: showLarge ? (wide ? 260 : 160) : 48, height: showLarge ? (wide ? 260 : 160) : 48)
                    .clipShape(RoundedRectangle(cornerRadius: showLarge ? 16 : 8))
                    .id(item.uri)
                    .accessibilityHidden(true)
            }
            if configuration.showTitle {
                MarqueeText(text: item.title, fontSize: 22, enabled: configuration.marquee && scenePhase == .active && pageVisible && !search && !devices && !reduceMotion)
                    .frame(height: typeSize.isAccessibilitySize ? 80 : 32)
            }
            if configuration.showArtist {
                MarqueeText(text: item.artistLine, fontSize: 16, enabled: configuration.marquee && scenePhase == .active && pageVisible && !search && !devices && !reduceMotion)
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

    @ViewBuilder private func lyricContent(_ snapshot: PlaybackSnapshot) -> some View {
        if !configuration.showLyrics {
            Spacer(minLength: 0)
            Button("render.showLyrics") { model.renderPreferences.configuration.showLyrics = true }
            Spacer(minLength: 0)
        } else if let document = model.lyrics.document, !document.lines.isEmpty {
            VStack(spacing: 0) {
                NativeLyricsView(document: document, configuration: configuration, offset: model.lyrics.selection.offset,
                                 duration: snapshot.duration, playing: snapshot.isPlaying, active: pageVisible && scenePhase == .active && !search && !devices,
                                 canSeek: snapshot.restrictions.canSeek && !model.isPerformingAction,
                                 position: { model.progress() }, seek: { target in Task { await model.seek(to: target) } },
                                 resumeToken: resumeToken, browsing: { browsing = $0 })
                Button("render.returnCurrent", systemImage: "location.fill") { resumeToken += 1 }
                    .buttonStyle(.bordered).accessibilityIdentifier("resumeLyricsFollowing")
                    .frame(height: 48).opacity(browsing ? 1 : 0).disabled(!browsing).accessibilityHidden(!browsing)
                credits
            }
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
            if configuration.showVolume, let device = snapshot.device, device.supportsVolume, let volume = device.volumePercent {
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
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !snapshot.isPlaying || scenePhase != .active)) { _ in
            VStack(spacing: 0) {
                Slider(value: Binding(get: { editing ? draft : model.progress() }, set: { draft = $0 }), in: 0 ... max(1, snapshot.duration)) { value in
                    if value {
                        draft = model.progress(); editing = true
                    } else {
                        editing = false; Task { await model.seek(to: draft) }
                    }
                }.disabled(!snapshot.restrictions.canSeek || model.isPerformingAction).accessibilityLabel(Text("render.progress"))
                HStack {
                    Button {
                        model.renderPreferences.configuration.remainingTime.toggle()
                    } label: {
                        let position = editing ? draft : model.progress()
                        Text(model.renderPreferences.configuration.remainingTime ? "−" + time(snapshot.duration - position) : time(position))
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(model.renderPreferences.configuration.remainingTime ? "render.remainingTime" : "render.elapsedTime"))
                    .accessibilityHint(Text("render.toggleTime"))
                    Spacer(); Text(time(snapshot.duration))
                }
                .font(.caption.monospacedDigit()).opacity(0.7)
            }
        }
        .onChange(of: snapshot.item?.uri) { editing = false; draft = 0 }
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
            Slider(value: Binding(get: { editing ? draft : Double(volume) }, set: { draft = $0 }), in: 0 ... 100) { value in
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
