import SwiftUI
import UIKit

struct MarqueeText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let enabled: Bool
    func makeUIView(context _: Context) -> MarqueeLabel {
        MarqueeLabel()
    }

    func updateUIView(_ view: MarqueeLabel, context _: Context) {
        view.update(text: text, fontSize: fontSize, enabled: enabled)
    }

    static func dismantleUIView(_ uiView: MarqueeLabel, coordinator _: ()) {
        uiView.label.layer.removeAllAnimations()
    }
}

final class MarqueeLabel: UIView {
    let label = UILabel()
    private var enabled = false
    private var stopped = false
    private var size: CGFloat = 20
    private var lastBounds = CGRect.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true; addSubview(label); label.textColor = .white
        label.adjustsFontForContentSizeCategory = true
        isAccessibilityElement = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MarqueeLabel, _: UITraitCollection) in
            view.updateFont(); view.lastBounds = .zero; view.setNeedsLayout()
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func update(text: String, fontSize: CGFloat, enabled: Bool) {
        guard label.text != text || self.enabled != enabled || size != fontSize else { return }
        if label.text != text {
            stopped = false
        }
        label.text = text; accessibilityLabel = text; self.enabled = enabled; size = fontSize
        updateFont(); lastBounds = .zero
        setNeedsLayout()
    }

    private func updateFont() {
        label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: size, weight: .semibold), compatibleWith: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != lastBounds else { return }
        lastBounds = bounds
        label.layer.removeAllAnimations()
        label.numberOfLines = 1
        let width = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height)).width
        let scrolls = enabled && !stopped && width > bounds.width && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        label.numberOfLines = scrolls ? 1 : 2
        label.textAlignment = scrolls ? .left : .center
        label.frame = CGRect(x: 0, y: 0, width: scrolls ? width : bounds.width, height: bounds.height)
        accessibilityTraits = scrolls || stopped ? [.button] : [.staticText]
        accessibilityHint = scrolls ? NSLocalizedString("render.stopMarquee", comment: "") : stopped ? NSLocalizedString("render.resumeMarquee", comment: "") : nil
        if scrolls, window != nil {
            let travel = width - bounds.width
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
            animation.values = [0, 0, -travel, -travel, 0]
            animation.keyTimes = [0, 0.1, 0.45, 0.55, 1]
            animation.duration = max(8, Double(travel / 24) * 2 + 2)
            animation.repeatCount = .infinity
            label.layer.add(animation, forKey: "marquee")
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow(); lastBounds = .zero; setNeedsLayout(); if window == nil {
            label.layer.removeAllAnimations()
        }
    }

    @objc private func toggle() {
        stopped.toggle(); lastBounds = .zero; setNeedsLayout()
    }

    override func accessibilityActivate() -> Bool {
        toggle(); return true
    }
}
