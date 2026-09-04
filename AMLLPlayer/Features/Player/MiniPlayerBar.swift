import SwiftUI

struct MiniPlayerBar: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot
    var openPlayer: () -> Void = {}

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 30, paused: !snapshot.isPlaying)
        ) { _ in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: openPlayer) {
                        HStack(spacing: 8) {
                            artwork
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.item?.title ?? String(localized: "player.noPlayback"))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(snapshot.item?.artistLine ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("openNowPlaying")

                    controlButton(
                        title: "player.previous",
                        systemImage: "backward.fill",
                        disabled: model.isPerformingAction
                            || !snapshot.restrictions.canSkipPrevious
                    ) {
                        await model.skipPrevious()
                    }

                    controlButton(
                        title: snapshot.isPlaying ? "player.pause" : "player.play",
                        systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill",
                        disabled: model.isPerformingAction
                    ) {
                        await model.togglePlayPause()
                    }

                    controlButton(
                        title: "player.next",
                        systemImage: "forward.fill",
                        disabled: model.isPerformingAction
                            || !snapshot.restrictions.canSkipNext
                    ) {
                        await model.skipNext()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                GeometryReader { proxy in
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.primary.opacity(0.55))
                                .frame(width: proxy.size.width * CGFloat(progress))
                        }
                }
                .frame(height: 2)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
        }
        .modifier(MiniPlayerGlassSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayerBar")
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = snapshot.item?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            artworkPlaceholder
                .frame(width: 48, height: 48)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
    }

    private var progress: Double {
        guard snapshot.duration > 0 else {
            return 0
        }
        return min(max(model.progress() / snapshot.duration, 0), 1)
    }

    private func controlButton(
        title: LocalizedStringKey,
        systemImage: String,
        disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct MiniPlayerGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay { contrastBorder }
        } else if #available(iOS 26.0, *) {
            // One system glass surface; do not stack material or glass button backgrounds.
            content
                .glassEffect(.regular.interactive(!reduceMotion), in: shape)
                .overlay { contrastBorder }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { contrastBorder }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }

    @ViewBuilder
    private var contrastBorder: some View {
        if contrast == .increased {
            shape.strokeBorder(.primary.opacity(0.6), lineWidth: 1)
        }
    }
}
