import SwiftUI

struct ImmersiveLyricsHeader: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot
    let item: PlaybackItem
    let presentation: LyricsQuickSettingsPresentation
    var additive = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ImmersiveInformationTextBottomKey.self,
                        value: proxy.frame(in: .named("immersiveLyricsHeader")).maxY)
                }
            }
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
        .coordinateSpace(name: "immersiveLyricsHeader")
        .blendMode(additive && !reduceTransparency ? .plusLighter : .normal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveLyricsInformation")
    }
}

struct ImmersiveInformationTextBottomKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue(), next.isFinite { value = next }
    }
}

struct ImmersiveInformationHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
