import CoreGraphics

enum AMLLArtworkDisplayPolicy {
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
    static func frame(viewport: CGSize, video: CGSize) -> CGRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let source = video.width > 0 && video.height > 0 ? video : CGSize(width: 9, height: 16)
        let scale = min(viewport.width / source.width, viewport.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: (viewport.width - width) / 2, y: 0, width: width, height: height)
    }

    static func transitionFrame(video: CGRect, viewportHeight: CGFloat) -> CGRect {
        let extensionHeight = min(140, max(64, viewportHeight * 0.1))
        return CGRect(x: video.minX, y: video.maxY - video.height * 0.2,
                      width: video.width, height: video.height * 0.2 + extensionHeight)
    }
}
