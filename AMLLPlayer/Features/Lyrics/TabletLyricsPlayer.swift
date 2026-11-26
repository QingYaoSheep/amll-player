import SwiftUI

/// Both ordinary iPad pages use the same control surface and keep their own
/// lyric view mounted while the window changes size or lyrics are hidden.
struct TabletLyricsPlayer<Cover: View, Canvas: View>: View {
    let model: AppModel
    let snapshot: PlaybackSnapshot
    let item: PlaybackItem
    let layout: TabletLyricsLayout
    let size: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat
    let configuration: LyricsRenderConfiguration
    let showsLyrics: Bool
    let quickSettings: LyricsQuickSettingsPresentation
    let onDevices: () -> Void
    let onSearch: () -> Void
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var canvas: (LyricsRenderConfiguration) -> Canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var controlsVisible: Bool {
        configuration.showControls && (layout.mode != .mini || !configuration.showLyrics)
    }

    private var showsFloatingLyricActions: Bool {
        layout.mode == .wide || (layout.mode == .narrow && size.width - layout.lyrics.maxX >= 56)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LyricsPageViewport(rect: layout.lyrics, reduceMotion: reduceMotion) {
                canvas(layout.typography.configuration(configuration, in: layout.lyrics.size))
            }
            .opacity(showsLyrics ? 1 : 0)
            .allowsHitTesting(configuration.showLyrics)
            .accessibilityHidden(!configuration.showLyrics)

            place(layout.cover, alignment: .center, content: cover)
                .accessibilityHidden(true)

            Group {
                place(layout.metadata, alignment: .leading) { metadata }
                    .opacity(layout.mode != .mini || !showsLyrics ? 1 : 0)
                    .environment(\.lyricsPageControlsEnabled, layout.mode != .mini || !configuration.showLyrics)
                    .allowsHitTesting(layout.mode != .mini || !configuration.showLyrics)
                    .accessibilityHidden(layout.mode == .mini && configuration.showLyrics)

                place(layout.progress, alignment: .top) {
                    LyricsProgressControl(model: model, snapshot: snapshot, tabletTrackThickness: layout.progressTrackThickness)
                        .offset(y: (layout.progress.height - 44) / 2)
                }
                .environment(\.lyricsPageControlsEnabled, controlsVisible)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)

                transport.opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)

