import AVFoundation
import SwiftUI

/// Native 5-layer backdrop hierarchy using shared-player hardware reflection
/// and a WindowServer `CABackdropLayer` variable blur without CPU readbacks.
struct ImmersiveArtworkMedia: UIViewRepresentable {
    let video: AnimatedArtwork?
    let layout: Layout
    var background: AMLLBackground?
    var still: ImmersiveStillFrame? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Layout: Equatable {
        let video: CGRect
        let reflection: CGRect
        let blurProfile: ImmersiveBackgroundBlurProfile?
        let presentsFrame: Bool
        let reflectionEnabled: Bool
        let reduceTransparency: Bool
        var backgroundDimming = ImmersiveArtworkPreset.dimmingOpacity
        var tuning: ImmersiveArtworkDebugConfiguration = .calibratedDefault
        var background: CGRect? = nil
        var dimming: CGRect? = nil
        var bottomFade: CGRect = .zero
        var cornerRadius: CGFloat = 0
        var pageOpacity = 1.0
        var videoCornerRadius: CGFloat = 0
        var fitsArtwork = true
        var excludesStatusBarBlur = false
        var showsVideo = true
        var showsBlur = true

        var transition: CGRect { blurProfile?.frame ?? .zero }

        static func inline(frame: CGRect, visible: Bool, presentsFrame: Bool, radius: CGFloat, dimming: Double = 0.16) -> Self {
            var tuning = ImmersiveArtworkDebugConfiguration()
            for layer in ImmersiveArtworkLayer.allCases { tuning[layer].enabled = false }
            tuning[.video].enabled = visible
            tuning[.background].enabled = true
            tuning[.dimming].enabled = dimming > 0
            tuning[.dimming].opacity = dimming
            return .init(video: frame, reflection: .zero, blurProfile: nil, presentsFrame: presentsFrame,
                         reflectionEnabled: false, reduceTransparency: false, backgroundDimming: dimming,
                         tuning: tuning, cornerRadius: 0, pageOpacity: 1, videoCornerRadius: radius, fitsArtwork: false,
                         excludesStatusBarBlur: false, showsVideo: visible, showsBlur: false)
        }

        static func immersive(cover: CGRect, viewport: CGSize, presentsFrame: Bool,
                              reduceTransparency: Bool, cornerRadius: CGFloat = 0, opacity: Double = 1,
                              excludesStatusBarBlur: Bool = false,
                              tuning: ImmersiveArtworkDebugConfiguration = .calibratedDefault,
                              backgroundDimming: Double = ImmersiveArtworkPreset.dimmingOpacity) -> Self {
            let tuning = tuning.enablingReflection()
            let video = AMLLImmersiveArtworkGeometry.fittedFrame(container: tuning[.video].frame(cover), source: cover.size)
            let profile = ImmersiveBackgroundBlurProfile.extendingBackground(video: video, viewport: viewport,
                                                                             adjustment: tuning[.transition])
            let effectiveDimming = tuning.layers[ImmersiveArtworkLayer.dimming.rawValue] == nil
                ? backgroundDimming : tuning[.dimming].opacity
            return .init(video: video,
                         reflection: tuning[.reflection].frame(ArtworkReflectionGeometry.frame(cover: video, viewportHeight: viewport.height)),
                         blurProfile: profile,
                         presentsFrame: presentsFrame,
                         reflectionEnabled: true,
                         reduceTransparency: reduceTransparency,
                         backgroundDimming: effectiveDimming,
                         tuning: tuning,
                         background: tuning[.background].frame(CGRect(origin: .zero, size: viewport)),
                         dimming: tuning[.dimming].frame(CGRect(origin: .zero, size: viewport)),
                         bottomFade: tuning[.bottomFade].frame(AMLLImmersiveArtworkGeometry.bottomFadeFrame(video: video, viewport: viewport)),
                         cornerRadius: cornerRadius,
                         pageOpacity: opacity,
                         videoCornerRadius: 0,
                         fitsArtwork: true,
                         excludesStatusBarBlur: excludesStatusBarBlur,
                         showsVideo: tuning[.video].enabled,
                         showsBlur: tuning[.transition].enabled && tuning.validatedBlur > 0)
        }
    }

    func makeUIView(context _: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.configure(video: video, layout: layout, background: background, still: still,
                       animation: context.transaction.animation, reduceMotion: reduceMotion)
    }
    static func dismantleUIView(_ view: Surface, coordinator _: ()) { view.dismantle() }

