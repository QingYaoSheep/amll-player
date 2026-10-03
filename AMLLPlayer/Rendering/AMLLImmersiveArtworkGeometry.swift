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
    /// Keep the shortened upper region and extend an equal distance below the video.
    static let transitionTopInsetFraction: CGFloat = 0.15
    static let transitionPeakStart: Double = 0.4375
    static let transitionPeakEnd: Double = 0.5625

    /// A small opaque center covers the video edge; both outer ends fade smoothly.
    static let transitionFadeStops: [(location: Double, alpha: Double)] = (0 ... 32).map { sample in
        let t = Double(sample) / 32
        let ramp = min(1, min(t / transitionPeakStart, (1 - t) / (1 - transitionPeakEnd)))
        return (t, ramp * ramp * (3 - 2 * ramp))
    }

    /// The original video fade stays independent of the two-sided blur overlay.
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

    static func transitionFrame(video: CGRect) -> CGRect {
        let halfHeight = transitionHalfHeight(videoHeight: video.height)
        return CGRect(x: video.minX, y: video.maxY - halfHeight, width: video.width, height: halfHeight * 2)
    }

    static func transitionHalfHeight(videoHeight: CGFloat) -> CGFloat {
        videoHeight * overlapFraction * (1 - transitionTopInsetFraction)
    }
}
