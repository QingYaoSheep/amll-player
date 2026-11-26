import Foundation

/// Window-local layout for the ordinary iPad player. The density and control
/// scales are independent in the small horizontal window.
struct TabletLyricsLayout: Equatable {
    enum Mode: Equatable { case wide, narrow, mini }

    let mode: Mode
    let cover: CGRect
    let metadata: CGRect
    let progress: CGRect
    let transportCenter: CGPoint
    let transportWidth: CGFloat
    let transportSpacing: CGFloat
    let buttonSize: CGFloat
    let glyphSize: CGFloat
    let volume: CGRect?
    let lyrics: CGRect
    let typography: TabletLyricTypography
    let scale: CGFloat

    init(size: CGSize, showsLyrics: Bool, showsControls: Bool = true,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0, actionHeight: CGFloat = 44)
    {
        let w = max(1, size.width), h = max(1, size.height)
        let horizontal = w / h >= 1.30
        mode = horizontal && w <= 720 && h <= 400 ? .mini : horizontal ? .wide : .narrow
        let d = switch mode {
        case .wide: min(w / 1376, h / 1030)
        case .narrow: max(0.75, min(w / 626, h / 1382))
        case .mini: max(0.5, min(w / 1376, h / 1030))
        }
        let s = mode == .mini ? 1.7 * d : d
        scale = s
        let footer = max(0, h - bottomInset - actionHeight - 4)
        let metadataHeight = max(46, 52 * s)
        let usableTop = max(0, topInset)
        let anchor: CGFloat
        let fadeTop: CGFloat
        let fadeTopWidth: CGFloat
        let fadeBottom: CGFloat
        let fadeBottomWidth: CGFloat

        switch mode {
        case .wide:
            let column = 0.55 * h
            let x = showsLyrics ? 0.04 * w : (w - column) / 2
            let y = max(usableTop, 0.10 * h)
            let side = max(1, min(column, 0.85 * h - 314.45 * s - (y - 0.10 * h)))
            cover = CGRect(x: x + (column - side) / 2, y: y, width: side, height: side)
            let lowerY = y + side + 0.05 * h
            let lowerHeight = max(0, h - lowerY - 85 * s)
            metadata = CGRect(x: x, y: lowerY, width: column, height: metadataHeight)
            progress = CGRect(x: x, y: lowerY + 20 + 45 * s, width: column, height: 20 * s)
            buttonSize = max(44, 68 * s)
            transportWidth = column
            transportSpacing = 95 * s
            transportCenter = CGPoint(x: x + column / 2, y: lowerY + lowerHeight / 2 + 24 * s)
            glyphSize = 36 * s
            volume = CGRect(x: x, y: lowerY + lowerHeight - 40 * s, width: column, height: 20 * s)
            let left = max(0, w / 2 - 18)
            let availableHeight = max(1, h - bottomInset)
            lyrics = CGRect(x: left, y: 0, width: max(1, 0.96 * w - left), height: availableHeight)
            anchor = cover.midY + 1.25 * 48 * d
            fadeTop = max(usableTop, 60 * d)
            fadeTopWidth = 50 * d
            fadeBottom = min(availableHeight, h - 70 * d)
            fadeBottomWidth = 100 * d

        case .narrow:
            let margin = min(w * 0.25, max(0.08 * w, 40))
            let smallSide = min(max(0.1 * w, 80), w * 0.4)
            let controlsTop = max(0, min(h * 0.7, footer - 125))
            let collapsedTop = max(usableTop, h * 0.15)
            let largeSide = max(1, min(w * 0.8, h * 0.5 - margin * s, max(1, controlsTop - collapsedTop - metadataHeight - 16)))
            let side = showsLyrics ? smallSide : largeSide
            let headerTop = max(usableTop, 80)
            cover = CGRect(x: showsLyrics ? margin : (w - side) / 2,
                           y: showsLyrics ? headerTop : collapsedTop, width: side, height: side)
            let labelX = showsLyrics ? cover.maxX + 20 : w * 0.1
            let labelY = showsLyrics ? cover.midY - metadataHeight / 2 : cover.maxY + 8
            metadata = CGRect(x: labelX, y: labelY, width: max(1, w - labelX - margin), height: metadataHeight)
            progress = CGRect(x: 0.1 * w, y: controlsTop, width: 0.8 * w, height: 23 * s)
            transportWidth = 0.8 * w
            transportSpacing = 138 * s
            let centerY = min(footer - 22, controlsTop + h * 0.15 - 4.65 * s)
            buttonSize = min(max(44, 89.7 * s), max(44, 2 * (footer - centerY)))
            transportCenter = CGPoint(x: w / 2, y: centerY)
            glyphSize = 48.3 * s
            volume = nil
            let ly = headerTop + smallSide
            let bottom = showsControls ? controlsTop : footer
            lyrics = CGRect(x: margin, y: ly, width: max(1, w - 2 * margin), height: max(1, bottom - ly))
            anchor = 140 * d
            fadeTop = 0
            fadeTopWidth = 100
            fadeBottom = lyrics.height
            fadeBottomWidth = 150

        case .mini:
            let margin = max(56 * s + 10 + 8 * d, 65 * d)
            let side = max(1, min(w / 2 - 48 * d, h - 2 * margin) / 1.03)
            cover = CGRect(x: w / 4 - side / 2, y: (h - side) / 2, width: side, height: side)
            let left = w / 2 + 18
            let width = max(1, min(w / 2 - 72 * d, w - left - 12))
            let progressHeight = max(30, 20 * s)
            let seekY = min(h / 2 - progressHeight / 2 + 34 * s, max(usableTop, footer - 104))
            progress = CGRect(x: left, y: seekY, width: width, height: progressHeight)
            metadata = CGRect(x: left, y: max(usableTop, min(h / 2 - 10 * d - 60 * s, seekY - metadataHeight - 8)),
                              width: width, height: metadataHeight)
            transportWidth = width
            transportSpacing = 95 * s
            buttonSize = max(44, 48 * s)
            transportCenter = CGPoint(x: left + width / 2, y: min(footer - buttonSize / 2, seekY + progressHeight + 30 + 24 * s))
            glyphSize = 32 * s
            volume = nil
            lyrics = CGRect(x: left, y: 0, width: width, height: max(1, h - bottomInset))
            anchor = h / 2
            fadeTop = max(usableTop, 23 * s + 32)
            fadeTopWidth = 60 * s
            fadeBottom = min(lyrics.height, h - 70 * d)
            fadeBottomWidth = 100 * d
        }

        let height = lyrics.height
        let bottom = min(height, max(1, fadeBottom))
        let top = min(bottom * 0.25, fadeTop)
        let full = max(top, bottom - min(bottom * 0.4, fadeBottomWidth))
        typography = TabletLyricTypography(density: d, mini: mode == .mini,
            anchor: min(0.85, max(0.15, anchor / height)), centersFocus: mode != .narrow,
            fade: [top, min(full, top + fadeTopWidth), full, bottom].map { Double($0 / height) })
    }
}

