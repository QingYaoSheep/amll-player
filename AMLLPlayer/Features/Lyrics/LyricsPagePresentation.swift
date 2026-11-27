import Observation
import QuartzCore
import SwiftUI

struct ImmersiveLyricsScrollEdge: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(active, for: .top)
        } else {
            content
        }
    }
}

/// Presentation state only. Never owns a document, song clock or seek request.
@MainActor @Observable
final class LyricsPagePresentationCoordinator {
    struct Mode: Equatable {
        var showsLyrics: Bool
        var immersive: Bool
    }

    private(set) var mode = Mode(showsLyrics: true, immersive: false)
    private(set) var rendersLyrics = true
    private(set) var rendersArtworkControls = false
    private(set) var revision = 0
    private var initialized = false

    init(showsLyrics: Bool = true) {
        mode.showsLyrics = showsLyrics
        rendersLyrics = showsLyrics
        rendersArtworkControls = !showsLyrics
    }

    func update(_ target: Mode, reduceMotion: Bool) {
        guard !initialized || mode != target else { return }
        let animate = initialized
        initialized = true
        let ticket = revision &+ 1
        withAnimation(animate ? LyricsPageMotion.content : nil, completionCriteria: .removed) {
            begin(target)
        } completion: { [weak self] in self?.finish(ticket) }
    }

    func begin(_ target: Mode) {
        revision &+= 1
        if target.showsLyrics { rendersLyrics = true }
        else { rendersArtworkControls = true }
        mode = target
    }

    func finish(_ ticket: Int) {
        guard ticket == revision else { return }
        rendersLyrics = mode.showsLyrics
        rendersArtworkControls = !mode.showsLyrics
    }
}

private struct LyricsPageControlsEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var lyricsPageControlsEnabled: Bool {
        get { self[LyricsPageControlsEnabledKey.self] }
        set { self[LyricsPageControlsEnabledKey.self] = newValue }
    }
}

struct LyricsPageControls<Content: View>: View {
    @Environment(\.lyricsPageControlsEnabled) private var enabled
    @ViewBuilder var content: () -> Content
    var body: some View { if enabled { content() } }
}

/// Apply to the actual control, since iOS 27 can expose a Button through an
/// otherwise hidden SwiftUI container while its sibling layout is retained.
struct LyricsPageControlVisibility: ViewModifier {
    @Environment(\.lyricsPageControlsEnabled) private var enabled
    func body(content: Content) -> some View {
        content.accessibilityHidden(!enabled).allowsHitTesting(enabled).disabled(!enabled)
    }
}

@MainActor enum LyricsPageMotion {
    static let contentDuration: TimeInterval = 0.2
    static let contentTimingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    // Same content-change curve as the existing product controls.
    static let content = Animation.timingCurve(0.23, 1, 0.32, 1, duration: contentDuration)
    // Reuse the product's interruptible spring. Large cover resizes felt abrupt
    // with the steep middle section of the former 240ms timing curve.
    static let geometry = LyricsQuickSettingsPresentation.motionAnimation
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
        content(item).opacity(outgoing == nil ? 1 : 1 - outgoingOpacity)
        .overlay(alignment: .leading) {
            if let outgoing {
                content(outgoing)
                    .environment(\.lyricsPageControlsEnabled, false)
                    .opacity(outgoingOpacity)
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .id(revision)
                    .onAppear {
                        let ticket = revision
                        withAnimation(LyricsPageMotion.content, completionCriteria: .removed) {
                            outgoingOpacity = 0
                        } completion: {
                            if revision == ticket { self.outgoing = nil }
                        }
                    }
            }
        }
        .onChange(of: item.uri, initial: true) { _, _ in
            revision &+= 1
            outgoing = current
            current = item
            outgoingOpacity = outgoing == nil ? 0 : 1
        }
        .onChange(of: item) { old, new in if old.uri == new.uri { current = new } }
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

struct LyricsPageControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    func lyricsArtworkFrame(enabled: Bool = true) -> some View {
        background { GeometryReader { proxy in
            Color.clear.preference(key: LyricsArtworkFrameKey.self,
                value: enabled ? proxy.frame(in: .named("lyricsPage")) : nil)
        } }
    }
}
