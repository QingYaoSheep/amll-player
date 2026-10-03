import CoreGraphics

enum AMLLArtworkDisplayPolicy {
    static func fadesImmersiveBottom(reflectionEnabled: Bool, reduceTransparency: Bool) -> Bool {
        !reflectionEnabled && !reduceTransparency
    }

    static func usesStaticLyricsCover(isPhone: Bool, showsLyrics: Bool) -> Bool {
        isPhone && showsLyrics
    }

    static func mountsImmersive(enabled: Bool, reduceMotion: Bool, staticLyricsCover: Bool,
                                selectedImmersive: Bool, portraitViewport: Bool,
                                kind: ArtworkAsset.Kind?, currentTrack: Bool, hasURL: Bool) -> Bool {
        enabled && !reduceMotion && !staticLyricsCover && selectedImmersive && portraitViewport
            && kind == .portraitVideo && currentTrack && hasURL
    }

    static func mountsSquare(enabled: Bool, reduceMotion: Bool, staticLyricsCover: Bool,
                             kind: ArtworkAsset.Kind?, currentTrack: Bool, hasURL: Bool) -> Bool {
        enabled && !reduceMotion && !staticLyricsCover && kind == .squareVideo && currentTrack && hasURL
    }
}

/// Keep the complete portrait frame visible in the page's background viewport.
enum AMLLImmersiveArtworkGeometry {
    static let overlapFraction: CGFloat = 0.34
    static let maximumBlur: CGFloat = 32
    /// Keep the shortened upper fade; the lower region now extends to the viewport edge.
    static let transitionTopInsetFraction: CGFloat = 0.15
    static func transitionFadeStops(solidStart: Double) -> [(location: Double, alpha: Double)] {
        (0 ... 32).map { sample in
            let t = Double(sample) / 32
            let ramp = min(1, t / max(0.001, solidStart))
            return (t, ramp * ramp * (3 - 2 * ramp))
        }
    }

    static let bottomFadeStops: [(location: Double, alpha: Double)] = (0 ... 32).map { sample in
        let t = Double(sample) / 32
        return (t, 1 - t * t * (3 - 2 * t))
    }

    /// The original video fade stays independent of the continuous background blur.
    static let videoFadeStops: [(location: Double, alpha: Double)] = [(0, 1)] + (0 ... 16).map { sample in
        let t = Double(sample) / 16
        return (1 - Double(overlapFraction) + t * Double(overlapFraction), 1 - t * t * (3 - 2 * t))
    }

    static func frame(viewport: CGSize, video: CGSize) -> CGRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let source = video.width > 0 && video.height > 0 ? video : CGSize(width: 9, height: 16)
        let scale = min(viewport.width / source.width, viewport.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: (viewport.width - width) / 2, y: 0, width: width, height: height)
    }

    /// Debug width/height resize the container, while the complete video remains aspect-fit.
    /// Reflection and blur must use the visible content rect, not its letterboxing.
    static func fittedFrame(container: CGRect, source: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, source.width > 0, source.height > 0 else { return .zero }
        let scale = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func transitionFrame(video: CGRect, viewportHeight: CGFloat? = nil) -> CGRect {
        let halfHeight = transitionHalfHeight(videoHeight: video.height)
        let top = video.maxY - halfHeight
        let bottom = max(video.maxY, viewportHeight ?? (video.maxY + halfHeight))
        return CGRect(x: video.minX, y: top, width: video.width, height: max(1, bottom - top))
    }

    static func bottomFadeFrame(video: CGRect, viewport: CGSize) -> CGRect {
        let top = video.maxY - transitionHalfHeight(videoHeight: video.height)
        return CGRect(x: 0, y: top, width: viewport.width, height: max(1, viewport.height - top))
    }

    static func transitionHalfHeight(videoHeight: CGFloat) -> CGFloat {
        videoHeight * overlapFraction * (1 - transitionTopInsetFraction)
    }
}

/// One continuous background blur region. Its lower area stays at full
/// strength; only the extension above the video/background junction ramps down.
struct ImmersiveBackgroundBlurProfile: Equatable, Sendable {
    let frame: CGRect
    let fullStrengthY: CGFloat

    static func extendingBackground(video: CGRect, viewport: CGSize,
                                    adjustment: ImmersiveArtworkLayerAdjustment = .init()) -> Self {
        guard viewport.width > 0, viewport.height > 0 else { return .init(frame: .zero, fullStrengthY: 0) }
        let adjustment = adjustment.validated()
        let junction = min(viewport.height, max(0, video.maxY))
        let extensionHeight = AMLLImmersiveArtworkGeometry.transitionHalfHeight(videoHeight: video.height) * adjustment.height
        let top = min(junction, max(0, junction - extensionHeight + adjustment.y))
        let width = viewport.width * adjustment.width
        return .init(frame: CGRect(x: (viewport.width - width) / 2 + adjustment.x, y: top,
                                  width: width, height: max(1, viewport.height - top)), fullStrengthY: junction)
    }

    func backgroundOnly(viewportHeight: CGFloat) -> Self {
        .init(frame: CGRect(x: frame.minX, y: 0, width: frame.width, height: max(1, viewportHeight)), fullStrengthY: 0)
    }

    func strength(at y: CGFloat) -> CGFloat {
        let end = min(frame.maxY, max(frame.minY, fullStrengthY))
        guard end > frame.minY else { return 1 }
        let t = min(1, max(0, (y - frame.minY) / (end - frame.minY)))
        return t * t * (3 - 2 * t)
    }
}
