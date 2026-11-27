import ActivityKit
import Foundation

struct LockScreenLyricsAttributes: ActivityAttributes {
    struct Row: Codable, Hashable, Identifiable, Sendable {
        let id: Int
        var text: String
    }

    enum Status: String, Codable, Hashable, Sendable {
        case playing, paused, outOfSync, loading, unavailable
    }

    struct ContentState: Codable, Hashable, Sendable {
        var track: Int
        var title: String
        var previous: Row?
        var current: Row?
        var next: Row?
        var status: Status
        var scrollsForward = false
        var backdrop: Data?
        var translation: String?
        var romanization: String?

        var rows: [Row] { [previous, current, next].compactMap { $0 } }
    }

    static let playerURL = URL(string: "amllplayer://lock-screen-lyrics")
}