    final class ReflectionPlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            playerLayer.backgroundColor = UIColor.clear.cgColor
        }

        required init?(coder _: NSCoder) { nil }
    }

    final class Surface: UIView {
        private var storedVideoSurface: AnimatedArtwork.Surface?
        var hasVideoPlayer: Bool { storedVideoSurface != nil }
        var videoSurface: AnimatedArtwork.Surface {
            if let storedVideoSurface { return storedVideoSurface }
            let view = AnimatedArtwork.Surface()
            storedVideoSurface = view
            videoPlane.insertSubview(view, belowSubview: stillSurface)
            return view
        }

        let backgroundSurface = UIView()
        let dimmingSurface = UIView()
        let videoPlane = UIView()
        let stillSurface = UIImageView()
        let reflectionPlane = UIView()
        private let reflectionContentView = UIView()
        let reflectionVideoView = ReflectionPlayerView()
        let reflectionStillView = UIImageView()
        let transitionSurface = ImmersiveBackdropBlurView()

        private let reflectionFadeMask = CAGradientLayer()
        private var outgoingVideoView: UIView?
        private var outgoingReflectionView: UIView?
        private var outgoingRevision = 0
        private(set) var outgoingFrameCount = 0

        private var configuredURL: URL?
        private var stillFrame: ImmersiveStillFrame?
        private var hasVideo = false
        private var configuredVideo = false
        private var layoutRevision = 0
        private var previousLayout: Layout?
        private var appliedLayout: Layout?
        private var appliedBounds: CGRect?
        private var appliedStatusBarBottom: CGFloat = 0
        private var backgroundHost: UIHostingController<AMLLBackground>?
        private var dismantled = false

        private struct PendingConfiguration {
            let video: AnimatedArtwork?
            let layout: Layout
            let background: AMLLBackground?
            let still: ImmersiveStillFrame?
            let animation: Animation?
            let reduceMotion: Bool
        }
        private var pendingConfiguration: PendingConfiguration?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            clipsToBounds = true

            stillSurface.contentMode = .scaleAspectFit
            videoPlane.addSubview(stillSurface)

            reflectionPlane.clipsToBounds = true
            reflectionFadeMask.colors = ArtworkReflectionStyle.fadeStops.map {
                UIColor(white: 1, alpha: CGFloat($0.alpha)).cgColor
            }
            reflectionFadeMask.locations = ArtworkReflectionStyle.fadeStops.map {
                NSNumber(value: $0.location)
            }
            reflectionPlane.layer.mask = reflectionFadeMask

            reflectionContentView.isOpaque = false
            reflectionContentView.isUserInteractionEnabled = false
            reflectionPlane.addSubview(reflectionContentView)

            reflectionVideoView.transform = CGAffineTransform(scaleX: 1, y: -1)
            reflectionStillView.contentMode = .scaleAspectFit
            reflectionStillView.transform = CGAffineTransform(scaleX: 1, y: -1)
            reflectionContentView.addSubview(reflectionVideoView)
            reflectionContentView.addSubview(reflectionStillView)

            for view in [backgroundSurface, dimmingSurface, videoPlane, reflectionPlane, transitionSurface] {
                view.isOpaque = false
                view.isUserInteractionEnabled = false
                addSubview(view)
            }
        }

        convenience init() {
            self.init(frame: .zero)
        }

        required init?(coder _: NSCoder) { nil }

        func configure(video: AnimatedArtwork?, layout: Layout, background: AMLLBackground? = nil,
                       still: ImmersiveStillFrame? = nil, animation: Animation? = nil, reduceMotion: Bool = false) {
            guard !dismantled else { return }
            pendingConfiguration = PendingConfiguration(video: video, layout: layout, background: background, still: still,
                                                      animation: animation, reduceMotion: reduceMotion)
            applyPendingConfiguration()
        }

        private func applyPendingConfiguration() {
            guard !dismantled, let pendingConfiguration else { return }
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }

            let video = pendingConfiguration.video
            let layout = pendingConfiguration.layout
            let changesMedia = appliedLayout != nil
                && (configuredURL != video?.url || (stillFrame != nil && stillFrame?.image !== pendingConfiguration.still?.image))
            if changesMedia {
                triggerOutgoingCrossfade(reduceMotion: pendingConfiguration.reduceMotion)
            }

            self.pendingConfiguration = nil
            let wasPresented = appliedLayout != nil
            let sourceChanged = hasVideo != (video != nil) || stillFrame?.image !== pendingConfiguration.still?.image
            if appliedLayout != layout || appliedBounds != bounds || sourceChanged { layoutRevision &+= 1 }
            let layoutTicket = layoutRevision
            configuredURL = video?.url
            hasVideo = video != nil

            if stillFrame?.image !== pendingConfiguration.still?.image {
                stillFrame = pendingConfiguration.still
                let uiImage = stillFrame.map { UIImage(cgImage: $0.image) }
                stillSurface.image = uiImage
                reflectionStillView.image = uiImage
            }

            if let background = pendingConfiguration.background {
                if let backgroundHost {
                    backgroundHost.rootView = background
                } else {
                    let host = UIHostingController(rootView: background)
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear
                    host.view.isOpaque = false
                    backgroundSurface.addSubview(host.view)
                    backgroundHost = host
                    appliedLayout = nil
                    attachBackgroundController()
                }
            } else if let host = backgroundHost {
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                backgroundHost = nil
            }

            if let video {
                videoSurface.onFailure = video.onFailure
                videoSurface.onState = video.onState
                videoSurface.onFirstFrame = video.onFirstFrame
            }

            let contentChanged = previousLayout?.presentsFrame != layout.presentsFrame
            previousLayout = layout
            if sourceChanged { appliedLayout = nil }

            if wasPresented, let animation = pendingConfiguration.animation ?? (contentChanged || sourceChanged ? LyricsPageMotion.content : nil) {
                UIView.animate(animation) {
                    self.applyLayout(layout, animated: true, alphaOnly: pendingConfiguration.reduceMotion)
                } completion: { [weak self] in
                    guard let self, self.layoutRevision == layoutTicket else { return }
                    self.finishVisibility(layout)
                }
            } else {
                applyLayout(layout)
            }

            if let video {
                configuredVideo = true
                videoSurface.configure(url: video.url, active: video.active, allowCellular: video.allowCellular,
                                       gravity: layout.fitsArtwork ? .resizeAspect : .resizeAspectFill, fadesBottom: false)
                reflectionVideoView.playerLayer.videoGravity = layout.fitsArtwork ? .resizeAspect : .resizeAspectFill
                videoSurface.attachReflection(to: reflectionVideoView.playerLayer)
            } else if configuredVideo {
                if let storedVideoSurface {
                    storedVideoSurface.detachReflection(reflectionVideoView.playerLayer)
                    storedVideoSurface.stop()
                    storedVideoSurface.removeFromSuperview()
                }
                reflectionVideoView.playerLayer.player = nil
                storedVideoSurface = nil
                configuredVideo = false
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachBackgroundController()
            applyPendingConfiguration()
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
            applyPendingConfiguration()
            if let previousLayout { applyLayout(previousLayout) }
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

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

        private func applyLayout(_ layout: Layout, animated: Bool = false, alphaOnly: Bool = false) {
            let statusBarBottom: CGFloat
            if layout.excludesStatusBarBlur, let window {
                let top = CGPoint(x: window.bounds.minX, y: window.bounds.minY + window.safeAreaInsets.top)
                statusBarBottom = max(0, safeAreaInsets.top, convert(top, from: window).y)
            } else {
                statusBarBottom = 0
            }
            guard appliedLayout != layout || appliedBounds != bounds || appliedStatusBarBottom != statusBarBottom else { return }
            appliedLayout = layout
            appliedBounds = bounds
            appliedStatusBarBottom = statusBarBottom

            CATransaction.begin(); CATransaction.setDisableActions(!animated)
            func place(_ view: UIView, _ frame: CGRect) {
                if alphaOnly { UIView.performWithoutAnimation { view.frame = frame } }
                else { view.frame = frame }
            }
            func placeFlippedMedia(_ view: UIView, size: CGSize) {
                let work = {
                    view.bounds = CGRect(origin: .zero, size: size)
                    view.center = CGPoint(x: size.width / 2, y: size.height / 2)
                }
                if alphaOnly { UIView.performWithoutAnimation(work) } else { work() }
            }

            let tuning = layout.tuning
            layer.cornerRadius = layout.cornerRadius

            place(backgroundSurface, layout.background ?? bounds)
            backgroundSurface.isHidden = !tuning[.background].enabled
            backgroundSurface.alpha = CGFloat(tuning[.background].opacity * layout.pageOpacity)
            if let view = backgroundHost?.view { place(view, backgroundSurface.bounds) }

            let effectiveDimming = tuning.layers[ImmersiveArtworkLayer.dimming.rawValue] == nil
                ? layout.backgroundDimming : tuning[.dimming].opacity
            place(dimmingSurface, layout.dimming ?? bounds)
            dimmingSurface.isHidden = !tuning[.dimming].enabled
            dimmingSurface.backgroundColor = UIColor.black.withAlphaComponent(CGFloat(effectiveDimming * layout.pageOpacity))

            place(videoPlane, layout.video)
            videoPlane.layer.cornerRadius = layout.videoCornerRadius
            videoPlane.clipsToBounds = layout.videoCornerRadius > 0
            if let view = storedVideoSurface { place(view, videoPlane.bounds) }
            place(stillSurface, videoPlane.bounds)
            stillSurface.contentMode = layout.fitsArtwork ? .scaleAspectFit : .scaleAspectFill
            stillSurface.isHidden = stillFrame == nil
            stillSurface.alpha = hasVideo && layout.presentsFrame ? 0 : 1
            storedVideoSurface?.isHidden = !hasVideo
            videoPlane.isHidden = (!layout.showsVideo || !tuning[.video].enabled) && !animated
            videoPlane.alpha = layout.showsVideo && tuning[.video].enabled
                ? CGFloat(tuning[.video].opacity * layout.pageOpacity) : 0

            place(reflectionPlane, layout.reflection)
            reflectionFadeMask.frame = reflectionPlane.bounds
            place(reflectionContentView, reflectionPlane.bounds)
            placeFlippedMedia(reflectionVideoView, size: layout.video.size)
            placeFlippedMedia(reflectionStillView, size: layout.video.size)
            reflectionStillView.contentMode = stillSurface.contentMode
            reflectionStillView.isHidden = stillFrame == nil
            reflectionStillView.alpha = hasVideo && layout.presentsFrame ? 0 : 1
            reflectionVideoView.isHidden = !hasVideo
            let presentsMedia = layout.presentsFrame || stillFrame != nil
            let showsReflection = layout.reflectionEnabled && presentsMedia && layout.showsVideo && tuning[.reflection].enabled
            reflectionPlane.isHidden = !showsReflection && (!animated || !layout.reflectionEnabled || layout.reflection.isEmpty)
            reflectionPlane.alpha = showsReflection ? CGFloat(tuning[.reflection].opacity * layout.pageOpacity) : 0

            var profile = layout.blurProfile ?? .init(frame: .zero, fullStrengthY: 0)
            if videoPlane.isHidden || !presentsMedia {
                profile = profile.backgroundOnly(viewportHeight: bounds.height)
            }
            place(transitionSurface, profile.frame)

            for (index, layer) in tuning.orderedLayers.reversed().enumerated() {
                if let plane = plane(for: layer) {
                    bringSubviewToFront(plane)
                    plane.layer.zPosition = CGFloat(index)
                }
            }

            let fadeEnabled = tuning[.bottomFade].enabled && !layout.reduceTransparency
            videoPlane.mask = fadeEnabled && tuning.isBelow(.video, .bottomFade)
                ? ImmersiveArtworkVisibility.mask(frame: layout.video, fade: layout.bottomFade, strength: tuning[.bottomFade].opacity)
                : nil
            reflectionContentView.mask = fadeEnabled && tuning.isBelow(.reflection, .bottomFade)
                ? ImmersiveArtworkVisibility.mask(frame: layout.reflection, fade: layout.bottomFade, strength: tuning[.bottomFade].opacity)
                : nil

            let blurRadius = CGFloat(tuning.validatedBlur)
            let hideBlur = layout.reduceTransparency || !layout.showsBlur || !tuning[.transition].enabled
                || profile.frame.isEmpty || blurRadius <= 0
            transitionSurface.configure(
                profile: profile,
                radius: blurRadius,
                topFeatherLength: CGFloat(tuning.validatedTopFeatherLength),
                opacity: tuning[.transition].opacity * layout.pageOpacity,
                clearThroughY: statusBarBottom,
                hidden: hideBlur
            )
            CATransaction.commit()
        }

        private func finishVisibility(_ layout: Layout) {
            stillSurface.isHidden = stillFrame == nil || (hasVideo && layout.presentsFrame)
            reflectionStillView.isHidden = stillFrame == nil || (hasVideo && layout.presentsFrame)
            videoPlane.isHidden = !layout.showsVideo || !layout.tuning[.video].enabled
            let presentsMedia = layout.presentsFrame || stillFrame != nil
            reflectionPlane.isHidden = !layout.reflectionEnabled || !presentsMedia
                || !layout.showsVideo || !layout.tuning[.reflection].enabled
        }

        private func triggerOutgoingCrossfade(reduceMotion: Bool) {
            clearOutgoing()
            guard !reduceMotion, window != nil, !videoPlane.isHidden else { return }

            let videoSnapshot = captureSnapshotView(of: videoPlane, fallbackImage: stillSurface.image,
                                                    frame: videoPlane.bounds, contentMode: stillSurface.contentMode)
            guard let videoSnapshot else { return }

            let reflectionSnapshot: UIView? = !reflectionPlane.isHidden && reflectionPlane.alpha > 0
                ? captureSnapshotView(of: reflectionPlane, fallbackImage: reflectionStillView.image,
                                      frame: reflectionStillView.frame, contentMode: reflectionStillView.contentMode,
                                      flipped: true)
                : nil

            outgoingRevision &+= 1
            let ticket = outgoingRevision
            outgoingVideoView = videoSnapshot
            videoPlane.addSubview(videoSnapshot)
            if let reflectionSnapshot {
                outgoingReflectionView = reflectionSnapshot
                reflectionContentView.addSubview(reflectionSnapshot)
            }
            outgoingFrameCount = 1

            CATransaction.begin(); CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.outgoingRevision == ticket else { return }
                    self.clearOutgoing()
                }
            }
            let targets = [videoSnapshot, reflectionSnapshot].compactMap { $0 }
            for view in targets {
                view.layer.opacity = 0
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = Float(1)
                animation.toValue = Float(0)
                animation.duration = LyricsPageMotion.contentDuration
                animation.timingFunction = LyricsPageMotion.contentTimingFunction
                view.layer.add(animation, forKey: "lyricsOutgoingOpacity")
            }
            CATransaction.commit()
        }

        private func captureSnapshotView(of plane: UIView, fallbackImage: UIImage?, frame: CGRect,
                                         contentMode: UIView.ContentMode, flipped: Bool = false) -> UIView? {
            let view: UIView?
            if let snapshot = plane.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = plane.bounds
                view = snapshot
            } else if let fallbackImage {
                let imageView = UIImageView(image: fallbackImage)
                imageView.contentMode = contentMode
                imageView.bounds = CGRect(origin: .zero, size: frame.size)
                imageView.center = CGPoint(x: frame.midX, y: frame.midY)
                if flipped {
                    imageView.transform = CGAffineTransform(scaleX: 1, y: -1)
                }
                view = imageView
            } else {
                view = nil
            }
            view?.isUserInteractionEnabled = false
            return view
        }

        private func clearOutgoing() {
            outgoingRevision &+= 1
            outgoingVideoView?.layer.removeAnimation(forKey: "lyricsOutgoingOpacity")
            outgoingVideoView?.removeFromSuperview()
            outgoingVideoView = nil
            outgoingReflectionView?.layer.removeAnimation(forKey: "lyricsOutgoingOpacity")
            outgoingReflectionView?.removeFromSuperview()
            outgoingReflectionView = nil
            outgoingFrameCount = 0
        }

        func stop() {
            layoutRevision &+= 1
            clearOutgoing()
            configuredURL = nil
            pendingConfiguration = nil
            previousLayout = nil
            appliedLayout = nil
            appliedBounds = nil
            appliedStatusBarBottom = 0
            if let storedVideoSurface {
                storedVideoSurface.detachReflection(reflectionVideoView.playerLayer)
                storedVideoSurface.stop()
                storedVideoSurface.removeFromSuperview()
            }
            storedVideoSurface = nil
            reflectionVideoView.playerLayer.player = nil
            configuredVideo = false
            hasVideo = false
            stillFrame = nil
            stillSurface.image = nil
            reflectionStillView.image = nil
            transitionSurface.stop()
            if let host = backgroundHost {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            backgroundHost = nil
        }

        func dismantle() {
            dismantled = true
            stop()
        }
    }
}

@MainActor
enum ImmersiveArtworkVisibility {
    /// Optional bottom-fade mask for debugging media opacity below the cover.
    static func mask(frame: CGRect, fade: CGRect?, strength: Double,
                     opacity: Double = 1) -> UIView? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        guard fade != nil || opacity != 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { renderer in
            let context = renderer.cgContext
            let rows = max(1, Int(ceil(frame.height)))
            for row in 0 ..< rows {
                let y = CGFloat(row) + 0.5
                let globalY = frame.minY + y
                let alpha = opacity
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
