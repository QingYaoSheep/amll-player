import SwiftUI

struct ImmersiveLyricsHeader: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot
    let item: PlaybackItem
    let presentation: LyricsQuickSettingsPresentation
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var titleSize = 18.0
    @ScaledMetric(relativeTo: .subheadline) private var artistSize = 15.0

    var body: some View {
        let configuration = model.renderPreferences.configuration
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                if configuration.showTitle {
                    Text(item.title).font(.system(size: titleSize, weight: .bold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                }
                if configuration.showArtist {
                    Text(item.artistLine).font(.system(size: artistSize)).foregroundStyle(.white.opacity(0.65))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if configuration.showControls {
                Button { Task { await model.togglePlayPause() } } label: {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44)
                }
                .disabled(model.isPerformingAction || (snapshot.isPlaying ? !snapshot.restrictions.canPause : !snapshot.restrictions.canResume))
                .accessibilityLabel(Text(snapshot.isPlaying ? "player.pause" : "player.play"))
                .accessibilityIdentifier("immersiveLyricsPlayPause")
            }
            if model.selectedMusicService == .appleMusic { AppleMusicCurrentFavorite(model: model) }
            else if model.selectedMusicService == .netease { NetEaseCurrentFavorite(model: model) }
            LyricsQuickSettingsButton(presentation: presentation)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveLyricsInformation")
    }
}

struct ImmersiveInformationHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension ImmersiveArtworkMedia.Layout {
    static func lyrics(cover: CGRect, viewport: CGSize, configuration: LyricsRenderConfiguration,
                       tuning: ImmersiveArtworkDebugConfiguration, presentsFrame: Bool,
                       reduceTransparency: Bool, cornerRadius: CGFloat = 0, opacity: Double = 1) -> Self {
        let profile = ImmersiveBackgroundBlurProfile.extendingBackground(video: cover, viewport: viewport)
        return .init(video: cover, reflection: ArtworkReflectionGeometry.frame(cover: cover, viewportHeight: viewport.height),
            transition: profile.frame, bottomFade: AMLLImmersiveArtworkGeometry.bottomFadeFrame(video: cover, viewport: viewport),
            tuning: tuning.forImmersiveLyrics(), presentsFrame: presentsFrame,
            reflectionEnabled: configuration.animatedArtwork?.reflection == true,
            reduceTransparency: reduceTransparency, backgroundDimming: configuration.backgroundDimming ?? 0.16,
            cornerRadius: cornerRadius, pageOpacity: opacity, blurProfile: profile)
    }
}