                if let volume = layout.volume, controlsVisible, configuration.showVolume {
                    volumeControl(at: volume)
                }
            }
            .animation(LyricsPageMotion.content, value: controlsVisible)

            if showsFloatingLyricActions {
                floatingLyricActions
            }

            bottomBar
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : LyricsPageMotion.geometry, value: configuration.showLyrics)
        .animation(LyricsPageMotion.content, value: showsLyrics)
    }

    private var metadata: some View {
        HStack(alignment: .center, spacing: 4) {
            LyricsTrackTransition(item: item) { displayed in
                VStack(alignment: .leading, spacing: 2) {
                    if configuration.showTitle, typeSize.isAccessibilitySize {
                        Text(displayed.title).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                    } else if configuration.showTitle {
                        AMLLMetadataText(text: displayed.title, size: max(15, 22 * layout.scale), bold: true, enabled: configuration.marquee)
                    }
                    if configuration.showArtist, typeSize.isAccessibilitySize {
                        Text(displayed.artistLine).font(.subheadline).lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(.white.opacity(0.72))
                    } else if configuration.showArtist {
                        AMLLMetadataText(text: displayed.artistLine, size: max(13, 19 * layout.scale), enabled: configuration.marquee)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    if configuration.showAlbum, let album = displayed.albumTitle, !typeSize.isAccessibilitySize {
                        Text(album).font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }

            if layout.mode != .mini {
                HStack(spacing: 0) {
                    if model.selectedMusicService == .appleMusic {
                        AppleMusicCurrentFavorite(model: model)
                            .foregroundStyle(.white.opacity(0.92))
                    } else if model.selectedMusicService == .netease {
                        NetEaseCurrentFavorite(model: model)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    LyricsQuickSettingsButton(presentation: quickSettings, systemImage: "ellipsis")
                        .foregroundStyle(.white.opacity(0.92))
                        .accessibilityIdentifier("tabletLyricsSettings")
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
            }
        }
    }

    private var transport: some View {
        let side = min(layout.buttonSize, max(44, (layout.transportWidth - 8) / 3))
        let step = max(side, min(layout.transportSpacing, (layout.transportWidth - side) / 2))
        let outerOffset = min(layout.transportWidth / 2 - 22, max(step + side / 2 + 24, step * 1.72))
        return ZStack {
            transportButton("player.previous", image: "backward.fill", side: side, available: snapshot.restrictions.canSkipPrevious) {
                await model.skipPrevious()
            }.offset(x: -step)
            transportButton(snapshot.isPlaying ? "player.pause" : "player.play", image: snapshot.isPlaying ? "pause.fill" : "play.fill",
                            side: side, available: snapshot.isPlaying ? snapshot.restrictions.canPause : snapshot.restrictions.canResume) {
                await model.togglePlayPause()
            }
            transportButton("player.next", image: "forward.fill", side: side, available: snapshot.restrictions.canSkipNext) {
                await model.skipNext()
            }.offset(x: step)
            if model.selectedMusicService != .spotify, layout.mode != .narrow, layout.transportWidth >= 2 * step + side + 96 {
                Button {
                    Task { await model.setShuffle(!snapshot.shuffleEnabled) }
                } label: {
                    Label("quickSettings.shuffle", systemImage: "shuffle")
                        .font(.system(size: 17, weight: .semibold))
                        .modifier(TabletLyricsActionTarget())
                }
                .foregroundStyle(snapshot.shuffleEnabled ? .white : .white.opacity(0.55))
                .accessibilityAddTraits(snapshot.shuffleEnabled ? .isSelected : [])
                .disabled(queueModeDisabled)
                .offset(x: -outerOffset)
                Menu {
                    ForEach(MusicRepeatMode.allCases, id: \.self) { mode in
                        Button {
                            Task { await model.setRepeat(mode) }
                        } label: {
                            if mode == snapshot.repeatMode { Label(mode.title, systemImage: "checkmark") }
                            else { Text(mode.title) }
                        }
                    }
                } label: {
                    Label("quickSettings.repeat", systemImage: snapshot.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 17, weight: .semibold))
                        .modifier(TabletLyricsActionTarget())
                }
                .foregroundStyle(snapshot.repeatMode == .off ? .white.opacity(0.55) : .white)
                .disabled(queueModeDisabled)
                .offset(x: outerOffset)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .frame(width: layout.transportWidth, height: side)
        .offset(x: layout.transportCenter.x - layout.transportWidth / 2, y: layout.transportCenter.y - side / 2)
    }

    private func transportButton(_ label: LocalizedStringKey, image: String, side: CGFloat, available: Bool,
                                 action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(label, systemImage: image)
                .font(.system(size: max(18, min(side * 0.68, layout.glyphSize)), weight: .semibold))
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .disabled(!available || model.isPerformingAction)
    }

    private var queueModeDisabled: Bool {
        model.isPerformingAction || (model.selectedMusicService == .netease && !model.netEasePlayback.canEditPersonalQueue)
    }

    @ViewBuilder private var bottomBar: some View {
        let barY = max(0, size.height - bottomInset - 48)
        if layout.mode == .mini {
            let leftColumn = size.width / 2
            let actionWidth = min(leftColumn, 248)
            HStack(spacing: 4) {
                lyricsToggleButton
                Button(action: onDevices) {
                    Label("player.devices", systemImage: "airplayaudio").modifier(TabletLyricsActionTarget())
                }
                .accessibilityIdentifier("tabletLyricsDevices")
                Button(action: onSearch) {
                    Label("lyrics.find", systemImage: "magnifyingglass").modifier(TabletLyricsActionTarget())
                }
                .accessibilityIdentifier("tabletLyricsSearch")
                LyricsQuickSettingsButton(presentation: quickSettings, systemImage: "ellipsis")
                    .modifier(TabletLyricsActionTarget())
                    .accessibilityIdentifier("tabletLyricsSettings")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: actionWidth, height: 44)
            .offset(x: leftColumn / 2 - actionWidth / 2, y: barY)
            .zIndex(1)
        } else {
            let leadingInset = layout.mode == .wide
                ? max(16, (showsLyrics ? layout.cover.minX : 0.038 * size.width) - 10)
                : max(16, layout.lyrics.minX - 10)
            let trailingInset = max(16, 0.024 * size.width)
            HStack(spacing: 0) {
                Button(action: onDevices) {
                    Label("player.devices", systemImage: "airplayaudio")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .modifier(TabletLyricsActionTarget())
                }
                .accessibilityIdentifier("tabletLyricsDevices")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    lyricsToggleButton
                    if model.selectedMusicService != .spotify {
                        Button { quickSettings.openQueue(reduceMotion: reduceMotion) } label: {
                            Label("quickSettings.queue", systemImage: "list.bullet")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.82))
                                .modifier(TabletLyricsActionTarget())
                        }
                        .accessibilityIdentifier("tabletLyricsQueue")
                    }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(width: size.width, height: 44)
            .offset(x: 0, y: barY)
            .zIndex(1)
        }
    }

    private var lyricsToggleButton: some View {
        Button {
            model.renderPreferences.configuration.showLyrics.toggle()
        } label: {
            Label(configuration.showLyrics ? "render.hideLyrics" : "render.showLyrics",
                  systemImage: configuration.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(configuration.showLyrics ? Color.black.opacity(0.84) : .white.opacity(0.78))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(configuration.showLyrics ? Color.white.opacity(0.88) : Color.clear)
                )
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tabletLyricsToggle")
    }

    private var floatingLyricActions: some View {
        let topY = layout.mode == .wide ? max(topInset, 0.08 * size.height) : layout.lyrics.minY + 12
        let trailing = layout.mode == .wide
            ? max(14, 0.024 * size.width)
            : max(8, (size.width - layout.lyrics.maxX - 44) / 2)
        let auxActive = configuration.translation || configuration.romanization
        return VStack(spacing: 8) {
            Button(action: onSearch) {
                Label("lyrics.find", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tabletLyricsSearch")

            Menu {
                Button {
                    model.renderPreferences.configuration.translation.toggle()
                } label: {
                    if configuration.translation {
                        Label("render.translation", systemImage: "checkmark")
                    } else {
                        Text("render.translation")
                    }
                }
                Button {
                    model.renderPreferences.configuration.romanization.toggle()
                } label: {
                    if configuration.romanization {
                        Label("render.romanization", systemImage: "checkmark")
                    } else {
                        Text("render.romanization")
                    }
                }
                Button {
                    model.renderPreferences.configuration.romanizationFirst.toggle()
                } label: {
                    if configuration.romanizationFirst {
                        Label("render.romanizationFirst", systemImage: "checkmark")
                    } else {
                        Text("render.romanizationFirst")
                    }
                }
            } label: {
                Label("render.translation", systemImage: auxActive ? "character.bubble.fill" : "character.bubble")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(auxActive ? Color.black.opacity(0.84) : .white.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(auxActive ? Color.white.opacity(0.88) : Color.white.opacity(0.18))
                            .overlay(
                                Circle().strokeBorder(Color.white.opacity(auxActive ? 0 : 0.16), lineWidth: 0.5)
                            )
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tabletLyricsTranslationMenu")
        }
        .opacity(showsLyrics ? 1 : 0)
        .allowsHitTesting(configuration.showLyrics)
        .accessibilityHidden(!configuration.showLyrics)
        .offset(x: max(0, size.width - trailing - 44), y: topY)
        .zIndex(1)
    }

    @ViewBuilder private func volumeControl(at track: CGRect) -> some View {
        let device = snapshot.device
        if model.selectedMusicService != .spotify || (device?.supportsVolume == true && device?.volumePercent != nil) {
            place(track, alignment: .center) {
                if model.selectedMusicService == .spotify, let device, let volume = device.volumePercent {
                    LyricsVolumeControl(model: model, device: device, volume: volume,
                                        tabletTrackThickness: layout.progressTrackThickness, showsIcons: false)
                } else {
                    LyricsSystemVolumeControl(tabletTrackThickness: layout.progressTrackThickness)
                }
            }
            speaker("speaker.fill", x: track.minX - 15 * layout.scale, y: track.midY, glyph: 13)
            speaker("speaker.wave.3.fill", x: track.maxX + 13 * layout.scale, y: track.midY, glyph: 17)
        }
    }

    private func speaker(_ symbol: String, x: CGFloat, y: CGFloat, glyph: CGFloat) -> some View {
        let size = 28 * layout.scale
        return Image(systemName: symbol).font(.system(size: glyph * layout.scale))
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: size, height: size)
            .offset(x: x - size / 2, y: y - size / 2)
            .accessibilityHidden(true).allowsHitTesting(false)
    }

    private func place<V: View>(_ rect: CGRect, alignment: Alignment, @ViewBuilder content: () -> V) -> some View {
        content().frame(width: rect.width, height: rect.height, alignment: alignment)
            .offset(x: rect.minX, y: rect.minY)
    }
}

struct TabletLyricsActionTarget: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}
