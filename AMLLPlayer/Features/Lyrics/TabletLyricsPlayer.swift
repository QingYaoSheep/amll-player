import SwiftUI

/// Both ordinary iPad pages use the same control surface and keep their own
/// lyric view mounted while the window changes size or lyrics are hidden.
struct TabletLyricsPlayer<Cover: View, Canvas: View, Actions: View>: View {
    let model: AppModel
    let snapshot: PlaybackSnapshot
    let item: PlaybackItem
    let layout: TabletLyricsLayout
    let size: CGSize
    let bottomInset: CGFloat
    let configuration: LyricsRenderConfiguration
    let showsLyrics: Bool
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var canvas: (LyricsRenderConfiguration) -> Canvas
    @ViewBuilder var actions: () -> Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var controlsVisible: Bool {
        configuration.showControls && (layout.mode != .mini || !configuration.showLyrics)
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
                    place(volume, alignment: .center) { volumeControl }
                }
            }
            .animation(LyricsPageMotion.content, value: controlsVisible)

            let leftColumn = layout.mode == .mini ? size.width / 2 : layout.mode == .wide ? layout.transportWidth : size.width
            let actionX = layout.mode == .wide ? layout.transportCenter.x : leftColumn / 2
            let actionWidth = min(leftColumn, 248)
            HStack(spacing: 4) {
                Button {
                    model.renderPreferences.configuration.showLyrics.toggle()
                } label: {
                    Label(configuration.showLyrics ? "render.hideLyrics" : "render.showLyrics",
                          systemImage: configuration.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .modifier(TabletLyricsActionTarget())
                }
                .accessibilityIdentifier("tabletLyricsToggle")
                actions()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: actionWidth, height: 44)
            .offset(x: actionX - actionWidth / 2, y: max(0, size.height - bottomInset - 48))
            .zIndex(1)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : LyricsPageMotion.geometry, value: configuration.showLyrics)
        .animation(LyricsPageMotion.content, value: showsLyrics)
    }

    private var metadata: some View {
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
    }

    private var transport: some View {
        let side = min(layout.buttonSize, max(44, (layout.transportWidth - 8) / 3))
        let step = max(side, min(layout.transportSpacing, (layout.transportWidth - side) / 2))
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
                        .modifier(TabletLyricsActionTarget())
                }
                .foregroundStyle(snapshot.shuffleEnabled ? .white : .white.opacity(0.55))
                .accessibilityAddTraits(snapshot.shuffleEnabled ? .isSelected : [])
                .disabled(queueModeDisabled)
                .offset(x: 22 - layout.transportWidth / 2)
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
                        .modifier(TabletLyricsActionTarget())
                }
                .foregroundStyle(snapshot.repeatMode == .off ? .white.opacity(0.55) : .white)
                .disabled(queueModeDisabled)
                .offset(x: layout.transportWidth / 2 - 22)
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

    @ViewBuilder private var volumeControl: some View {
        if model.selectedMusicService == .spotify {
            if let device = snapshot.device, device.supportsVolume, let volume = device.volumePercent {
                LyricsVolumeControl(model: model, device: device, volume: volume, tabletTrackThickness: 7.5 * layout.scale)
            }
        } else {
            SystemMusicVolumeView().frame(height: 44).padding(.horizontal, 30 * layout.scale)
        }
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
