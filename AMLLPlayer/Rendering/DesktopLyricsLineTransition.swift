import Foundation

/// PiP's readability treatment leaves positions, word clocks and run states
/// to the shared frame engine. Only a focus change retargets the two channels.
@MainActor
struct DesktopLyricsLineTransition {
    struct Appearance: Equatable {
        var opacity: Double
        var blur: Double
    }

    private struct Entry {
        var focused: Bool
        var from: Appearance
        var presented: Appearance
        var began: TimeInterval?
    }

    private var entries: [Int: Entry] = [:]
    var isAnimating: Bool { entries.values.contains { $0.began != nil } }

    mutating func reset() { entries.removeAll(keepingCapacity: true) }

    mutating func keepVisible(_ indexes: Set<Int>) {
        entries = entries.filter { indexes.contains($0.key) }
    }

    mutating func appearance(index: Int, focused: Bool, opacity: Double, blur: Double,
                             maximumBlur: Double, now: TimeInterval, reduceMotion: Bool) -> Appearance {
        let target = Appearance(opacity: opacity * (focused ? 1 : 0.65),
                                blur: focused || reduceMotion ? 0 : min(maximumBlur, max(blur, maximumBlur * 0.35)))
        guard var entry = entries[index] else {
            entries[index] = Entry(focused: focused, from: target, presented: target)
            return target
        }
        if entry.focused != focused {
            entry.focused = focused
            entry.from = entry.presented
            if reduceMotion { entry.from.blur = 0 }
            entry.began = now
        }
        if let began = entry.began, now < began + LyricsPageMotion.contentDuration {
            let fraction = max(0, (now - began) / LyricsPageMotion.contentDuration)
            let weight = AMLLWordMotion.cubicBezier(fraction, x1: 0.23, y1: 1, x2: 0.32, y2: 1)
            entry.presented = Appearance(
                opacity: entry.from.opacity + (target.opacity - entry.from.opacity) * weight,
                blur: reduceMotion ? 0 : entry.from.blur + (target.blur - entry.from.blur) * weight
            )
        } else {
            entry.began = nil
            entry.presented = target
        }
        entries[index] = entry
        return entry.presented
    }
}
