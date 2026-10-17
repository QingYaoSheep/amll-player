import CoreGraphics

struct ImmersiveLyricsArtworkSource: Equatable {
    let trackID: String?
    let size: CGSize
    let isVideo: Bool

    static let placeholder = Self(trackID: nil, size: CGSize(width: 1, height: 1), isVideo: false)

    func forTrack(_ current: String?) -> Self { trackID == current ? self : .placeholder }
}

/// Layout only: no song time, playback state or lyric animation lives here.
struct ImmersiveLyricsLayout: Equatable {
    let cover: CGRect
    let information: CGRect
    let lyrics: CGRect
    let horizontalInset: CGFloat
    let contentHeight: CGFloat
    let requiresScrolling: Bool

    static func isEnabled(_ configuration: LyricsRenderConfiguration, isPhone: Bool, viewport: CGSize) -> Bool {
        configuration.immersiveLyrics == true && configuration.showLyrics && isPhone
            && viewport.width > 0 && viewport.height > viewport.width
    }

    static func resolve(viewport: CGSize, artwork: CGSize, informationHeight: CGFloat,
                        bottomInset: CGFloat, isVideo: Bool = false) -> Self {
        let width = max(1, viewport.width), height = max(1, viewport.height)
        let inset = min(44, max(20, width * 30 / 402))
        let infoHeight = informationHeight.isFinite ? max(44, informationHeight) : 64
        let safeBottom = bottomInset.isFinite ? max(0, bottomInset) : 0
        let minimumLyrics = max(160, height / 3)
        let availableCover = max(0, height - safeBottom - minimumLyrics - infoHeight - 40)
        let source = artwork.width.isFinite && artwork.height.isFinite && artwork.width > 0 && artwork.height > 0
            ? artwork : CGSize(width: 1, height: 1)
        // An exceptionally tall accessibility header can scroll with the lyric
        // viewport instead of reducing controls or the canvas to zero height.
        let maximumCoverHeight = max(80, availableCover)
        let cover: CGRect
        if isVideo {
            // Match the existing lyrics-hidden immersive page. Reserving lyric
            // space must not shrink a playing video into a narrow inset card.
            // An overflowing information/lyric region can scroll below it.
            cover = AMLLImmersiveArtworkGeometry.frame(viewport: CGSize(width: width, height: height), video: source)
        } else {
            let scale = min(width / source.width, maximumCoverHeight / source.height)
            cover = CGRect(x: (width - source.width * scale) / 2, y: 0,
                           width: source.width * scale, height: source.height * scale)
        }
        let information = CGRect(x: inset, y: cover.maxY + 16, width: max(1, width - inset * 2), height: infoHeight)
        let top = information.maxY + 24
        let lyrics = CGRect(x: 0, y: top, width: width, height: max(minimumLyrics, height - safeBottom - top))
        let contentHeight = lyrics.maxY + safeBottom
        return Self(cover: cover, information: information, lyrics: lyrics, horizontalInset: inset,
                    contentHeight: contentHeight, requiresScrolling: contentHeight > height + 0.5)
    }
}
