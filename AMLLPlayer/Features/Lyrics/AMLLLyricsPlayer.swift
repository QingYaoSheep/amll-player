import QuartzCore
import SwiftUI

/// Unified AMLL lyric page. Its shell follows the previously added
/// Apple Music-derived geometry while the lyric viewport uses the native AMLL
/// motion and glyph engine.
struct AMLLLyricsPlayer: View {
    @Bindable var model: AppModel
    var usesSystemZoom = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var immersiveInformationHeight: CGFloat = 64
    @State private var immersiveInformationTextBottom: CGFloat?
    @State private var stillArtwork = ImmersiveStillArtwork()
    @State private var search = false
    @State private var devices = false
    @State private var quickSettings: LyricsQuickSettingsPresentation
    @State private var browsing = false
    @State private var resumeToken = 0
    @State private var shellMotion = LyricsMotionModel()
    @State private var artworkLoader = AnimatedArtworkLoader()
    @State private var artworkNetwork = ArtworkNetworkPolicy.shared
    @State private var artworkPortraitViewport = false
    @State private var artworkReflectionFrames = ArtworkReflectionFrames()
    @State private var artworkDebug = ImmersiveArtworkDebugStore.shared
    @State private var showingArtworkDebug = false
    @State private var presentation = LyricsPagePresentationCoordinator()
    @State private var artworkFrame: CGRect?
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.32, dampingFraction: 0.9))) private var dismissalDrag: CGFloat = 0

    init(model: AppModel, usesSystemZoom: Bool = false, presentation: LyricsQuickSettingsPresentation? = nil) {
        self.model = model
        self.usesSystemZoom = usesSystemZoom
        _quickSettings = State(initialValue: presentation ?? LyricsQuickSettingsPresentation())
        _presentation = State(initialValue: LyricsPagePresentationCoordinator(showsLyrics: model.renderPreferences.configuration.showLyrics))
    }

    private var configuration: LyricsRenderConfiguration {
        model.renderPreferences.configuration.validated()
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = AppleMusicLyricsLayoutMetrics.responsive(in: geometry.size)
            let drag = dismissalTransform(height: geometry.size.height)
            let lyricLayout = immersiveLyricsLayout(size: geometry.size, bottomInset: geometry.safeAreaInsets.bottom)
            let canvasLayout = immersiveLyricsLayout(size: geometry.size, bottomInset: geometry.safeAreaInsets.bottom, retainingHidden: true)
            let immersive = lyricLayout != nil || (model.playbackSnapshot?.item.map { mountsImmersiveArtwork($0, size: geometry.size) } ?? false)
            ZStack {
                ZStack {
                    Color(white: 0.08)
                    if let item = model.playbackSnapshot?.item {
                        mediaBackdrop(item, layout: lyricLayout, immersive: immersive, size: geometry.size)
                    }
                }
                // A stable sibling, not an overlay whose identity inherits
                // the conditional background's identity.
                Group {
                    if let snapshot = model.playbackSnapshot, let item = snapshot.item {
                        player(snapshot: snapshot, item: item, metrics: metrics, size: geometry.size, lyricLayout: canvasLayout)
                    } else {
                        ContentUnavailableView("player.noPlayback", systemImage: "music.note")
                    }
                }
                .opacity(immersive ? drag.opacity : 1)
            }
            .modifier(LyricsPageCompositing())
            .modifier(LyricsPageDynamicRange())
            .coordinateSpace(name: "lyricsPage")
            .onPreferenceChange(LyricsArtworkFrameKey.self) { if let frame = $0, frame.width > 0 { artworkFrame = frame } }
            .onChange(of: LyricsPagePresentationCoordinator.Mode(showsLyrics: configuration.showLyrics,
                immersive: lyricLayout != nil), initial: true) { _, mode in
                presentation.update(mode, reduceMotion: reduceMotion)
            }
            .onChange(of: geometry.size, initial: true) { _, size in
                artworkPortraitViewport = size.height > size.width
            }
            .onChange(of: artworkPresentationDiagnostic(size: geometry.size), initial: true) { _, diagnostic in
                artworkReflectionFrames.pageDiagnostic = diagnostic
            }
            .foregroundStyle(.white)
            // Clip the already-composited page, never the transparent lyric
            // foreground separately from the backdrop it must blend with.
            .clipShape(RoundedRectangle(cornerRadius: drag.radius, style: .continuous))
            .scaleEffect(drag.scale)
            .offset(y: drag.offset)
            .opacity(immersive ? 1 : drag.opacity)
            .overlay(alignment: .top) { dismissalHandle(metrics: metrics) }
            .overlay(alignment: .topTrailing) {
                if artworkDebug.showsButton, let item = model.playbackSnapshot?.item,
                   lyricLayout != nil || mountsImmersiveArtwork(item, size: geometry.size) {
                    ImmersiveArtworkDebugButton { showingArtworkDebug = true }
                    .padding(.top, geometry.safeAreaInsets.top + 48).padding(.trailing, 16)
                }
            }
            .sheet(isPresented: $showingArtworkDebug) {
                ImmersiveArtworkDebugPanel(viewport: geometry.size,
                    video: lyricLayout?.visibleCover ?? AMLLImmersiveArtworkGeometry.fittedFrame(
                        container: artworkDebug.configuration[.video].frame(AMLLImmersiveArtworkGeometry.frame(
                            viewport: geometry.size, video: artworkLoader.videoSize ?? .zero)),
                        source: artworkLoader.videoSize ?? CGSize(width: 9, height: 16)),
                    backgroundDimming: configuration.backgroundDimming ?? 0.16,
                    frames: artworkReflectionFrames)
                    .presentationDetents([.medium, .large])
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .modifier(LyricsQuickSettingsPresenter(model: model, presentation: quickSettings,
            artworkStatus: configuration.animatedArtwork?.enabled == true ? artworkStatus : nil))
        .sheet(isPresented: $search) { LyricsSearchView(coordinator: model.lyrics) }
        .sheet(isPresented: $devices) { DevicePickerView(model: model) }
        .onChange(of: model.playbackSnapshot?.item?.uri) { browsing = false }
        .task(id: artworkRequestKey) { await loadAnimatedArtwork() }
        .task(id: stillArtworkRequestKey) {
            await stillArtwork.load(stillArtworkRequestKey == nil ? nil : model.playbackSnapshot?.item?.artworkURL)
        }
        .alert("error.title", isPresented: Binding(get: { model.presentedError != nil }, set: {
            if !$0 {
                model.presentedError = nil
            }
        })) {
            Button("common.ok", role: .cancel) { model.presentedError = nil }
        } message: { Text(model.presentedError?.localizedDescription ?? "") }
    }

    @ViewBuilder
    private func player(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics, size: CGSize,
                        lyricLayout: ImmersiveLyricsLayout?) -> some View {
        if AppleMusicLyricsLayoutMetrics.usesTabletColumns(in: size) {
            tabletPlayer(snapshot: snapshot, item: item, metrics: metrics, size: size)
        } else {
            ZStack(alignment: .topLeading) {
                lyricsPlayer(snapshot: snapshot, item: item, metrics: metrics, size: size, layout: lyricLayout)
                    .environment(\.lyricsPageControlsEnabled, configuration.showLyrics)
                    .opacity(presentation.mode.showsLyrics ? 1 : 0)
                    .allowsHitTesting(configuration.showLyrics).accessibilityHidden(!configuration.showLyrics)
                artworkPlayer(snapshot: snapshot, item: item, metrics: metrics, size: size)
                    .environment(\.lyricsPageControlsEnabled, !configuration.showLyrics)
                    .opacity(presentation.mode.showsLyrics ? 0 : 1)
                    .allowsHitTesting(!configuration.showLyrics).accessibilityHidden(configuration.showLyrics)
            }
            .animation(LyricsPageMotion.content, value: presentation.mode.showsLyrics)
        }
    }

    private func lyricsPlayer(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics,
                              size: CGSize, layout: ImmersiveLyricsLayout?) -> some View {
        let rect = layout?.lyrics ?? CGRect(origin: .zero, size: size)
        // Keep the same canvas identity while switching modes. Only its viewport
        // changes; seek state, source timing and the live frame engine persist.
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                LyricsPageViewport(rect: rect, reduceMotion: reduceMotion) {
                  lyricCanvas(snapshot, fadeTop: layout != nil ? 0 : (configuration.showMetadata ?? true)
                    ? metrics.compactArtworkTop + metrics.compactArtworkSize : 44,
                    renderConfiguration: lyricConfiguration(layout: layout, page: size))
                    .padding(.horizontal, layout == nil ? max(0, metrics.horizontalInset - 20) : 0)
                }
                ZStack(alignment: .topLeading) {
                    LyricsTrackTransition(item: item) { compactMetadata(item: $0, metrics: metrics) }
                        .environment(\.lyricsPageControlsEnabled, layout == nil && (configuration.showMetadata ?? true) && configuration.showLyrics)
                        .opacity(layout == nil && (configuration.showMetadata ?? true) ? 1 : 0)
                        .allowsHitTesting(layout == nil && (configuration.showMetadata ?? true) && configuration.showLyrics)
                        .accessibilityHidden(layout != nil || !(configuration.showMetadata ?? true) || !configuration.showLyrics)
                    ImmersiveLyricsHeader(model: model, snapshot: snapshot, item: item, presentation: quickSettings,
                        additive: layout?.overlaysArtwork ?? false)
                        .environment(\.lyricsPageControlsEnabled, layout != nil && configuration.showLyrics)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: ImmersiveInformationHeightKey.self, value: proxy.size.height)
                            }
                        }
                        .opacity(layout != nil ? 1 : 0)
                        .allowsHitTesting(layout != nil).accessibilityHidden(layout == nil)
                }
                .frame(width: layout?.information.width ?? max(1, size.width - metrics.horizontalInset * 2))
                .frame(height: layout?.information.height ?? metrics.compactArtworkSize, alignment: .topLeading)
                .offset(x: layout?.information.minX ?? metrics.horizontalInset,
                        y: layout?.information.minY ?? metrics.compactArtworkTop)
                .animation(reduceMotion ? nil : LyricsPageMotion.geometry, value: layout?.information)
                .animation(LyricsPageMotion.content, value: layout != nil)
            }
            .frame(width: size.width, height: layout?.contentHeight ?? size.height, alignment: .topLeading)
        }
        .scrollDisabled(layout?.requiresScrolling != true)
        // The native canvas owns its viewport mask. A second transparent
        // scroll clip can isolate its additive/EDR layers from the backdrop.
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .onPreferenceChange(ImmersiveInformationHeightKey.self) { height in
            if height > 0, abs(immersiveInformationHeight - height) > 0.5 { immersiveInformationHeight = height }
        }
        .onPreferenceChange(ImmersiveInformationTextBottomKey.self) { bottom in
            if let bottom, abs((immersiveInformationTextBottom ?? -1) - bottom) > 0.5 { immersiveInformationTextBottom = bottom }
        }
    }

    private func lyricConfiguration(layout: ImmersiveLyricsLayout?, page: CGSize) -> LyricsRenderConfiguration {
        if let layout { return layout.lyricConfiguration(configuration, page: page) }
        var value = configuration
        value.immersiveLyrics = false
        return value
    }

    private func artworkPlayer(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics, size: CGSize) -> some View {
        let artworkSide = min(size.width - metrics.expandedArtworkInset * 2, size.height * 0.405)
        return VStack(spacing: 0) {
            artwork(item, side: artworkSide, radius: 12,
                    hideStatic: mountsImmersiveArtwork(item, size: size) && artworkLoader.hasPresentedFrame,
                    recordsFrame: !configuration.showLyrics)
                .padding(.top, metrics.expandedArtworkTop)
            LyricsTrackTransition(item: item) { fullMetadata(item: $0) }
                .padding(.top, metrics.expandedMetadataGap)
                .padding(.horizontal, 8)
            if configuration.showControls {
                LyricsProgressControl(model: model, snapshot: snapshot)
                    .padding(.horizontal, 8)
                    .padding(.top, metrics.metadataToProgressGap)
                transport(snapshot)
                    .padding(.top, metrics.transportTopGap)
                if configuration.showVolume, model.selectedMusicService == .spotify,
                   let device = snapshot.device, device.supportsVolume,
                   let volume = device.volumePercent
                {
                    LyricsVolumeControl(model: model, device: device, volume: volume)
                        .padding(.horizontal, 8)
                        .padding(.top, metrics.volumeTopGap)
                }
                bottomActions
                    .padding(.top, metrics.bottomActionsTopGap)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, metrics.expandedArtworkInset)
    }

    private func tabletPlayer(snapshot: PlaybackSnapshot, item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics, size: CGSize) -> some View {
        HStack(spacing: 52) {
            VStack(spacing: 0) {
                artwork(item, side: min(420, size.width * 0.38), radius: 14)
                fullMetadata(item: item).padding(.top, 34)
                if configuration.showControls {
                    LyricsProgressControl(model: model, snapshot: snapshot).padding(.top, 28)
                    transport(snapshot).padding(.top, 36)
                    if configuration.showVolume, configuration.showLyrics || model.selectedMusicService == .spotify,
                       let device = snapshot.device, device.supportsVolume,
                       let volume = device.volumePercent
                    {
                        LyricsVolumeControl(model: model, device: device, volume: volume).padding(.top, 42)
                    }
                    if configuration.showVolume, configuration.showLyrics, model.selectedMusicService != .spotify {
                        SystemMusicVolumeView().frame(height: 44).padding(.top, 42)
                    }
                    bottomActions.padding(.top, 26)
                }
            }
            .frame(width: min(440, size.width * 0.42))
            lyricCanvas(snapshot)
                .opacity(presentation.mode.showsLyrics ? 1 : 0)
                .allowsHitTesting(configuration.showLyrics).accessibilityHidden(!configuration.showLyrics)
        }
        .padding(.horizontal, max(36, metrics.horizontalInset))
        .padding(.top, max(96, metrics.compactArtworkTop))
        .padding(.bottom, 42)
    }

    @ViewBuilder
    private func lyricCanvas(_ snapshot: PlaybackSnapshot, fadeTop: CGFloat? = nil,
                             renderConfiguration: LyricsRenderConfiguration? = nil) -> some View {
        if let document = model.lyrics.document, !document.lines.isEmpty {
            ZStack(alignment: .bottom) {
                AMLLLyricsDisplay(
                    model: model,
                    snapshot: snapshot,
                    configuration: renderConfiguration ?? configuration,
                    active: presentation.rendersLyrics && scenePhase == .active && !search && !devices && !quickSettings.suspendsPage,
                    resumeToken: resumeToken,
                    fadeTop: fadeTop,
                    browsing: { browsing = $0 }
                )
                // UIViewRepresentable has no intrinsic height. Give the
                // lyric viewport the whole shell so its display link and
                // layout cache use the complete Apple Music-derived viewport.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func compactMetadata(item: PlaybackItem, metrics: AppleMusicLyricsLayoutMetrics) -> some View {
        HStack(spacing: 12) {
            artwork(item, side: metrics.compactArtworkSize, radius: 11,
                recordsFrame: configuration.showLyrics && (configuration.showMetadata ?? true))
            VStack(alignment: .leading, spacing: 2) {
                if configuration.showTitle {
                    AMLLMetadataText(text: item.title, size: 17, bold: true, enabled: configuration.marquee)
                        .blendMode(reduceTransparency ? .normal : .plusLighter)
                }
                if configuration.showArtist {
                    AMLLMetadataText(text: item.artistLine, size: 16, enabled: configuration.marquee).opacity(0.72)
                        .blendMode(reduceTransparency ? .normal : .plusLighter)
                }
                if configuration.showAlbum, let album = item.albumTitle {
                    AMLLMetadataText(text: album, size: 14, enabled: configuration.marquee).opacity(0.58)
                        .blendMode(reduceTransparency ? .normal : .plusLighter)
                }
                if model.lyrics.selection.candidate != nil {
                    Text("lyrics.match.manual")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                        .accessibilityIdentifier("lyricsManualLock")
                }
            }
            Spacer(minLength: 8)
            LyricsPageControls {
            if model.selectedMusicService == .appleMusic {
                AppleMusicCurrentFavorite(model: model)
            } else if model.selectedMusicService == .netease {
                NetEaseCurrentFavorite(model: model)
            } else {
                lyricsActionsMenu
            }
            optionsMenu
            }
        }
        .frame(height: metrics.compactArtworkSize)
    }

    private func fullMetadata(item: PlaybackItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if configuration.showTitle {
                    AMLLMetadataText(text: item.title, size: 23, bold: true, enabled: configuration.marquee)
                        .blendMode(reduceTransparency ? .normal : .plusLighter)
                }
                if configuration.showArtist {
                    AMLLMetadataText(text: item.artistLine, size: 20, enabled: configuration.marquee).opacity(0.62)
                        .blendMode(reduceTransparency ? .normal : .plusLighter)
                }
                if configuration.showAlbum, let album = item.albumTitle {
                    AMLLMetadataText(text: album, size: 16, enabled: configuration.marquee).opacity(0.5)
                        .blendMode(reduceTransparency ? .normal : .plusLighter)
                }
            }
            Spacer(minLength: 8)
            LyricsPageControls {
            if model.selectedMusicService == .appleMusic {
                AppleMusicCurrentFavorite(model: model)
            } else if model.selectedMusicService == .netease {
                NetEaseCurrentFavorite(model: model)
            } else {
                lyricsActionsMenu
            }
            optionsMenu
            }
        }
    }

    private var phoneLyricsUsesStaticArtwork: Bool {
        AMLLArtworkDisplayPolicy.usesStaticLyricsCover(isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                                                       showsLyrics: configuration.showLyrics) && !usesImmersiveLyrics
    }

    private var usesImmersiveLyrics: Bool {
        configuration.immersiveLyrics == true && configuration.showLyrics && artworkPortraitViewport
            && UIDevice.current.userInterfaceIdiom == .phone
    }

    private var stillArtworkRequestKey: String? {
        guard let item = model.playbackSnapshot?.item else { return nil }
        return item.uri + "|" + (item.artworkURL?.absoluteString ?? "")
    }

    private var currentStillFrame: ImmersiveStillFrame? {
        stillArtwork.frame(for: model.playbackSnapshot?.item?.artworkURL)
    }

    private func immersiveLyricsLayout(size: CGSize, bottomInset: CGFloat, retainingHidden: Bool = false) -> ImmersiveLyricsLayout? {
        var layoutConfiguration = configuration
        if retainingHidden { layoutConfiguration.showLyrics = true }
        guard ImmersiveLyricsLayout.isEnabled(layoutConfiguration, isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                                              viewport: size) else { return nil }
        let source: CGSize
        let presentsVideo = immersiveLyricsHasVideo && artworkLoader.videoSize != nil
        if presentsVideo, let actual = artworkLoader.videoSize { source = actual }
        else { source = currentStillFrame?.size ?? CGSize(width: 1, height: 1) }
        return .resolve(viewport: size, artwork: source, informationHeight: immersiveInformationHeight,
                        bottomInset: bottomInset, isVideo: presentsVideo,
                        informationTextBottom: immersiveInformationTextBottom,
                        artworkAdjustment: artworkDebug.configuration[.video])
    }

    private var immersiveLyricsHasVideo: Bool {
        configuration.animatedArtwork?.enabled == true && !reduceMotion
            && artworkNetwork.permits(allowCellular: configuration.animatedArtwork?.allowCellular ?? false)
            && artworkLoader.trackID == model.playbackSnapshot?.item?.uri && artworkLoader.playbackURL != nil
    }

    private func mountsImmersiveArtwork(_ item: PlaybackItem, size: CGSize) -> Bool {
        AMLLArtworkDisplayPolicy.mountsImmersive(
            enabled: configuration.animatedArtwork?.enabled == true, reduceMotion: reduceMotion,
            staticLyricsCover: phoneLyricsUsesStaticArtwork,
            selectedImmersive: configuration.animatedArtwork?.presentation == .immersive,
            portraitViewport: size.height > size.width, kind: artworkLoader.kind,
            currentTrack: artworkLoader.trackID == item.uri, hasURL: artworkLoader.playbackURL != nil
        )
    }

    private func artwork(_ item: PlaybackItem, side: CGFloat, radius: CGFloat,
                         hideStatic: Bool = false, recordsFrame: Bool = true) -> some View
    {
        RoundedRectangle(cornerRadius: radius).fill(.white.opacity(0.1))
            .overlay { if currentStillFrame == nil { Image(systemName: "music.note").font(.largeTitle) } }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: configuration.artworkCornerRadius ?? radius, style: .continuous))
            .lyricsArtworkFrame(enabled: recordsFrame)
            .opacity(hideStatic || currentStillFrame != nil || (showsInlineVideo && artworkLoader.hasPresentedFrame) ? 0 : 1)
            .accessibilityHidden(true)
    }

    private var showsInlineVideo: Bool {
        AMLLArtworkDisplayPolicy.mountsSquare(enabled: configuration.animatedArtwork?.enabled == true,
            reduceMotion: reduceMotion, staticLyricsCover: phoneLyricsUsesStaticArtwork, kind: artworkLoader.kind,
            currentTrack: artworkLoader.trackID == model.playbackSnapshot?.item?.uri, hasURL: artworkLoader.playbackURL != nil)
    }

    private func mediaBackdrop(_ item: PlaybackItem, layout: ImmersiveLyricsLayout?, immersive: Bool, size: CGSize) -> some View {
        let canKeepVideo = immersiveLyricsHasVideo
        let showsInlineCover = !configuration.showLyrics || (configuration.showMetadata ?? true)
            || AppleMusicLyricsLayoutMetrics.usesTabletColumns(in: size)
        let cover = layout?.cover ?? AMLLImmersiveArtworkGeometry.frame(viewport: size, video: artworkLoader.videoSize ?? .zero)
        let mediaLayout: ImmersiveArtworkMedia.Layout = immersive
            ? .immersive(cover: cover, viewport: size, configuration: configuration,
                tuning: artworkDebug.configuration, presentsFrame: canKeepVideo && artworkLoader.hasPresentedFrame,
                reduceTransparency: reduceTransparency)
            : .inline(frame: artworkFrame ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                visible: showsInlineCover && (currentStillFrame != nil || showsInlineVideo),
                presentsFrame: showsInlineVideo && artworkLoader.hasPresentedFrame,
                radius: configuration.artworkCornerRadius ?? (AppleMusicLyricsLayoutMetrics.usesTabletColumns(in: size)
                    ? 14 : configuration.showLyrics ? 11 : 12), dimming: configuration.backgroundDimming ?? 0.16)
        var video = canKeepVideo ? immersiveVideo(item) : nil
        if !immersive && !showsInlineVideo { video?.active = false }
        return ImmersiveArtworkMedia(video: video, frames: artworkReflectionFrames,
            layout: mediaLayout,
            background: artworkBackground(meshForegroundBlending: needsMeshForegroundBlending(immersive: immersive),
                enabled: !immersive || artworkDebug.configuration[.background].enabled),
            still: currentStillFrame)
            .frame(width: size.width, height: size.height)
            .animation(reduceMotion ? nil : LyricsPageMotion.geometry, value: mediaLayout.video)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func immersiveVideo(_ item: PlaybackItem) -> AnimatedArtwork {
        let url = artworkLoader.playbackURL!
        let token = artworkLoader.requestToken
        return AnimatedArtwork(url: url,
                               active: scenePhase == .active && !search && !devices && !quickSettings.suspendsPage && model.playbackSnapshot?.isPlaying == true,
                               allowCellular: configuration.animatedArtwork?.allowCellular ?? false,
                               reflectionFrames: artworkReflectionFrames,
                               onFailure: { url, error in artworkLoader.playbackFailed(trackID: item.uri, url: url, error: error, token: token) },
                               onState: { url, state in artworkLoader.playbackChanged(token: token, url: url, state: state) },
                               onFirstFrame: { url, videoSize in artworkLoader.firstFramePresented(token: token, url: url, size: videoSize) },
                               gravity: .resizeAspect,
                               fadesBottom: false)
    }

    private func artworkBackground(meshForegroundBlending: Bool = false, enabled: Bool = true) -> AMLLBackground {
        AMLLBackground(artworkURL: model.playbackSnapshot?.item?.artworkURL,
            active: enabled && scenePhase == .active && !search && !devices && !quickSettings.suspendsPage,
            blur: configuration.backgroundBlur, mode: configuration.backgroundMode ?? .mesh,
            color: configuration.backgroundColor ?? .sourceDefault,
            gradientEnd: configuration.backgroundGradientEnd ?? .sourceDefault,
            flowing: configuration.flowingBackground ?? .init(), dimming: 0,
            meshForegroundBlending: meshForegroundBlending)
    }

    private func needsMeshForegroundBlending(immersive: Bool) -> Bool {
        guard #available(iOS 27.0, *) else { return false }
        return UIDevice.current.userInterfaceIdiom == .phone && configuration.showLyrics && !immersive
            && !reduceTransparency && (configuration.backgroundMode ?? .mesh).isMesh
    }

    private var artworkRequestKey: String {
        let settings = configuration.animatedArtwork ?? .init()
        return [model.playbackSnapshot?.item?.uri ?? "", String(settings.enabled), String(settings.allowCellular),
                (settings.presentation ?? .square).rawValue, String(artworkPortraitViewport), String(reduceMotion),
                String(usesImmersiveLyrics),
                String(artworkNetwork.permits(allowCellular: settings.allowCellular)),
                model.lyrics.settings.storefront, model.lyrics.settings.language,
                model.lyrics.selection.candidate?.id ?? ""].joined(separator: "|")
    }

    private func loadAnimatedArtwork() async {
        let settings = configuration.animatedArtwork ?? .init()
        guard settings.enabled, !reduceMotion,
              artworkNetwork.permits(allowCellular: settings.allowCellular),
              let item = model.playbackSnapshot?.item else { artworkLoader.reset(); return }
        await artworkLoader.loadForLyrics(item: item, coordinator: model.lyrics, settings: settings,
            prefersPortrait: (settings.presentation == .immersive || usesImmersiveLyrics) && artworkPortraitViewport)
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
        LyricsQuickSettingsButton(presentation: quickSettings)
    }

    private var artworkStatus: String {
        if phoneLyricsUsesStaticArtwork {
            return "动态封面：歌词模式使用静态封面"
        }
        if reduceMotion {
            return "动态封面：减少动态效果，使用静态图"
        }
        if !artworkNetwork.permits(allowCellular: configuration.animatedArtwork?.allowCellular ?? false) {
            return "动态封面：等待允许的网络，使用静态图"
        }
        switch artworkLoader.status {
        case .idle: return "动态封面：静态图"
        case .loading: return "动态封面：加载中"
        case .streaming:
            return artworkLoader.failureCode == nil
                ? "动态封面：" + artworkPlaybackDescription + "，静默缓存中"
                : "动态封面：使用在线资源，缓存未完成（\(artworkLoader.failureCode ?? "")）"
        case .ready: return "动态封面：已缓存，" + artworkPlaybackDescription
        case .unavailable: return "动态封面：无匹配布局的视频，使用静态图"
        case .failed: return "动态封面：加载失败，使用静态图（\(artworkLoader.failureCode ?? "未知错误")）"
        }
    }

    private func artworkPresentationDiagnostic(size: CGSize) -> String {
        let immersive = model.playbackSnapshot?.item.map { mountsImmersiveArtwork($0, size: size) } ?? false
        let resource = artworkLoader.playbackURL.map { $0.isFileURL ? "本地" : "在线" } ?? "无"
        return "页面资源：\(artworkLoader.status.rawValue)；类型：\(artworkLoader.kind?.rawValue ?? "无")；来源：\(resource)；沉浸挂载：\(immersive ? "是" : "否")；歌词：\(configuration.showLyrics ? "显示" : "隐藏")\n播放页状态：\(artworkStatus)；页面：\(Int(size.width))×\(Int(size.height)) pt"
    }

    private var artworkPlaybackDescription: String {
        switch artworkLoader.playbackState {
        case .preparing: "准备首帧"
        case .displayed: "无声播放中"
        case .buffering: "缓冲中"
        case .paused: "已暂停"
        case .failed: "播放失败，使用静态图"
        }
    }

    private var lyricsActionsMenu: some View {
        LyricsPageControls {
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
    }

    private func dismissalHandle(metrics: AppleMusicLyricsLayoutMetrics) -> some View {
        Button { dismiss() } label: {
            Capsule()
                .fill(.white.opacity(0.48))
                .frame(width: metrics.handleSize.width, height: metrics.handleSize.height)
                .frame(maxWidth: .infinity).frame(height: 44)
        }
        .buttonStyle(.plain)
        .padding(.top, metrics.handleTop - 20)
        .accessibilityLabel(Text("common.done"))
        .accessibilityIdentifier("closeLyricsPlayer")
        .contentShape(Rectangle())
        .gesture(dismissGesture, including: usesSystemZoom ? .none : .all)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dismissalDrag) { value, state, _ in
                guard value.translation.height > abs(value.translation.width) else { return }
                state = max(0, value.translation.height)
            }
            .onChanged { value in
                guard value.translation.height > abs(value.translation.width) else { return }
                if shellMotion.mode != .dismissing {
                    shellMotion.handle(.beginDismissal, at: CACurrentMediaTime())
                }
            }
            .onEnded { value in
                guard value.translation.height > abs(value.translation.width) else {
                    shellMotion.handle(.cancelDismissal, at: CACurrentMediaTime())
                    return
                }
                if value.translation.height > 90 || value.predictedEndTranslation.height > 180 {
                    dismiss()
                } else {
                    shellMotion.handle(.cancelDismissal, at: CACurrentMediaTime())
                }
            }
    }

    private func dismissalTransform(height: CGFloat) -> (offset: CGFloat, scale: CGFloat, radius: CGFloat, opacity: Double) {
        guard !usesSystemZoom, !reduceMotion, height > 0 else { return (0, 1, 0, 1) }
        let clamped = min(height * 0.88, max(0, dismissalDrag))
        let resistance = 1 - min(0.14, clamped / height * 0.18)
        let offset = clamped * resistance
        let progress = min(1, max(0, offset / height))
        return (offset, 1 - min(0.038, progress * 0.065), min(30, progress * 70), 1 - min(0.055, progress * 0.09))
    }
}



/// Allow the floating Metal lyric layers to retain extended values through
/// SwiftUI composition. Individual renderers still enforce the user's HDR
/// setting, live screen headroom and the 2x ceiling; SDR content stays SDR.
private struct LyricsPageDynamicRange: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.allowedDynamicRange(.high)
        } else {
            content
        }
    }
}

/// Keep the backdrop and lyric blend in one stable boundary at rest and during
/// zoom. This modifier must not branch on presentation: doing so rebuilds the
/// native canvas when switching modes. Live blur uses its own pixel inputs.
struct LyricsPageCompositing: ViewModifier {
    func body(content: Content) -> some View {
        content.compositingGroup()
    }
}
