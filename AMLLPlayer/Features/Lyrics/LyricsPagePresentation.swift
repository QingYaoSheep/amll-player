import Observation
import SwiftUI

/// Presentation state only. Never owns a document, song clock or seek request.
@MainActor @Observable
final class LyricsPagePresentationCoordinator {
    struct Mode: Equatable {
        var showsLyrics: Bool
        var immersive: Bool
    }

    private(set) var mode = Mode(showsLyrics: true, immersive: false)
    private(set) var rendersLyrics = true
    private(set) var revision = 0
    private var initialized = false

    func update(_ target: Mode, reduceMotion: Bool) {
        guard !initialized || mode != target else { return }
        let animate = initialized
        initialized = true
        revision &+= 1
        let ticket = revision
        if target.showsLyrics { rendersLyrics = true }
        withAnimation(animate ? LyricsPageMotion.content : nil, completionCriteria: .removed) {
            mode = target
        } completion: { [weak self] in self?.finish(ticket) }
    }

    func finish(_ ticket: Int) {
        guard ticket == revision else { return }
        rendersLyrics = mode.showsLyrics
    }
}

enum LyricsPageMotion {
    // Same content-change curve as the existing product controls.
    static let content = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    static let geometry = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
    static let returnSpring = LyricsQuickSettingsPresentation.motionAnimation
}

/// Only cover/metadata content belongs here; never wrap the lyric canvas.
/// Explicitly bounded to the current item and one outgoing item.
struct LyricsTrackTransition<Content: View>: View {
    let item: PlaybackItem
    @ViewBuilder var content: (PlaybackItem) -> Content
    @State private var current: PlaybackItem?
    @State private var outgoing: PlaybackItem?
    @State private var outgoingOpacity = 0.0
    @State private var revision = 0

    var body: some View {
        ZStack {
            content(item)
            if let outgoing {
                content(outgoing)
                    .opacity(outgoingOpacity)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onChange(of: item.uri, initial: true) { _, _ in
            revision &+= 1
            let ticket = revision
            outgoing = current
            current = item
            guard outgoing != nil else { return }
            outgoingOpacity = 1
            withAnimation(LyricsPageMotion.content, completionCriteria: .removed) {
                outgoingOpacity = 0
            } completion: {
                if revision == ticket { outgoing = nil }
            }
        }
    }
}

/// Freeze the native viewport at its destination size. Only the surrounding
/// placement moves, so a transition cannot cause 30 fresh Core Text layouts.
struct LyricsPageViewport<Content: View>: View {
    let rect: CGRect
    var reduceMotion = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: rect.width, height: rect.height)
            .transaction { $0.animation = nil }
            .offset(x: rect.minX, y: rect.minY)
            .animation(reduceMotion ? nil : LyricsPageMotion.geometry, value: rect.origin)
    }
}

struct LyricsArtworkFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    func lyricsArtworkFrame(enabled: Bool = true) -> some View {
        background { GeometryReader { proxy in
            Color.clear.preference(key: LyricsArtworkFrameKey.self,
                value: enabled ? proxy.frame(in: .named("lyricsPage")) : nil)
        } }
    }
}
