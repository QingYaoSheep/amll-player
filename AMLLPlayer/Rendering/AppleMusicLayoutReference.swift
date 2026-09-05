import CoreGraphics
import Foundation

/// User-supplied Apple Music captures are the authority for spatial layout only.
/// AMLL remains the authority for lyric typography and motion.
struct AppleMusicLayoutReferenceManifest: Codable, Equatable, Sendable {
    struct Capture: Codable, Equatable, Sendable {
        enum State: String, Codable, Hashable, Sendable { case lyricsVisible, lyricsHidden }
        var filename: String
        var sha256: String
        var pixelWidth: Int
        var pixelHeight: Int
        var displayScale: Double
        var state: State
    }

    var schemaVersion: Int
    var device: String
    var operatingSystem: String
    var captures: [Capture]

    static let suppliedIPhone16Pro = Self(
        schemaVersion: 1,
        device: "iPhone 16 Pro",
        operatingSystem: "iOS 26 (exact build pending)",
        captures: [
            Capture(filename: "IMG_2679.PNG", sha256: "cd7d853049e2583540be36ba097a1a12eb454d2ed1863c2b9a5d801091d9c5c4",
                    pixelWidth: 1_206, pixelHeight: 2_622, displayScale: 3, state: .lyricsVisible),
            Capture(filename: "IMG_2680.PNG", sha256: "6faf6fe359983b4ce25b15c1c6c4f0d5c12b9b6db509745401d73b0d6e864720",
                    pixelWidth: 1_206, pixelHeight: 2_622, displayScale: 3, state: .lyricsHidden),
        ]
    )
}

struct AppleMusicLyricsLayoutMetrics: Equatable, Sendable {
    var canvas: CGSize
    var horizontalInset: CGFloat
    var handleTop: CGFloat
    var handleSize: CGSize
    var compactArtworkTop: CGFloat
    var compactArtworkSize: CGFloat
    var expandedArtworkTop: CGFloat
    var expandedArtworkInset: CGFloat
    var expandedMetadataGap: CGFloat
    var metadataToProgressGap: CGFloat
    var transportTopGap: CGFloat
    var volumeTopGap: CGFloat
    var bottomActionsTopGap: CGFloat

    /// First measured layout. Coordinates are in points after dividing the supplied 1206×2622 captures by 3.
    static let iPhone16Pro = Self(
        canvas: CGSize(width: 402, height: 874),
        horizontalInset: 32,
        handleTop: 69,
        handleSize: CGSize(width: 60, height: 4),
        compactArtworkTop: 95,
        compactArtworkSize: 72,
        expandedArtworkTop: 95,
        expandedArtworkInset: 24,
        expandedMetadataGap: 43,
        metadataToProgressGap: 31,
        transportTopGap: 42,
        volumeTopGap: 55,
        bottomActionsTopGap: 30
    )

    static func responsive(in size: CGSize) -> Self {
        let reference = Self.iPhone16Pro
        guard size.width > 0, size.height > 0 else { return reference }
        let widthScale = min(1.35, max(0.82, size.width / reference.canvas.width))
        var result = reference
        result.canvas = size
        result.horizontalInset = max(20, reference.horizontalInset * widthScale)
        result.compactArtworkSize = min(88, max(60, reference.compactArtworkSize * widthScale))
        result.expandedArtworkInset = max(20, reference.expandedArtworkInset * widthScale)
        return result
    }
}
