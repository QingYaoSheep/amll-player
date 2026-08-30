import Foundation

struct PlaybackItem: Equatable, Sendable {
    let id: String?
    let uri: String
    let title: String
    let artists: [String]
    let albumTitle: String?
    let artworkURL: URL?
    let duration: TimeInterval
    let isEpisode: Bool
    let isAdvertisement: Bool

    var artistLine: String {
        artists.joined(separator: ", ")
    }
}

struct PlaybackDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let isActive: Bool
    let isRestricted: Bool
    let volumePercent: Int?
    let supportsVolume: Bool
}

struct PlaybackRestrictions: Equatable, Sendable {
    let canPause: Bool
    let canResume: Bool
    let canSeek: Bool
    let canSkipNext: Bool
    let canSkipPrevious: Bool

    static let unrestricted = PlaybackRestrictions(
        canPause: true,
        canResume: true,
        canSeek: true,
        canSkipNext: true,
        canSkipPrevious: true
    )
}

enum PlaybackSnapshotSource: String, Equatable, Sendable {
    case appRemote
    case webAPI
}

struct PlaybackSnapshot: Equatable, Sendable {
    let item: PlaybackItem?
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let device: PlaybackDevice?
    let restrictions: PlaybackRestrictions
    let source: PlaybackSnapshotSource
    let sampledAtUptime: TimeInterval

    static func empty(
        source: PlaybackSnapshotSource,
        sampledAtUptime: TimeInterval
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            item: nil,
            isPlaying: false,
            position: 0,
            duration: 0,
            device: nil,
            restrictions: .unrestricted,
            source: source,
            sampledAtUptime: sampledAtUptime
        )
    }
}
