import Foundation

struct LockScreenLyricsTimeline {
    typealias State = LockScreenLyricsAttributes.ContentState
    private struct Cue {
        var row: LockScreenLyricsAttributes.Row
        var start: Double
        var end: Double
    }

    private let cues: [Cue]

    init(document: LyricsDocument) {
        guard !document.isInstrumental else { cues = []; return }
        let sorted = document.lines.enumerated().compactMap { index, line -> Cue? in
            guard !line.isBackground else { return nil }
            let start = line.words.first?.start ?? line.start
            let end = line.words.last?.end ?? line.end
            let text = line.text.isEmpty ? line.words.map(\.text).joined() : line.text
            let display = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard start.isFinite, end.isFinite, start >= 0, end > start, !display.isEmpty else { return nil }
            return Cue(row: .init(id: index, text: display), start: start, end: end)
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.row.id < rhs.row.id : lhs.start < rhs.start
        }
        var unique: [Cue] = []
        for cue in sorted where unique.last?.start != cue.start { unique.append(cue) }
        cues = unique
    }

    var isEmpty: Bool { cues.isEmpty }

    func update(_ state: inout State, position: Double, offset: Double) -> Double? {
        guard position.isFinite, offset.isFinite else { return nil }
        let time = position - offset
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time { low = middle + 1 }
            else { high = middle }
        }
        let latest = low > 0 ? cues[low - 1] : nil
        let next = low < cues.count ? cues[low] : nil
        state.previous = low >= 2 ? cues[low - 2].row : nil
        state.current = latest?.row
        state.next = next?.row
        if let latest, let next, next.start - 0.25 - latest.end >= 4 {
            if time < latest.end { return latest.end + offset }
            state.previous = latest.row
            state.current = nil
        }
        return next.map { $0.start + offset }
    }
}

enum LockScreenLyricsState {
    typealias State = LockScreenLyricsAttributes.ContentState

    static func canFollow(_ snapshot: PlaybackSnapshot, externalSampleAfter: Double?, uptime: Double) -> Bool {
        let age = uptime - snapshot.sampledAtUptime
        guard age.isFinite, age >= 0 else { return false }
        if snapshot.source == .nativeAudio { return age <= 2 }
        if let externalSampleAfter, snapshot.sampledAtUptime <= externalSampleAfter { return false }
        return age <= (snapshot.source == .musicKit ? 2 : 8)
    }

    static func isForward(_ old: State?, _ new: State, discontinuity: Bool) -> Bool {
        guard let old, !discontinuity, old.track == new.track,
              old.status == .playing, new.status == .playing, let current = new.current else { return false }
        return old.next?.id == current.id
    }

    static func project(_ state: inout State, timeline: LockScreenLyricsTimeline?, position: Double,
                        offset: Double, playing: Bool, trusted: Bool, previous: State?) -> Double? {
        guard trusted else {
            if let previous, previous.track == state.track {
                state.previous = previous.previous
                state.current = previous.current
                state.next = previous.next
            }
            state.status = .outOfSync
            return nil
        }
        guard let timeline else { return nil }
        state.status = playing ? .playing : .paused
        return timeline.update(&state, position: position, offset: offset)
    }

    static func fitted(_ source: State) -> State {
        var state = source
        state.title = prefix(state.title, bytes: 192)
        state.previous = state.previous.map { shortened($0, to: 480) }
        state.current = state.current.map { shortened($0, to: 960) }
        state.next = state.next.map { shortened($0, to: 480) }
        let encoder = JSONEncoder()
        func fits(_ value: State) -> Bool { ((try? encoder.encode(value))?.count ?? .max) <= 3_800 }
        if fits(state) { return state }
        state.backdrop = nil
        if fits(state) { return state }
        // Quotes and control characters can take more space once encoded.
        state.title = prefix(state.title, bytes: 120)
        state.previous = state.previous.map { shortened($0, to: 120) }
        state.next = state.next.map { shortened($0, to: 120) }
        state.current = state.current.map { shortened($0, to: 200) }
        return state
    }

    private static func shortened(_ row: LockScreenLyricsAttributes.Row, to bytes: Int) -> LockScreenLyricsAttributes.Row {
        .init(id: row.id, text: prefix(row.text, bytes: bytes))
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var length = 0
        let characters = text.prefix { character in
            length += String(character).utf8.count
            return length <= bytes - 3
        }
        return String(characters) + "…"
    }
}

struct LockScreenLyricsSession {
    private(set) var dismissed = false

    mutating func dismiss() { dismissed = true }
    mutating func ended() { dismissed = false }

    func canStart(foreground: Bool, playing: Bool, synchronized: Bool) -> Bool {
        foreground && playing && synchronized && !dismissed
    }
}
