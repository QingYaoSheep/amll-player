import SwiftUI

struct ImmersiveLyricsHeaderAppearance: Equatable, Sendable {
    let usesPlusLighter: Bool
    let usesHDR: Bool
    let hdrBrightness: Double

    static func resolve(overlaysArtwork: Bool,
                        hdrEnabled: Bool,
                        reduceTransparency: Bool) -> Self {
        let additive = overlaysArtwork && !reduceTransparency
        let hdr = additive && hdrEnabled
        return Self(
            usesPlusLighter: additive,
            usesHDR: hdr,
            hdrBrightness: hdr ? LyricsHDRConfiguration.targetBrightness : 1.0
        )
    }
}

private struct ImmersiveHeaderDynamicRange: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), enabled {
            content.allowedDynamicRange(.high)
        } else {
            content
        }
    }
}

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

    private static func foregroundColor(opacity: Double, appearance: ImmersiveLyricsHeaderAppearance) -> Color {
        if #available(iOS 26.0, *), appearance.usesHDR {
            let brightness = appearance.hdrBrightness
            return Color(.sRGBLinear, red: brightness, green: brightness, blue: brightness, opacity: opacity)
                .headroom(brightness)
        }
        return Color.white.opacity(opacity)
    }

    var body: some View {
        let configuration = model.renderPreferences.configuration
        let appearance = ImmersiveLyricsHeaderAppearance.resolve(
            overlaysArtwork: additive,
            hdrEnabled: configuration.hdr?.enabled == true,
            reduceTransparency: reduceTransparency
        )
        let primaryColor = Self.foregroundColor(opacity: 1, appearance: appearance)
        let secondaryColor = Self.foregroundColor(opacity: 0.65, appearance: appearance)
        HStack(alignment: .center, spacing: 4) {
            LyricsTrackTransition(item: item) { displayed in
              VStack(alignment: .leading, spacing: 3) {
                if configuration.showTitle {
                    Text(displayed.title).font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                }
                if configuration.showArtist {
                    Text(displayed.artistLine).font(.system(size: artistSize))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .trackSwipeToSkip(
                enabled: configuration.showControls && !model.isPerformingAction,
                canSkipNext: snapshot.restrictions.canSkipNext,
                canSkipPrevious: snapshot.restrictions.canSkipPrevious,
                onSkipNext: { Task { await model.skipNext() } },
                onSkipPrevious: { Task { await model.skipPrevious() } }
            )
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ImmersiveInformationTextBottomKey.self,
                        value: proxy.frame(in: .named("immersiveLyricsHeader")).maxY)
                }
            }
            LyricsPageControls {
            if configuration.showControls {
                Button { Task { await model.togglePlayPause() } } label: {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44)
                        .modifier(PlayPauseSymbolTransition())
                        .contentShape(Rectangle())
                }
                .disabled(model.isPerformingAction || (snapshot.isPlaying ? !snapshot.restrictions.canPause : !snapshot.restrictions.canResume))
                .accessibilityLabel(Text(snapshot.isPlaying ? "player.pause" : "player.play"))
                .accessibilityIdentifier("immersiveLyricsPlayPause")
            }
            if model.selectedMusicService == .appleMusic { AppleMusicCurrentFavorite(model: model) }
            else if model.selectedMusicService == .netease { NetEaseCurrentFavorite(model: model) }
            LyricsQuickSettingsButton(presentation: presentation)
            }
        }
        .foregroundStyle(primaryColor)
        .tint(primaryColor)
        .buttonStyle(MusicContentButtonStyle())
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: "immersiveLyricsHeader")
        .blendMode(appearance.usesPlusLighter ? .plusLighter : .normal)
        .modifier(ImmersiveHeaderDynamicRange(enabled: appearance.usesHDR))
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
