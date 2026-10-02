import CryptoKit
import Foundation

/// Typed, bounded diagnostics. No API headers, media URLs, accounts or lyric text are accepted.
@MainActor final class PlaybackSeekDiagnostics {
    static let shared = PlaybackSeekDiagnostics()
    struct Row: Codable, Sendable {
        var index: Int
        var y: Double
        var scale: Double
        var opacity: Double
        var wordTime: Double
        var scheduledAt: Double?
        var startedAt: Double?
    }
    struct Event: Codable, Sendable {
        var uptime: Double
        var phase: String
        var requestID: UUID?
        var entry: String?
        var service: String?
        var trackHash: String?
        var resource: UUID?
        var target: Double?
        var actual: Double?
        var lyricTime: Double?
        var offset: Double?
        var revision: UInt64?
        var canvas: UUID?
        var rows: [Row]?
        var codec: String?
        var duration: Double?
        var seekableStart: Double?
        var seekableEnd: Double?
    }
    private(set) var events: [Event] = []
    private var frameDeadline = 0.0
    private var lastFrame = 0.0
    private var request: PlaybackSeekRequest?
    private let limit = 800
    func begin(_ request: PlaybackSeekRequest) {
        self.request = request; frameDeadline = ProcessInfo.processInfo.systemUptime + 13; lastFrame = 0
        record("request", request: request, actual: nil)
    }
    func record(_ phase: String, request: PlaybackSeekRequest? = nil, actual: Double? = nil,
                resource: UUID? = nil, revision: UInt64? = nil, canvas: UUID? = nil,
                codec: String? = nil, duration: Double? = nil, seekableStart: Double? = nil, seekableEnd: Double? = nil) {
        let value = request ?? self.request
        append(.init(uptime: ProcessInfo.processInfo.systemUptime, phase: phase, requestID: value?.id,
                     entry: value?.entry.rawValue, service: value?.service.rawValue,
                     trackHash: value.map { SHA256.hash(data: Data($0.trackURI.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() },
                     resource: resource, target: value?.target, actual: actual, lyricTime: value?.lyricTime, offset: value?.offset,
                     revision: revision, canvas: canvas, rows: nil, codec: codec, duration: duration,
                     seekableStart: seekableStart, seekableEnd: seekableEnd))
    }
    func frame(canvas: UUID, state: AMLLFrameState, confirmation: PlaybackSeekConfirmation?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now <= frameDeadline, now - lastFrame >= 1 / 120 else { return }
        lastFrame = now
        let rows = state.rows.filter { !$0.hidden }.prefix(14).map {
            Row(index: $0.lineIndex, y: $0.y, scale: $0.scale, opacity: $0.opacity, wordTime: $0.wordClock.time,
                scheduledAt: $0.positionMotion?.scheduledAt, startedAt: $0.positionMotion?.startedAt)
        }
        append(.init(uptime: now, phase: "canvas-frame", requestID: confirmation?.requestID ?? request?.id,
                     entry: request?.entry.rawValue, service: request?.service.rawValue, trackHash: nil,
                     resource: confirmation?.resourceGeneration, target: confirmation?.target, actual: state.lyricTime,
                     revision: nil, canvas: canvas, rows: Array(rows)))
    }
    private func append(_ event: Event) {
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
    }
    func clear() { events.removeAll(); request = nil; frameDeadline = 0 }
    func export() throws -> URL {
        struct Export: Encodable { var schema = 1; var commit: String; var events: [Event] }
        let commit = Bundle.main.object(forInfoDictionaryKey: "AMLLBuildCommit") as? String ?? "local"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AMLL-seek-" + UUID().uuidString + ".json")
        try encoder.encode(Export(commit: commit, events: events)).write(to: url, options: .atomic)
        return url
    }
}
