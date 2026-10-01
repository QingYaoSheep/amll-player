import UIKit

/// Explicit SF Pro default design for the scrolling lyric canvas. Core Text
/// retains the system cascade (including PingFang and emoji). Point size has
/// already been resolved by the canvas; do not apply Dynamic Type a second time.
@MainActor
enum AMLLLyricsFont {
    static func make(pointSize: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        let standard = base.withDesign(.default) ?? base
        let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
        return UIFont(descriptor: standard.addingAttributes([.traits: traits]), size: pointSize)
    }
}
