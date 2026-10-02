import Foundation

/// Audio targets use real media seconds. Visual advance is deliberately absent.
enum PlaybackSeekEntry: String, Codable, Sendable { case lyric, progress, remote, restore, unspecified }

struct PlaybackSeekRequest: Equatable, Sendable {
    let id: UUID
    let service: MusicServiceID
    let sourceGeneration: UUID
    let trackURI: String
    let target: Double
    let entry: PlaybackSeekEntry
    let requestedAt: Double
    var lyricTime: Double?
    var offset: Double?
}

struct PlaybackSeekConfirmation: Equatable, Sendable {
    let requestID: UUID
    let sourceGeneration: UUID
    let resourceGeneration: UUID
    let trackURI: String
    let target: Double
    let position: Double
    let sampledAt: Double
}

struct PlaybackSeekResult: Sendable {
    let confirmation: PlaybackSeekConfirmation
    let snapshot: PlaybackSnapshot
}

/// Sampled once on the main actor by each display frame, including the first frame.
struct LyricsPlaybackFrame: Sendable {
    var snapshot: PlaybackSnapshot?
    var position: Double
    var playing: Bool
    var seekRevision: Int
    var pending: PlaybackSeekRequest?
    var confirmation: PlaybackSeekConfirmation?
    var legacySeekPosition: Double?
}

enum PlaybackSeekError: Error, LocalizedError {
    case timedOut, interrupted, inaccurate
    var errorDescription: String? {
        switch self {
        case .timedOut: "跳转等待超过 10 秒，已恢复实际播放进度。请重试。"
        case .interrupted: "此次跳转未完成，已恢复实际播放进度。请重试。"
        case .inaccurate: "音源未能跳到指定位置，已恢复实际播放进度。请重试。"
        }
    }
}
