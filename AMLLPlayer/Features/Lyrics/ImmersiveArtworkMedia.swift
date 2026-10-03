import AVFoundation
import SwiftUI

/// One native hierarchy determines the actual backdrop sampled by UIKit's live blur.
struct ImmersiveArtworkMedia: UIViewRepresentable {
    let video: AnimatedArtwork
    let frames: ArtworkReflectionFrames
    let layout: Layout
    var background: AMLLBackground?

    struct Layout: Equatable {
        let video: CGRect
        let reflection: CGRect
        let transition: CGRect
        let bottomFade: CGRect
        let tuning: ImmersiveArtworkDebugConfiguration
        let presentsFrame: Bool
        let reflectionEnabled: Bool
        let reduceTransparency: Bool
        var background: CGRect? = nil
        var dimming: CGRect? = nil
        var backgroundDimming = 0.16
    }

    func makeUIView(context _: Context) -> Surface { Surface(frames: frames) }
    func updateUIView(_ view: Surface, context _: Context) {
        view.configure(video: video, layout: layout, background: background)
    }
    static func dismantleUIView(_ view: Surface, coordinator _: ()) { view.stop() }

    final class Surface: UIView {
        let videoSurface = AnimatedArtwork.Surface()
        let reflectionSurface = ArtworkReflection.Surface()
        let reflectionPlane = UIView()
        let transitionSurface = ImmersiveLiveBlurSurface()
        let videoPlane = UIView()
        let backgroundSurface = UIView()
        let dimmingSurface = UIView()
        private let frames: ArtworkReflectionFrames
        private var backgroundHost: UIHostingController<AMLLBackground>?
        private var previousLayout: Layout?
        private var appliedLayout: Layout?
        private var appliedBounds: CGRect?

        init(frames: ArtworkReflectionFrames) {
            self.frames = frames
            super.init(frame: .zero)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            clipsToBounds = true
            videoPlane.addSubview(videoSurface)
            reflectionPlane.addSubview(reflectionSurface)
            for view in [backgroundSurface, dimmingSurface, videoPlane, reflectionPlane, transitionSurface] {
                view.isOpaque = false
                addSubview(view)
            }
            // The blur is a live backdrop effect, never an independent video-frame copy.
            frames.attach(reflectionSurface)
        }

        required init?(coder _: NSCoder) { nil }

        func configure(video: AnimatedArtwork, layout: Layout, background: AMLLBackground? = nil) {
            if let background {
                if let backgroundHost { backgroundHost.rootView = background }
                else {
                    let host = UIHostingController(rootView: background)
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear
                    backgroundSurface.addSubview(host.view)
                    backgroundHost = host
                    appliedLayout = nil
                    attachBackgroundController()
                }
            }
            videoSurface.onFailure = video.onFailure
            videoSurface.onState = video.onState
            videoSurface.onFirstFrame = video.onFirstFrame
            previousLayout = layout
            applyLayout(layout)
            videoSurface.configure(url: video.url, active: video.active, allowCellular: video.allowCellular,
                reflectionFrames: frames, gravity: .resizeAspect, fadesBottom: false)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachBackgroundController()
        }

        private func attachBackgroundController() {
            guard window != nil, let host = backgroundHost, host.parent == nil else { return }
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController {
                    controller.addChild(host)
                    host.didMove(toParent: controller)
                    return
                }
                responder = current.next
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let previousLayout { applyLayout(previousLayout) }
        }

        /// Excludes the mask-operation marker, which has no painted surface of its own.
        func plane(for layer: ImmersiveArtworkLayer) -> UIView? {
            switch layer {
            case .background: backgroundSurface
            case .dimming: dimmingSurface
            case .video: videoPlane
            case .reflection: reflectionPlane
            case .transition: transitionSurface
            case .bottomFade: nil
            }
        }

