import SwiftUI
import UIKit

/// Pointer entry matches source TextMarquee; tapping is the touch equivalent.
/// The full string remains a single VoiceOver element even while clipped.
struct AMLLMetadataText: UIViewRepresentable {
    var text: String
    var size: CGFloat
    var bold = false
    var enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context _: Context) -> Label {
        Label()
    }

    func updateUIView(_ view: Label, context _: Context) {
        view.configure(text: text, size: size, bold: bold,
                       enabled: enabled && !reduceMotion && scenePhase == .active)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Label, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.label.intrinsicContentSize.width,
               height: uiView.label.font.lineHeight)
    }

    static func dismantleUIView(_ view: Label, coordinator _: ()) {
        view.stop()
    }

    @MainActor
    final class Label: UIView {
        let label = UILabel()
        private let fade = CAGradientLayer()
        private var enabled = false
        private var pointSize: CGFloat = 17
        private var bold = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textColor = .white
            label.numberOfLines = 1
            addSubview(label)
            layer.mask = fade
            fade.startPoint = .init(x: 0, y: 0.5)
            fade.endPoint = .init(x: 1, y: 0.5)
            isAccessibilityElement = true
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(activate)))
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) { (view: Label, _: UITraitCollection) in
                view.updateFont(); view.stop(); view.invalidateIntrinsicContentSize(); view.setNeedsLayout()
            }
        }

        required init?(coder _: NSCoder) {
            nil
        }

        func configure(text: String, size: CGFloat, bold: Bool, enabled: Bool) {
            guard label.text != text || pointSize != size || self.bold != bold || self.enabled != enabled else { return }
            stop()
            label.text = text; accessibilityLabel = text
            pointSize = size; self.bold = bold; self.enabled = enabled
            updateFont()
            accessibilityTraits = enabled ? .button : .staticText
            invalidateIntrinsicContentSize(); setNeedsLayout()
        }

        private func updateFont() {
            label.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .systemFont(ofSize: pointSize, weight: bold || traitCollection.legibilityWeight == .bold ? .bold : .regular),
                compatibleWith: traitCollection
            )
        }

        override var intrinsicContentSize: CGSize {
            label.intrinsicContentSize
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let next = CGRect(x: 0, y: 0, width: label.intrinsicContentSize.width, height: bounds.height)
            if label.frame != next || fade.frame != bounds {
                stop()
            }
            label.frame = next; fade.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                stop()
            }
        }

        func stop() {
            label.layer.removeAnimation(forKey: "sourceMarquee")
            fade.removeAnimation(forKey: "sourceMarqueeFade")
            fade.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
            fade.locations = [0, 0.05, 0.95, 1]
        }

        @objc private func activate() {
            guard enabled, window != nil else { return }
            if label.layer.animation(forKey: "sourceMarquee") != nil {
                stop(); return
            }
            let motion = AMLLMarqueeMotion(textWidth: label.bounds.width, viewportWidth: bounds.width)
            guard motion.distance > 0 else { return }
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
            animation.values = [NSNumber(value: 0.0), NSNumber(value: -motion.distance), NSNumber(value: 0.0)]
            animation.keyTimes = [0, 0.5, 1]
            animation.duration = motion.legDuration * 2
            animation.calculationMode = .linear
            label.layer.add(animation, forKey: "sourceMarquee")
            let fadeAnimation = CAKeyframeAnimation(keyPath: "colors")
            let colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
            fadeAnimation.values = [colors, colors]
            fadeAnimation.duration = animation.duration
            fade.add(fadeAnimation, forKey: "sourceMarqueeFade")
        }

        @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
            if gesture.state == .began {
                activate()
            }
            if gesture.state == .ended || gesture.state == .cancelled {
                stop()
            }
        }

        override func accessibilityActivate() -> Bool {
            guard enabled else { return false }
            activate(); return true
        }
    }
}
