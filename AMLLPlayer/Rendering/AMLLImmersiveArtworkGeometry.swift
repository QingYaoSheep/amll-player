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
    /// Shorten the fade region from its top only; keep the video bottom fixed.
    static let transitionTopInsetFraction: CGFloat = 0.15

    /// The blur overlay is strongest at the bottom and fades out towards its top.
    static let transitionFadeStops: [(location: Double, alpha: Double)] = (0 ... 16).map { sample in
        let t = Double(sample) / 16
        return (t, t * t * (3 - 2 * t))
    }

    /// Keep the video's downward fade independent of the overlay's upward fade.
    static let videoFadeStops: [(location: Double, alpha: Double)] = [(0, 1)] + transitionFadeStops.map {
        (1 - Double(overlapFraction) + $0.location * Double(overlapFraction), 1 - $0.alpha)
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
        let height = video.height * overlapFraction * (1 - transitionTopInsetFraction)
        return CGRect(x: video.minX, y: video.maxY - height, width: video.width, height: height)
    }
}