struct TabletLyricTypography: Codable, Equatable, Sendable {
    let density: Double
    let mini: Bool
    let anchor: Double
    let centersFocus: Bool
    let fade: [Double]

    var primarySize: Double { 48 * density * (mini ? 1.25 : 1) }
    var visualLineLeading: Double { 10 * density }
    var paragraphGap: Double { 40 * density }

    static func maximumBlur(level: Int?) -> Double {
        6 * LyricsAnimationBlur.maximum(LyricsAnimationBlur.level(level, isPad: true)) / LyricsAnimationBlur.maximum(3)
    }

    static func blur(distance: Int, maximum: Double) -> Double {
        guard distance != 0 else { return 0 }
        let effectiveDistance = abs(distance) + (distance < 0 ? 2 : 1)
        return min(6, 1.25 * (Double(effectiveDistance) - 0.25)) * maximum / 6
    }

    func focusOffset(contentHeight: Double) -> Double { centersFocus ? contentHeight / 2 : 0 }

    func configuration(_ current: LyricsRenderConfiguration, in viewport: CGSize) -> LyricsRenderConfiguration {
        var value = current
        value.immersiveLyrics = false
        value.tabletTypography = self
        value.anchor = min(0.92, max(0.08, anchor + current.anchor - LyricsRenderConfiguration().anchor))
        value.fontSize = max(10, primarySize + current.resolvedFontSize(width: viewport.width, height: viewport.height) - 32)
        value.sizePreset = nil
        value.auxiliaryScale = min(1, max(0.3, 0.55 + (current.auxiliaryScale ?? 0.5) - 0.5))
        return value
    }

    func inset(width: CGFloat, duet: Bool, background: Bool, custom: Double?) -> CGFloat {
        let ratio = duet ? 0.80 : 0.95
        let visibleWidth = width * ratio
        let available = max(1, visibleWidth - 2 * (custom.map { $0 - 20 } ?? 0))
        let localWidth = background ? available / 0.7 : available
        return (width - localWidth) / 2
    }
}
