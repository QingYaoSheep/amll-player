import SwiftUI

/// Real-page adapter for the native AMLL lyric canvas.
///
/// The adapter owns no playback implementation. It only projects the
/// existing AppModel snapshot, lyric document and Spotify control callbacks
/// into the renderer's deterministic input contract.
struct AMLLLyricsDisplay: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot
    let configuration: LyricsRenderConfiguration
    let active: Bool
    let resumeToken: Int
    var browsing: (Bool) -> Void = { _ in }

    private var document: LyricsDocument? {
        model.lyrics.document
    }

    var body: some View {
        if let document, !document.lines.isEmpty {
            AMLLNativeLyricsView(
                document: document,
                configuration: configuration,
                input: input(for: document),
                position: { model.progress() },
                interaction: { interaction in handle(interaction, document: document) },
                canSeek: snapshot.restrictions.canSeek && !model.isPerformingAction,
                active: active,
                targetFPS: 120,
                resumeToken: resumeToken,
                browsing: browsing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("amllNativeLyricsDisplay")
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private func input(for document: LyricsDocument) -> AMLLPlayerInput {
        AMLLPlayerInput(
            position: model.progress(),
            offset: model.lyrics.selection.offset,
            playing: snapshot.isPlaying,
            seekRevision: model.lyricsSeekRevision,
            seeking: false,
            document: document,
            playbackSnapshot: snapshot,
            artworkURL: snapshot.item?.artworkURL,
            configuration: configuration,
            event: .snapshot
        )
    }

    private func handle(_ interaction: AMLLInteraction, document: LyricsDocument) {
        switch interaction {
        case let .seek(lineID):
            guard snapshot.restrictions.canSeek, !model.isPerformingAction,
                  let line = document.lines.first(where: { $0.id == lineID }) else { return }
            let target = LyricsTimeline.seekTarget(line: line, offset: model.lyrics.selection.offset,
                                                   duration: snapshot.duration)
            Task { await model.seek(to: target) }
        case .resumeFollowing:
            browsing(false)
        default:
            break
        }
    }
}
