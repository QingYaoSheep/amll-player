import SwiftUI

/// Compatibility-page adapter. It reuses the same loader, layout, frame hub and
/// media surfaces without replacing that page's existing lyric renderer.
struct ImmersiveLyricsArtworkBackdrop: View {
    @Bindable var model: AppModel
    let item: PlaybackItem
    let layout: ImmersiveLyricsLayout
    let viewport: CGSize
    let active: Bool
    let artworkSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var loader = AnimatedArtworkLoader()
    @State private var still = ImmersiveStillArtwork()
    @State private var frames = ArtworkReflectionFrames()
    @State private var network = ArtworkNetworkPolicy.shared
    @State private var debug = ImmersiveArtworkDebugStore.shared
    private var configuration: LyricsRenderConfiguration { model.renderPreferences.configuration.validated() }
    private var hasVideo: Bool {
        configuration.animatedArtwork?.enabled == true && !reduceMotion
            && network.permits(allowCellular: configuration.animatedArtwork?.allowCellular ?? false)
            && loader.trackID == item.uri && loader.playbackURL != nil
    }
    private var displayedSize: CGSize {
        if hasVideo, loader.hasPresentedFrame, let size = loader.videoSize { return size }
        return still.frame(for: item.artworkURL)?.size ?? CGSize(width: 1, height: 1)
    }
    private var requestKey: String {
        [item.uri, String(configuration.animatedArtwork?.enabled == true), String(reduceMotion),
         String(configuration.animatedArtwork?.allowCellular == true),
         String(network.permits(allowCellular: configuration.animatedArtwork?.allowCellular ?? false)),
         model.lyrics.selection.candidate?.id ?? "", model.lyrics.settings.storefront, model.lyrics.settings.language].joined(separator: "|")
    }
    var body: some View {
        ImmersiveArtworkMedia(video: video, frames: frames,
            layout: .lyrics(cover: layout.cover, viewport: viewport, configuration: configuration,
                tuning: debug.configuration, presentsFrame: hasVideo && loader.hasPresentedFrame,
                reduceTransparency: reduceTransparency),
            background: AMLLBackground(artworkURL: item.artworkURL, active: active,
                blur: configuration.backgroundBlur, mode: configuration.backgroundMode ?? .mesh,
                color: configuration.backgroundColor ?? .sourceDefault,
                gradientEnd: configuration.backgroundGradientEnd ?? .sourceDefault,
                flowing: configuration.flowingBackground ?? .init(), dimming: 0),
            still: still.frame(for: item.artworkURL))
            .id(loader.requestToken)
            .onChange(of: displayedSize, initial: true) { _, size in artworkSize(size) }
            .task(id: item.uri + "|" + (item.artworkURL?.absoluteString ?? "")) { await still.load(item.artworkURL) }
            .task(id: requestKey) {
                let settings = configuration.animatedArtwork ?? .init()
                guard settings.enabled, !reduceMotion, network.permits(allowCellular: settings.allowCellular) else { loader.reset(); return }
                await loader.loadForLyrics(item: item, coordinator: model.lyrics, settings: settings, prefersPortrait: true)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private var video: AnimatedArtwork? {
        guard hasVideo, let url = loader.playbackURL else { return nil }
        let token = loader.requestToken
        return AnimatedArtwork(url: url, active: active && model.playbackSnapshot?.isPlaying == true,
            allowCellular: configuration.animatedArtwork?.allowCellular ?? false, reflectionFrames: frames,
            onFailure: { url, error in loader.playbackFailed(trackID: item.uri, url: url, error: error, token: token) },
            onState: { url, state in loader.playbackChanged(token: token, url: url, state: state) },
            onFirstFrame: { url, size in loader.firstFramePresented(token: token, url: url, size: size) },
            gravity: .resizeAspect, fadesBottom: false)
    }
}

extension AnimatedArtworkLoader {
    @MainActor func loadForLyrics(item: PlaybackItem, coordinator: LyricsCoordinator,
                                  settings: AnimatedArtworkConfiguration, prefersPortrait: Bool) async {
        guard let track = TrackIdentity(item), let provider = coordinator.apple else { reset(); return }
        let candidate = coordinator.selection.candidate
        let lyricsSettings = coordinator.settings
        await load(trackID: item.uri, kind: prefersPortrait ? .portraitVideo : .squareVideo,
            fallbackKind: prefersPortrait ? .squareVideo : nil, streamWhileDownloading: true, assets: {
                let songID: String
                if let candidate, candidate.source == .apple { songID = candidate.sourceID }
                else {
                    let matches = try await provider.search(track: track, query: "", settings: lyricsSettings)
                    guard let match = matches.first(where: { $0.score >= 70 }) else { return [] }
                    songID = match.sourceID
                }
                try Task.checkCancellation()
                return try await provider.animatedArtwork(songID: songID, settings: lyricsSettings)
            }, download: { url in
                try await ArtworkMediaDownload.download(url, allowCellular: settings.allowCellular)
            })
    }
}