        private func applyLayout(_ layout: Layout) {
            guard appliedLayout != layout || appliedBounds != bounds else { return }
            appliedLayout = layout
            appliedBounds = bounds
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let tuning = layout.tuning
            backgroundSurface.frame = layout.background ?? bounds
            backgroundSurface.isHidden = !tuning[.background].enabled
            backgroundSurface.alpha = tuning[.background].opacity
            backgroundHost?.view.frame = backgroundSurface.bounds
            dimmingSurface.frame = layout.dimming ?? bounds
            dimmingSurface.isHidden = !tuning[.dimming].enabled
            dimmingSurface.backgroundColor = UIColor.black.withAlphaComponent(CGFloat(
                tuning.layers[ImmersiveArtworkLayer.dimming.rawValue] == nil
                    ? layout.backgroundDimming : tuning[.dimming].opacity))

            videoPlane.frame = layout.video
            videoSurface.frame = videoPlane.bounds
            videoPlane.isHidden = !tuning[.video].enabled
            videoPlane.alpha = tuning[.video].opacity
            reflectionPlane.frame = layout.reflection
            reflectionSurface.frame = reflectionPlane.bounds
            reflectionPlane.isHidden = !layout.reflectionEnabled || !layout.presentsFrame || !tuning[.reflection].enabled
            reflectionSurface.isHidden = reflectionPlane.isHidden
            reflectionSurface.configure(opacity: tuning[.reflection].opacity)
            transitionSurface.frame = layout.transition
            transitionSurface.isHidden = layout.reduceTransparency || !tuning[.transition].enabled || tuning.validatedBlur == 0

            // Both UIView order and CALayer order follow the saved priority.
            for (index, layer) in tuning.orderedLayers.reversed().enumerated() {
                if let plane = plane(for: layer) {
                    bringSubviewToFront(plane)
                    plane.layer.zPosition = CGFloat(index)
                }
            }
            let fadeEnabled = tuning[.bottomFade].enabled && !layout.reduceTransparency
            func bottomFade(for layer: ImmersiveArtworkLayer) -> CGRect? {
                fadeEnabled && tuning.isBelow(layer, .bottomFade) ? layout.bottomFade : nil
            }
            // UIKit forbids masks/partial alpha on a live blur's ancestors. Apply
            // its combined visibility mask directly to the effect view instead.
            layer.mask = nil
            videoPlane.mask = ImmersiveArtworkVisibility.mask(frame: layout.video,
                fade: bottomFade(for: .video), strength: tuning[.bottomFade].opacity)
            reflectionPlane.mask = ImmersiveArtworkVisibility.mask(frame: layout.reflection,
                fade: bottomFade(for: .reflection), strength: tuning[.bottomFade].opacity)
            transitionSurface.configure(amount: tuning.validatedBlur / 80,
                mask: ImmersiveArtworkVisibility.mask(frame: layout.transition,
                    fade: bottomFade(for: .transition), strength: tuning[.bottomFade].opacity,
                    transitionEnd: layout.video.maxY, opacity: tuning[.transition].opacity))
            CATransaction.commit()
            reflectionSurface.setNeedsLayout()
            frames.replayLatest()
        }

        func stop() {
            videoSurface.stop()
            reflectionSurface.clear()
            transitionSurface.stop()
            if let host = backgroundHost {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            backgroundHost = nil
        }
    }
}

/// Public UIKit backdrop sampling automatically respects hidden views and z order.
/// The control is normalized effect strength, not a claimed Gaussian radius in pt.
final class ImmersiveLiveBlurSurface: UIVisualEffectView {
    private var effectAnimator: UIViewPropertyAnimator?
    private(set) var amount: Double = -1

    init() {
        super.init(effect: nil)
        isUserInteractionEnabled = false
    }
    required init?(coder _: NSCoder) { nil }

    func configure(amount: Double, mask: UIView?) {
        if self.amount != amount || effectAnimator == nil {
            if effectAnimator == nil {
                let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                    self?.effect = UIBlurEffect(style: .regular)
                }
                animator.pausesOnCompletion = true
                animator.startAnimation()
                animator.pauseAnimation()
                effectAnimator = animator
            }
            self.amount = amount
            effectAnimator?.fractionComplete = CGFloat(min(1, max(0, amount)))
        }
        // Reassign on every geometry change: UIKit copies a visual-effect mask.
        self.mask = mask
        alpha = 1
    }

    func stop() {
        effectAnimator?.stopAnimation(true)
        effectAnimator = nil
        effect = nil
        mask = nil
    }
}

@MainActor
enum ImmersiveArtworkVisibility {
    /// A direct view mask combines the upward blur fade, debug opacity and final
    /// downward fade without putting the live backdrop inside a masked parent.
    static func mask(frame: CGRect, fade: CGRect?, strength: Double,
                     transitionEnd: CGFloat? = nil, opacity: Double = 1) -> UIView? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        guard fade != nil || transitionEnd != nil || opacity != 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { renderer in
            let context = renderer.cgContext
            let rows = max(1, Int(ceil(frame.height)))
            for row in 0 ..< rows {
                let y = CGFloat(row) + 0.5
                let globalY = frame.minY + y
                var alpha = opacity
                if let transitionEnd {
                    let t = min(1, max(0, (globalY - frame.minY) / max(1, transitionEnd - frame.minY)))
                    alpha *= Double(t * t * (3 - 2 * t))
                }
                context.setFillColor(UIColor(white: 1, alpha: CGFloat(alpha)).cgColor)
                context.fill(CGRect(x: 0, y: CGFloat(row), width: frame.width, height: 1))
                if let fade, globalY >= fade.minY {
                    let t = min(1, max(0, (globalY - fade.minY) / max(1, fade.height)))
                    let faded = alpha * (1 - Double(t * t * (3 - 2 * t)) * strength)
                    context.setBlendMode(.copy)
                    context.setFillColor(UIColor(white: 1, alpha: CGFloat(faded)).cgColor)
                    context.fill(CGRect(x: fade.minX - frame.minX, y: CGFloat(row), width: fade.width, height: 1)
                        .intersection(CGRect(origin: .zero, size: frame.size)))
                    context.setBlendMode(.normal)
                }
            }
        }
        return UIImageView(image: image)
    }
}
