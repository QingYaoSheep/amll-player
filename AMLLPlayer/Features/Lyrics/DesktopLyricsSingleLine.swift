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

    static func lyricTime(position: Double, offset: Double) -> Double {
        let position = position.isFinite ? position : 0
        let offset = offset.isFinite ? offset : 0
        return floor((position - offset) * 1000 + 0.5) / 1000
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

    mutating func frame(target: Int?, now: Double, immediate: Bool, blurs: Bool) -> Frame {
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
            phase = .exiting(since: now, alpha: lastVisibleAlpha)
            return .init(layer: .outgoing(alpha: lastVisibleAlpha, blur: 0), capture: index)
        case let .exiting(since, alpha):
            let boundary = since + Self.exitDuration
            if now >= boundary { return enter(target, since: boundary, now: now) }
            let progress = min(1, max(0, (now - since) / Self.exitDuration))
            // Soften the line while it is still legible. Run the fade on a
            // separate smooth curve so the soft frames are visible.
            let opacity = 1 - progress * progress * (3 - 2 * progress)
            let blur = easing(progress * Self.duration)
            return .init(layer: .outgoing(alpha: alpha * opacity,
                                          blur: blurs ? Self.blurMaximum * blur : 0))
        case let .entering(index, since):
            if index == target { return enter(index, since: since, now: now) }
            guard lastVisibleAlpha > 0 else { return enter(target, since: now, now: now) }
            phase = .exiting(since: now, alpha: lastVisibleAlpha)
            return .init(layer: .outgoing(alpha: lastVisibleAlpha, blur: 0), capture: index)
        }
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
