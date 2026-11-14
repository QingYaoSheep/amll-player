import Observation
import SwiftUI
import CoreImage
import QuartzCore

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

    init(showsLyrics: Bool = true) {
        mode.showsLyrics = showsLyrics
        rendersLyrics = showsLyrics
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
        mode = target
    }

    func finish(_ ticket: Int) {
        guard ticket == revision else { return }
        rendersLyrics = mode.showsLyrics
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

@MainActor enum LyricsPageMotion {
    static let contentDuration: TimeInterval = 0.2
    static let contentTimingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    // Same content-change curve as the existing product controls.
    static let content = Animation.timingCurve(0.23, 1, 0.32, 1, duration: contentDuration)
    static let geometry = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
    static let returnSpring = LyricsQuickSettingsPresentation.motionAnimation
}

/// Retained decoder pixels are immutable. Conversion is performed once per
/// resource transition, away from the UI thread; never on a display tick.
struct LyricsArtworkSnapshot: @unchecked Sendable {
    struct Layer {
        let buffer: CVPixelBuffer
        let frame: CGRect
        let opacity: CGFloat
        let fits: Bool
    }
    let size: CGSize
    let scale: CGFloat
    let layers: [Layer]
}

actor LyricsArtworkSnapshotDecoder {
    static let shared = LyricsArtworkSnapshotDecoder()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func decode(_ input: LyricsArtworkSnapshot) -> ImmersiveStillFrame? {
        guard !Task.isCancelled else { return nil }
        guard input.size.width > 0, input.size.height > 0, !input.layers.isEmpty else { return nil }
        let scale = min(input.scale, 1600 / max(input.size.width, input.size.height))
        let extent = CGRect(x: 0, y: 0, width: max(1, ceil(input.size.width * scale)), height: max(1, ceil(input.size.height * scale)))
        var composite = CIImage(color: .clear).cropped(to: extent)
        for layer in input.layers {
            let source = ArtworkReflectionImage.decodedVideoSource(layer.buffer)
            let rect = CGRect(x: layer.frame.minX * scale, y: (input.size.height - layer.frame.maxY) * scale,
                width: layer.frame.width * scale, height: layer.frame.height * scale)
            guard rect.width > 0, rect.height > 0 else { continue }
            let factor = layer.fits ? min(rect.width / source.extent.width, rect.height / source.extent.height)
                : max(rect.width / source.extent.width, rect.height / source.extent.height)
            let image = source.transformed(by: .init(translationX: -source.extent.minX, y: -source.extent.minY))
                .transformed(by: .init(scaleX: factor, y: factor))
                .transformed(by: .init(translationX: rect.midX - source.extent.width * factor / 2,
                    y: rect.midY - source.extent.height * factor / 2))
                .cropped(to: rect)
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity)])
            composite = image.composited(over: composite)
        }
        guard !Task.isCancelled else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var storage: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(extent.width), Int(extent.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage) == kCVReturnSuccess,
            let buffer = storage, let image = context.createCGImage(composite, from: extent, format: .RGBA8, colorSpace: space) else { return nil }
        context.render(composite, to: buffer, bounds: extent, colorSpace: space)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        return ImmersiveStillFrame(image: image, buffer: buffer)
    }
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
        ZStack(alignment: .leading) {
            content(item).opacity(outgoing == nil ? 1 : 1 - outgoingOpacity)
            if let outgoing {
                content(outgoing)
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

extension View {
    func lyricsArtworkFrame(enabled: Bool = true) -> some View {
        background { GeometryReader { proxy in
            Color.clear.preference(key: LyricsArtworkFrameKey.self,
                value: enabled ? proxy.frame(in: .named("lyricsPage")) : nil)
        } }
    }
}
