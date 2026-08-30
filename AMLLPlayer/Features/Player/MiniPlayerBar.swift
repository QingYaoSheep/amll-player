import SwiftUI

struct MiniPlayerBar: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 30, paused: !snapshot.isPlaying)
        ) { _ in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
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
                .padding(.horizontal, 10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
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
        Button(title, systemImage: systemImage) {
            Task { await action() }
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .frame(width: 34, height: 44)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
