import Foundation

/// Round the media height in steps. Expand as soon as there is more text,
/// then wait for the scroll to settle before submitting a shorter format.
struct DesktopLyricsAdaptiveHeight {
    static let minimum: CGFloat = 112
    static let maximum: CGFloat = 240
    static let padding: CGFloat = 10
    private static let tiers: [CGFloat] = [minimum, 136, 160, 184, 208, maximum]

    private(set) var height = Self.minimum
    private var shrinking: (height: CGFloat, since: Double)?
    var isSettling: Bool { shrinking != nil }

    mutating func update(contentHeight: CGFloat, at now: Double, reset: Bool = false) -> CGFloat {
        let required = contentHeight + Self.padding * 2
        let target = Self.tiers.first { $0 >= required } ?? Self.maximum
        if reset || target >= height {
            height = target
            shrinking = nil
        } else if let shrinking, shrinking.height == target {
            if now - shrinking.since >= 0.3 {
                height = target
                self.shrinking = nil
            }
        } else {
            shrinking = (target, now)
        }
        return height
    }
}
