import SwiftUI

/// Apple Music supplies only the spatial shell. The lyric canvas embedded here is AMLL's native port.
struct AppleMusicLyricsPlayer: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = false
    @State private var devices = false
    @State private var browsing = false
    @State private var resumeToken = 0
    @GestureState private var dismissalDrag: CGFloat = 0

    private var configuration: LyricsRenderConfiguration {
        model.renderPreferences.configuration.validated()
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = AppleMusicLyricsLayoutMetrics.responsive(in: geometry.size)
            let drag = dismissalTransform(height: geometry.size.height)
            ZStack {
                Color(white: 0.08)
                AMLLMeshBackground(artworkURL: model.playbackSnapshot?.item?.artworkURL,
                                   active: scenePhase == .active && !search && !devices)
                Color.black.opacity(0.16)
                if let snapshot = model.playbackSnapshot, let item = snapshot.item {
                    player(snapshot: snapshot, item: item, metrics: metrics, size: geometry.size)
                } else {
                    ContentUnavailableView("player.noPlayback", systemImage: "music.note")
                }
            }
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: drag.radius, style: .continuous))
            .scaleEffect(drag.scale)
            .offset(y: drag.offset)
            .opacity(drag.opacity)
            .overlay(alignment: .top) { dismissalHandle(metrics: metrics) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $search) { LyricsSearchView(coordinator: model.lyrics) }
        .sheet(isPresented: $devices) { DevicePickerView(model: model) }
        .onChange(of: model.playbackSnapshot?.item?.uri) { browsing = false }
        .alert("error.title", isPresented: Binding(get: { model.presentedError != nil }, set: {
            if !$0 { model.presentedError = nil }
        })) {
            Button("common.ok", role: .cancel) { model.presentedError = nil }
        } message: { Text(model.presentedError?.localizedDescription ?? "") }
    }

    @ViewBuilder
    private func player(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics, size: CGSize) -> some View {
        if size.width >= 700 {
            tabletPlayer(snapshot: snapshot, item: item, metrics: metrics, size: size)
        } else if configuration.showLyrics {
            lyricsPlayer(snapshot: snapshot, item: item, metrics: metrics)
        } else {
            artworkPlayer(snapshot: snapshot, item: item, metrics: metrics, size: size)
        }
    }

    private func lyricsPlayer(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics) -> some View {
        ZStack(alignment: .top) {
            lyricCanvas(snapshot)
                .padding(.horizontal, max(0, metrics.horizontalInset - 20))
            compactMetadata(item: item, metrics: metrics)
                .padding(.horizontal, metrics.horizontalInset)
                .padding(.top, metrics.compactArtworkTop)
        }
    }

    private func artworkPlayer(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics, size: CGSize) -> some View {
        let artworkSide = min(size.width - metrics.expandedArtworkInset * 2, size.height * 0.405)
        return VStack(spacing: 0) {
            artwork(item, side: artworkSide, radius: 12)
                .padding(.top, metrics.expandedArtworkTop)
            fullMetadata(item: item)
                .padding(.top, metrics.expandedMetadataGap)
            LyricsProgressControl(model: model, snapshot: snapshot)
                .padding(.top, metrics.metadataToProgressGap)
            transport(snapshot)
                .padding(.top, metrics.transportTopGap)
            if configuration.showVolume, let device = snapshot.device, device.supportsVolume, let volume = device.volumePercent {
                LyricsVolumeControl(model: model, device: device, volume: volume)
                    .padding(.top, metrics.volumeTopGap)
            }
            bottomActions
                .padding(.top, metrics.bottomActionsTopGap)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, metrics.expandedArtworkInset)
    }

    private func tabletPlayer(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics, size: CGSize) -> some View {
        HStack(spacing: 52) {
            VStack(spacing: 0) {
                artwork(item, side: min(420, size.width * 0.38), radius: 14)
                fullMetadata(item: item).padding(.top, 34)
                LyricsProgressControl(model: model, snapshot: snapshot).padding(.top, 28)
                transport(snapshot).padding(.top, 36)
                if configuration.showVolume, let device = snapshot.device, device.supportsVolume, let volume = device.volumePercent {
                    LyricsVolumeControl(model: model, device: device, volume: volume).padding(.top, 42)
                }
                bottomActions.padding(.top, 26)
            }
            .frame(width: min(440, size.width * 0.42))
            lyricCanvas(snapshot)
        }
        .padding(.horizontal, max(36, metrics.horizontalInset))
        .padding(.top, max(96, metrics.compactArtworkTop))
        .padding(.bottom, 42)
    }

    @ViewBuilder
    private func lyricCanvas(_ snapshot: PlaybackSnapshot) -> some View {
        if let document = model.lyrics.document, !document.lines.isEmpty {
            ZStack(alignment: .bottom) {
                NativeLyricsView(
                    document: document, configuration: configuration, offset: model.lyrics.selection.offset,
                    duration: snapshot.duration, playing: snapshot.isPlaying,
                    active: scenePhase == .active && !search && !devices,
                    canSeek: snapshot.restrictions.canSeek && !model.isPerformingAction,
                    position: { model.progress() }, seek: { target in Task { await model.seek(to: target) } },
                    resumeToken: resumeToken, browsing: { browsing = $0 }
                )
                Button("render.returnCurrent", systemImage: "location.fill") { resumeToken += 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.18))
                    .frame(minHeight: 44)
                    .padding(.bottom, 34)
                    .opacity(browsing ? 1 : 0)
                    .disabled(!browsing)
                    .accessibilityHidden(!browsing)
                    .accessibilityIdentifier("resumeLyricsFollowing")
            }
        } else {
            VStack(spacing: 16) {
                Spacer()
                if model.lyrics.isLoading { ProgressView() }
                Image(systemName: model.lyrics.document?.isInstrumental == true ? "pianokeys" : "text.quote").font(.largeTitle)
                Text(LocalizedStringKey("lyrics.status." + model.lyrics.status.rawValue)).multilineTextAlignment(.center)
                Button("lyrics.find") { search = true }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func compactMetadata(item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics) -> some View {
        HStack(spacing: 12) {
            artwork(item, side: metrics.compactArtworkSize, radius: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(item.artistLine).font(.system(size: 16)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            }
            Spacer(minLength: 8)
            lyricsActionsMenu
            optionsMenu
        }
        .frame(height: metrics.compactArtworkSize)
    }

    private func fullMetadata(item: PlaybackItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 23, weight: .bold)).lineLimit(1)
                Text(item.artistLine).font(.system(size: 20)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
            }
            Spacer(minLength: 8)
            lyricsActionsMenu
            optionsMenu
        }
    }

    private func artwork(_ item: PlaybackItem, side: CGFloat, radius: CGFloat) -> some View {
        AsyncImage(url: item.artworkURL) { image in image.resizable().scaledToFill() }
            placeholder: { RoundedRectangle(cornerRadius: radius).fill(.white.opacity(0.1)).overlay { Image(systemName: "music.note").font(.largeTitle) } }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .id(item.uri)
            .accessibilityHidden(true)
    }

    private func transport(_ snapshot: PlaybackSnapshot) -> some View {
        HStack {
            transportButton("player.previous", systemImage: "backward.fill", disabled: !snapshot.restrictions.canSkipPrevious) {
                await model.skipPrevious()
            }
            Spacer()
            transportButton(snapshot.isPlaying ? "player.pause" : "player.play",
                            systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill", size: 44,
                            disabled: snapshot.isPlaying ? !snapshot.restrictions.canPause : !snapshot.restrictions.canResume)
            {
                await model.togglePlayPause()
            }
            Spacer()
            transportButton("player.next", systemImage: "forward.fill", disabled: !snapshot.restrictions.canSkipNext) {
                await model.skipNext()
            }
        }
        .padding(.horizontal, 40)
        .frame(height: 64)
    }

    private func transportButton(_ title: LocalizedStringKey, systemImage: String, size: CGFloat = 31,
                                 disabled: Bool, action: @escaping @MainActor () async -> Void) -> some View
    {
        Button { Task { await action() } } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: size, weight: .semibold))
                .frame(minWidth: 52, minHeight: 52)
        }
        .buttonStyle(.plain)
        .disabled(disabled || model.isPerformingAction)
    }

    private var bottomActions: some View {
        HStack {
            Button { model.renderPreferences.configuration.showLyrics = true } label: {
                Label("render.showLyrics", systemImage: "quote.bubble")
            }
            Spacer()
            Button { devices = true; Task { await model.loadDevices() } } label: {
                Label("player.devices", systemImage: "airplayaudio")
            }
            Spacer()
            Button { search = true } label: {
                Label("lyrics.find", systemImage: "list.bullet")
            }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(.white.opacity(0.68))
        .padding(.horizontal, 38)
        .frame(height: 48)
    }

    private var optionsMenu: some View {
        Menu {
            Button(configuration.showLyrics ? "render.hideLyrics" : "render.showLyrics", systemImage: "text.quote") {
                model.renderPreferences.configuration.showLyrics.toggle()
            }
            Button("player.devices", systemImage: "airplayaudio") { devices = true; Task { await model.loadDevices() } }
            Button("lyrics.find", systemImage: "magnifyingglass") { search = true }
        } label: {
            Label("render.options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("lyricsDisplayOptions")
    }

    private var lyricsActionsMenu: some View {
        Menu {
            Button("lyrics.find", systemImage: "magnifyingglass") { search = true }
            Button("lyrics.refresh", systemImage: "arrow.clockwise") { model.lyrics.reload(force: true) }
            Button("lyrics.automatic", systemImage: "arrow.uturn.backward") { model.lyrics.restoreAutomatic() }
            Divider()
            Button("lyrics.offset.minus") { model.lyrics.setOffset(model.lyrics.selection.offset - 0.1) }
            Button("lyrics.offset.plus") { model.lyrics.setOffset(model.lyrics.selection.offset + 0.1) }
            Button("lyrics.offset.zero") { model.lyrics.setOffset(0) }
        } label: {
            Label("lyrics.actions", systemImage: "star.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 25, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("lyricsActions")
        .disabled(model.lyrics.track == nil || !model.lyrics.settings.enabled)
    }

    private func dismissalHandle(metrics: AppleMusicLyricsLayoutMetrics) -> some View {
        Button { dismiss() } label: {
            Capsule()
                .fill(.white.opacity(0.48))
                .frame(width: metrics.handleSize.width, height: metrics.handleSize.height)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .padding(.top, metrics.handleTop - 20)
        .accessibilityLabel(Text("common.done"))
        .accessibilityIdentifier("closeLyricsPlayer")
        .contentShape(Rectangle())
        .gesture(dismissGesture)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dismissalDrag) { value, state, _ in
                guard value.translation.height > abs(value.translation.width) else { return }
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                guard value.translation.height > abs(value.translation.width) else { return }
                if value.translation.height > 90 || value.predictedEndTranslation.height > 180 { dismiss() }
            }
    }

    private func dismissalTransform(height: CGFloat) -> (offset: CGFloat, scale: CGFloat, radius: CGFloat, opacity: Double) {
        guard !reduceMotion, height > 0 else { return (0, 1, 0, 1) }
        let clamped = min(height * 0.88, max(0, dismissalDrag))
        let resistance = 1 - min(0.14, clamped / height * 0.18)
        let offset = clamped * resistance
        let progress = min(1, max(0, offset / height))
        return (offset, 1 - min(0.038, progress * 0.065), min(30, progress * 70), 1 - min(0.055, progress * 0.09))
    }
}
