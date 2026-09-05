import Foundation

struct LyricsRenderState: Equatable {
    var time: Double
    var active: [Int]
    var focus: Int?
    var gapProgress: Double?
    var interlude: AMLLInterludeRange?
}

struct AMLLInterludeRange: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var isNextDuet: Bool
    var nextLineIndex: Int
}

/// Prefix maximum end times allow overlapping vocals without scanning the whole song each frame.
struct LyricsTimeline {
    let lines: [LyricLine]
    private let prefixEnd: [Double]
    private let interludes: [AMLLInterludeRange]
    init(lines: [LyricLine]) {
        self.lines = lines.filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var maximum = 0.0
        prefixEnd = self.lines.map { maximum = max(maximum, $0.end); return maximum }
        var gaps: [AMLLInterludeRange] = []
        var previousEnd = 0.0
        for (index, line) in self.lines.enumerated() where !line.isBackground {
            let gapEnd = max(previousEnd, line.start - 0.25)
            if gapEnd - previousEnd >= 4 {
                gaps.append(.init(start: previousEnd, end: gapEnd, isNextDuet: line.isDuet, nextLineIndex: index))
            }
            previousEnd = max(previousEnd, line.end)
        }
        interludes = gaps
    }

    func state(position: Double, offset: Double, advance: Double) -> LyricsRenderState {
        let time = (position.isFinite ? position : 0) - (offset.isFinite ? offset : 0)
        let upper = upperBound(time)
        var active: [Int] = []
        var index = upper - 1
        while index >= 0, prefixEnd[index] > time {
            if lines[index].start <= time, time < lines[index].end {
                active.append(index)
            }
            index -= 1
        }
        active.reverse()
        // Keep the newest foreground voice focused after its advance window has ended.
        var focus = active.last { !lines[$0].isBackground } ?? active.last
        let upcoming = upperBound(time + (advance.isFinite ? max(0, advance) : 0))
        if let early = (upper ..< upcoming).first(where: { !lines[$0].isBackground }) {
            focus = early
        }
        if focus == nil {
            focus = upper < lines.count ? upper : lines.indices.last
        }
        let previousEnd = upper > 0 ? prefixEnd[upper - 1] : 0
        let nextStart = upper < lines.count ? lines[upper].start : previousEnd
        let gap = active.isEmpty && nextStart - previousEnd >= 3 && time >= previousEnd
            ? min(1, max(0, (time - previousEnd) / (nextStart - previousEnd))) : nil
        let interludeTime = time + 0.02
        let interlude = interludes.first { $0.start < interludeTime && interludeTime < $0.end }
        return .init(time: time, active: active, focus: focus, gapProgress: gap, interlude: interlude)
    }

    func accessibility(_ state: LyricsRenderState, canSeek: Bool) -> AccessibilityLyricsSnapshot {
        let focus = state.active.first ?? state.focus
        return .init(current: state.active.map { lines[$0].text },
                     previous: focus.flatMap { $0 > 0 ? lines[$0 - 1].text : nil },
                     next: focus.flatMap { $0 + 1 < lines.count ? lines[$0 + 1].text : nil }, canSeek: canSeek)
    }

    static func progress(time: Double, start: Double, end: Double) -> Double {
        guard time.isFinite, start.isFinite, end.isFinite else { return 0 }
        guard time >= start else { return 0 }
        guard end > start else { return 1 }
        return min(1, max(0, (time - start) / (end - start)))
    }

    /// Positive delay means the line is sung later on the Spotify clock; advance is never applied to seek.
    static func seekTarget(line: LyricLine, offset: Double, duration: Double) -> Double {
        min(max(0, duration), max(0, line.start + offset))
    }

    private func upperBound(_ time: Double) -> Int {
        var lower = 0, upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].start <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

struct LyricsFollowState {
    private(set) var following = true
    var position = 0.0
    var velocity = 0.0
    var springParameters = AMLLSpringParameters.verticalDefault
    mutating func browse() {
        following = false; velocity = 0
    }

    mutating func resume() {
        following = true; velocity = 0
    }

    mutating func reset() {
        following = true; position = 0; velocity = 0
    }

    mutating func configure(lineInterval: TimeInterval?, seeking: Bool, interlude: Bool) {
        springParameters = AMLLMotionMetrics.verticalSpring(lineInterval: lineInterval, seeking: seeking, interlude: interlude)
    }

    func isSettled(at target: Double) -> Bool {
        abs(position - target) < 0.25 && abs(velocity) < 0.1
    }

    /// AMLL's analytic spring, including velocity-preserving retargets and its 50 ms dropped-frame clamp.
    mutating func step(target: Double, dt: Double, immediate: Bool) -> Double {
        guard following else { return position }
        if immediate {
            position = target; velocity = 0; return position
        }
        var spring = AMLLSpring(value: position, velocity: velocity)
        spring.parameters = springParameters
        position = spring.step(target: target, delta: dt)
        velocity = spring.velocity
        return position
    }
}
