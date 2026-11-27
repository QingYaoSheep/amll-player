import Foundation

/// A selection timeline in source time. Earlier voices never reclaim the
/// strip when a more recently started voice finishes.
struct DesktopLyricsSingleLineTimeline {
    struct Line: Equatable {
        let index: Int
        let start: Double
        let end: Double
    }

    private let lines: [Line]

    init(document: LyricsDocument) {
        let ordered: [Line] = document.lines.enumerated().compactMap { index, line in
            guard !line.isBackground else { return nil }
            let timed = line.precision == .word && !line.words.isEmpty
            let start = (timed ? line.words.first?.start : nil) ?? line.start
            let end = (timed ? line.words.last?.end : nil) ?? line.end
            let text = timed ? line.words.map(\.text).joined() : line.text
            guard start.isFinite, end.isFinite, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Line(index: index, start: start, end: max(start, end))
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.index < rhs.index : lhs.start < rhs.start
        }
        var unique: [Line] = []
        for line in ordered where unique.last?.start != line.start { unique.append(line) }
        lines = unique
    }

    func line(at lyricTime: Double) -> Line? {
        guard lyricTime.isFinite else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let middle = low + (high - low) / 2
            if lines[middle].start <= lyricTime { low = middle + 1 }
            else { high = middle }
        }
        return low > 0 ? lines[low - 1] : nil
    }

    func line(sourceIndex: Int) -> Line? {
        lines.first { $0.index == sourceIndex }
    }
}

struct DesktopLyricsSingleLineHandoff {
    let catching: [Int]
    let leaving: [Int]
    let upcoming: Int?
    let selected: Int?

    func successor(after index: Int) -> Int? {
        if leaving.contains(index) { return selected ?? upcoming }
        if catching.contains(index) { return upcoming }
        return nil
    }
}

struct DesktopLyricsSingleLineSelection {
    private var selected: DesktopLyricsSingleLineTimeline.Line?
    private var queued: DesktopLyricsSingleLineTimeline.Line?
    private var presentsTailBeforeExit = false
    private(set) var needsNextFrame = false

    mutating func update(timeline: DesktopLyricsSingleLineTimeline?, at time: Double,
                         handoff: DesktopLyricsSingleLineHandoff?, interlude: Bool, reset: Bool,
                         tailInMotion: (Int) -> Bool)
        -> (line: DesktopLyricsSingleLineTimeline.Line?, advancesEarly: Bool)
    {
        needsNextFrame = false
        if reset {
            selected = nil
            queued = nil
            presentsTailBeforeExit = false
        }
        let timed = timeline?.line(at: time)
        if !reset, !interlude, let current = selected ?? timed, let index = handoff?.successor(after: current.index),
           let next = timeline?.line(sourceIndex: index), next.start > current.start {
            selected = current
            if queued == nil, handoff?.leaving.contains(current.index) == true { presentsTailBeforeExit = true }
            if next.start > (queued?.start ?? -.infinity) { queued = next }
        }
        if let queued, let current = selected {
            if tailInMotion(current.index) {
                presentsTailBeforeExit = true
                return (current, false)
            }
            if presentsTailBeforeExit {
                // Publish the final run or cutoff pixels before snapshotting them.
                presentsTailBeforeExit = false
                needsNextFrame = true
                return (current, false)
            }
            self.queued = nil
            selected = interlude ? nil : ((timed?.start ?? -.infinity) > queued.start ? timed : queued)
            return (selected, true)
        }
        if interlude { selected = nil; return (nil, false) }
        if selected == nil || (timed?.start ?? -.infinity) > (selected?.start ?? -.infinity) {
            selected = timed
        }
        return (selected, false)
    }
}

struct DesktopLyricsSingleLineTransition {
    enum Layer: Equatable {
        case empty
        case live(index: Int, alpha: Double)
        case outgoing(alpha: Double, blur: Double)
    }

    struct Frame: Equatable {
        let layer: Layer
        var capture: Int?
    }

    static let duration = 0.12
    static let exitDuration = 0.20
    static let blurMaximum = 2.0

    private enum Phase {
        case empty
        case showing(Int)
        case exiting(since: Double, alpha: Double)
        case entering(index: Int, since: Double)
    }

    private var phase = Phase.empty
    private var lastVisibleAlpha = 1.0

    var isAnimating: Bool {
        switch phase {
        case .exiting, .entering: true
        case .empty, .showing: false
        }
    }

    mutating func frame(target: Int?, now: Double, immediate: Bool, blurs: Bool, earlyDelta: Double = 0) -> Frame {
        if immediate {
            phase = target.map { .showing($0) } ?? .empty
        }
        switch phase {
        case .empty:
            return enter(target, since: now, now: now)
        case let .showing(index):
            if index == target {
                lastVisibleAlpha = 1
                return .init(layer: .live(index: index, alpha: 1))
            }
            return startExit(index, now: now, earlyDelta: earlyDelta, blurs: blurs)
        case let .exiting(since, alpha):
            let boundary = since + Self.exitDuration
            if now >= boundary { return enter(target, since: boundary, now: now) }
            return .init(layer: outgoing(elapsed: now - since, alpha: alpha, blurs: blurs))
        case let .entering(index, since):
            if index == target { return enter(index, since: since, now: now) }
            guard lastVisibleAlpha > 0 else { return enter(target, since: now, now: now) }
            return startExit(index, now: now, earlyDelta: earlyDelta, blurs: blurs)
        }
    }

    private mutating func startExit(_ index: Int, now: Double, earlyDelta: Double, blurs: Bool) -> Frame {
        let elapsed = min(max(0, earlyDelta), 1.0 / 60)
        phase = .exiting(since: now - elapsed, alpha: lastVisibleAlpha)
        return .init(layer: outgoing(elapsed: elapsed, alpha: lastVisibleAlpha, blurs: blurs), capture: index)
    }

    private func outgoing(elapsed: Double, alpha: Double, blurs: Bool) -> Layer {
        let progress = min(1, max(0, elapsed / Self.exitDuration))
        let opacity = 1 - progress * progress * (3 - 2 * progress)
        let softness = easing(progress * Self.duration)
        return .outgoing(alpha: alpha * opacity, blur: blurs ? Self.blurMaximum * softness : 0)
    }

    private mutating func enter(_ index: Int?, since: Double, now: Double) -> Frame {
        guard let index else { phase = .empty; return .init(layer: .empty) }
        let elapsed = now - since
        if now >= since + Self.duration {
            phase = .showing(index)
            lastVisibleAlpha = 1
        } else {
            phase = .entering(index: index, since: since)
            lastVisibleAlpha = easing(elapsed)
        }
        return .init(layer: .live(index: index, alpha: lastVisibleAlpha))
    }

    private func easing(_ elapsed: Double) -> Double {
        AMLLWordMotion.cubicBezier(elapsed / Self.duration, x1: 0.23, y1: 1, x2: 0.32, y2: 1)
    }
}
