import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct LockScreenLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockScreenLyricsAttributes.self) { context in
            LockScreenLyricsCard(state: context.state, stale: context.isStale)
                .widgetURL(LockScreenLyricsAttributes.playerURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { lyricsIcon }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.current?.text ?? context.state.next?.text ?? context.state.title)
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                lyricsIcon
            } compactTrailing: {
                if context.state.status == .paused {
                    Image(systemName: "pause.fill")
                        .accessibilityLabel(Text("lockScreenLyrics.paused"))
                }
            } minimal: {
                lyricsIcon
            }
            .widgetURL(LockScreenLyricsAttributes.playerURL)
        }
    }

    private var lyricsIcon: some View {
        Image(systemName: "music.note.list")
            .accessibilityLabel(Text("lockScreenLyrics.title"))
    }
}

private struct LockScreenLyricsCard: View {
    typealias State = LockScreenLyricsAttributes.ContentState
    var state: State
    var stale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    var body: some View {
        if #available(iOS 26, *) {
            content.activityBackgroundTint(nil)
        } else {
            content
                .foregroundStyle(.white)
                .background { legacyBackdrop }
                .activityBackgroundTint(Color(white: 0.10))
                .activitySystemActionForegroundColor(.white)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .accessibilityHidden(true)
                Text(state.title)
                    .lineLimit(1)
                    .contentTransition(.identity)
                if let status {
                    Spacer(minLength: 8)
                    Text(status).lineLimit(1)
                }
            }
            .font(.caption.weight(.semibold))
            .opacity(0.75)

            if state.status != .loading {
                ViewThatFits(in: .vertical) {
                    lyrics(state.rows)
                    lyrics([state.current, state.next].compactMap { $0 })
                    lyrics([state.current ?? state.next].compactMap { $0 }, currentLineLimit: 1)
                }
                .id(state.track)
                .frame(maxHeight: .infinity, alignment: .center)
                .clipped()
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .frame(height: 134)
    }

    private var status: LocalizedStringKey? {
        if stale || state.status == .outOfSync { return "lockScreenLyrics.outOfSync" }
        switch state.status {
        case .paused: return "lockScreenLyrics.paused"
        case .loading: return "lockScreenLyrics.loading"
        case .playing, .outOfSync: return nil
        }
    }

    private func lyrics(_ rows: [LockScreenLyricsAttributes.Row], currentLineLimit: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                let focused = row.id == state.current?.id
                Text(row.text)
                    .font(focused ? .title3.weight(.bold) : .subheadline.weight(.medium))
                    .lineLimit(focused ? currentLineLimit : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(focused ? 1 : 0.66)
                    .contentTransition(.identity)
                    .accessibilityAddTraits(focused ? .isSelected : [])
                    .transition(rowTransition)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(animation, value: rows)
    }

    private var animation: Animation? {
        guard !luminanceReduced, state.scrollsForward else { return nil }
        return .easeInOut(duration: reduceMotion ? 0.16 : 0.24)
    }

    private var rowTransition: AnyTransition {
        guard !luminanceReduced, state.scrollsForward else { return .identity }
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                           removal: .move(edge: .top).combined(with: .opacity))
    }

    private var legacyBackdrop: some View {
        GeometryReader { geometry in
            if !reduceTransparency, !luminanceReduced, let bytes = state.backdrop, let image = UIImage(data: bytes) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(Color.black.opacity(0.20))
                    .accessibilityHidden(true)
            }
        }
    }
}
