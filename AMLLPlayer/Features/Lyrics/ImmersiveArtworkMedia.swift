import AVFoundation
import SwiftUI

/// All media live in one UIKit/CALayer hierarchy. An AVPlayerLayer must not be
/// separately hosted above an offscreen SwiftUI blur or mask composition.
struct ImmersiveArtworkMedia: UIViewRepresentable {
    let video: AnimatedArtwork
    let frames: ArtworkReflectionFrames
    let layout: Layout

    struct Layout: Equatable {
        let video: CGRect
        let reflection: CGRect
        let transition: CGRect
        let bottomFade: CGRect
        let tuning: ImmersiveArtworkDebugConfiguration
        let presentsFrame: Bool
        let reflectionEnabled: Bool
        let reduceTransparency: Bool
    }

    func makeUIView(context _: Context) -> Surface { Surface(frames: frames) }
    func updateUIView(_ view: Surface, context _: Context) { view.configure(video: video, layout: layout) }
    static func dismantleUIView(_ view: Surface, coordinator _: ()) { view.stop() }

    final class Surface: UIView {
        let videoSurface = AnimatedArtwork.Surface()
        let reflectionSurface = ArtworkReflection.Surface()
        let transitionSurface = ArtworkVideoTransition.Surface()
        /// Keep visibility/opacity outside the AVPlayerLayer's own readiness alpha.
        let videoPlane = UIView()
        private let frames: ArtworkReflectionFrames
        private let finalMask = CALayer()
        private let outsideFade = CAShapeLayer()
        private let fade = CAGradientLayer()
        private let belowFade = CALayer()
        private var previousLayout: Layout?

        init(frames: ArtworkReflectionFrames) {
            self.frames = frames
            super.init(frame: .zero)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            clipsToBounds = true
            videoPlane.isOpaque = false
            videoPlane.addSubview(videoSurface)
            addSubview(videoPlane)
            addSubview(reflectionSurface)
            addSubview(transitionSurface)
            // A single common parent provides an actual compositing order,
            // including the hardware-backed AVPlayerLayer beneath videoPlane.
            videoPlane.layer.zPosition = 0
            reflectionSurface.layer.zPosition = 0
            transitionSurface.layer.zPosition = 1
            finalMask.addSublayer(outsideFade)
            finalMask.addSublayer(fade)
            finalMask.addSublayer(belowFade)
            finalMask.masksToBounds = true
            outsideFade.fillRule = .evenOdd
            outsideFade.fillColor = UIColor.white.cgColor
            frames.attach(reflectionSurface)
            frames.attach(transitionSurface)
        }

        required init?(coder _: NSCoder) { nil }

        func configure(video: AnimatedArtwork, layout: Layout) {
            videoSurface.onFailure = video.onFailure
            videoSurface.onState = video.onState
            videoSurface.onFirstFrame = video.onFirstFrame
            if previousLayout != layout {
                previousLayout = layout
                applyLayout(layout)
            }
            videoSurface.configure(url: video.url, active: video.active, allowCellular: video.allowCellular,
                reflectionFrames: frames, gravity: .resizeAspect, fadesBottom: false)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let previousLayout { applyLayout(previousLayout) }
        }

        private func applyLayout(_ layout: Layout) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let tuning = layout.tuning
            videoPlane.frame = layout.video
            videoSurface.frame = videoPlane.bounds
            videoPlane.isHidden = !tuning[.video].enabled
            videoPlane.alpha = tuning[.video].opacity
            reflectionSurface.frame = layout.reflection
            reflectionSurface.isHidden = !layout.reflectionEnabled || !layout.presentsFrame
            reflectionSurface.configure(opacity: tuning[.reflection].opacity)
            transitionSurface.frame = layout.transition
            transitionSurface.isHidden = !layout.presentsFrame || layout.reduceTransparency || !tuning[.transition].enabled
            transitionSurface.alpha = tuning[.transition].opacity
            transitionSurface.configure(videoSize: layout.video.size, composition: .init(
                video: layout.video, reflection: layout.reflection, transition: layout.transition,
                reflectionEnabled: layout.reflectionEnabled, reflectionOpacity: tuning[.reflection].opacity,
                blurRadius: tuning.validatedBlur))
            configureFinalMask(layout)
            CATransaction.commit()
            reflectionSurface.setNeedsLayout()
            transitionSurface.setNeedsLayout()
            // Replays a paused frame when an effect was toggled back on.
            frames.replayLatest()
        }

        private func configureFinalMask(_ layout: Layout) {
            guard layout.tuning[.bottomFade].enabled, !layout.reduceTransparency else {
                layer.mask = nil
                return
            }
            let rect = layout.bottomFade
            let strength = layout.tuning[.bottomFade].opacity
            finalMask.frame = bounds
            outsideFade.frame = bounds
            let outside = CGMutablePath()
            outside.addRect(bounds)
            outside.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                  height: max(0, bounds.maxY - rect.minY)))
            outsideFade.path = outside
            fade.frame = rect
            fade.colors = AMLLImmersiveArtworkGeometry.bottomFadeStops.map {
                UIColor(white: 1, alpha: CGFloat(1 - (1 - $0.alpha) * strength)).cgColor
            }
            fade.locations = AMLLImmersiveArtworkGeometry.bottomFadeStops.map { NSNumber(value: $0.location) }
            belowFade.frame = CGRect(x: rect.minX, y: rect.maxY, width: rect.width,
                                     height: max(0, bounds.maxY - rect.maxY))
            belowFade.backgroundColor = UIColor(white: 1, alpha: CGFloat(1 - strength)).cgColor
            layer.mask = finalMask
        }

        func stop() {
            videoSurface.stop()
            reflectionSurface.clear()
            transitionSurface.clear()
        }
    }
}
