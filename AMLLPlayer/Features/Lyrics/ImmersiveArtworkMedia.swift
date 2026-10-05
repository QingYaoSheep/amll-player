import AVFoundation
import SwiftUI

/// One native hierarchy determines the visible backdrop used by the untinted blur.
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
        var cornerRadius: CGFloat = 0
        var pageOpacity = 1.0
        var blurProfile: ImmersiveBackgroundBlurProfile? = nil
    }

    func makeUIView(context _: Context) -> Surface { Surface(frames: frames) }
    func updateUIView(_ view: Surface, context _: Context) {
        view.configure(video: video, layout: layout, background: background)
    }
    static func dismantleUIView(_ view: Surface, coordinator _: ()) { view.dismantle() }

    final class Surface: UIView {
        let videoSurface = AnimatedArtwork.Surface()
        let reflectionSurface = ArtworkReflection.Surface()
        let reflectionPlane = UIView()
        let transitionSurface = ImmersiveLiveBlurSurface()
        let videoPlane = UIView()
        let backgroundSurface = UIView()
        let dimmingSurface = UIView()
        private let frames: ArtworkReflectionFrames
        private let presentation: ArtworkFramePresentation
        private var backgroundHost: UIHostingController<AMLLBackground>?
        private var previousLayout: Layout?
        private var appliedLayout: Layout?
        private var appliedBounds: CGRect?
        private var blurProfile: ImmersiveBackgroundBlurProfile?
        private var rejectedConfiguration = false
        private struct PendingConfiguration {
            let video: AnimatedArtwork
            let layout: Layout
            let background: AMLLBackground?
        }
        private var pendingConfiguration: PendingConfiguration?
        private var waitingForAttachment = false
        private var dismantled = false

        init(frames: ArtworkReflectionFrames) {
            self.frames = frames
            presentation = frames.makePresentation()
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
            transitionSurface.capture = { [weak self] in self?.captureBlurInput() }
        }

        required init?(coder _: NSCoder) { nil }

        func configure(video: AnimatedArtwork, layout: Layout, background: AMLLBackground? = nil) {
            guard !dismantled else { return }
            pendingConfiguration = PendingConfiguration(video: video, layout: layout, background: background)
            applyPendingConfiguration()
        }

        /// SwiftUI may update/measure a representable which never enters a
        /// window. Only the attached, sized presentation may claim the hub.
        /// Window/layout callbacks commit the latest input without requiring
        /// another SwiftUI update or restarting the resource request.
        private func applyPendingConfiguration() {
            guard !dismantled, let pendingConfiguration else { return }
            guard window != nil, bounds.width > 0, bounds.height > 0 else {
                if !waitingForAttachment {
                    frames.recordLifecycle("等待窗口与有效尺寸", presentation: presentation)
                    waitingForAttachment = true
                }
                return
            }
            self.pendingConfiguration = nil
            waitingForAttachment = false
            guard frames.activate(presentation, reflection: reflectionSurface, blur: transitionSurface) else {
                if !rejectedConfiguration {
                    frames.recordLifecycle("配置拒绝：较旧呈现", presentation: presentation)
                    rejectedConfiguration = true
                }
                videoSurface.stop()
                return
            }
            let video = pendingConfiguration.video
            let layout = pendingConfiguration.layout
            let background = pendingConfiguration.background
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
                reflectionFrames: frames, presentation: presentation, gravity: .resizeAspect, fadesBottom: false)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            frames.recordLifecycle(window == nil ? "离开窗口" : "进入窗口", presentation: presentation)
            attachBackgroundController()
            applyPendingConfiguration()
            if window != nil, frames.ownsPresentation(presentation) {
                videoSurface.refreshReflectionFrame()
                frames.replayLatest()
            }
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
            guard frames.ownsPresentation(presentation) else { return }
            guard appliedLayout != layout || appliedBounds != bounds else { return }
            appliedLayout = layout
            appliedBounds = bounds
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let tuning = layout.tuning
            layer.cornerRadius = layout.cornerRadius
            backgroundSurface.frame = layout.background ?? bounds
            backgroundSurface.isHidden = !tuning[.background].enabled
            backgroundSurface.alpha = tuning[.background].opacity * layout.pageOpacity
            backgroundHost?.view.frame = backgroundSurface.bounds
            dimmingSurface.frame = layout.dimming ?? bounds
            dimmingSurface.isHidden = !tuning[.dimming].enabled
            dimmingSurface.backgroundColor = UIColor.black.withAlphaComponent(CGFloat(
                (tuning.layers[ImmersiveArtworkLayer.dimming.rawValue] == nil
                    ? layout.backgroundDimming : tuning[.dimming].opacity) * layout.pageOpacity))

            videoPlane.frame = layout.video
            videoSurface.frame = videoPlane.bounds
            videoPlane.isHidden = !tuning[.video].enabled
            videoPlane.alpha = tuning[.video].opacity * layout.pageOpacity
            reflectionPlane.frame = layout.reflection
            reflectionSurface.frame = reflectionPlane.bounds
            reflectionPlane.isHidden = !layout.reflectionEnabled || !layout.presentsFrame || !tuning[.reflection].enabled
            reflectionSurface.isHidden = reflectionPlane.isHidden
            reflectionSurface.configure(opacity: tuning[.reflection].opacity * layout.pageOpacity)
            var profile = layout.blurProfile ?? .init(frame: layout.transition, fullStrengthY: layout.video.maxY)
            if videoPlane.isHidden || !layout.presentsFrame { profile = profile.backgroundOnly(viewportHeight: bounds.height) }
            blurProfile = profile
            transitionSurface.frame = profile.frame
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
            // Media opacity fades independently; the backdrop fade changes only its blur radius.
            layer.mask = nil
            videoPlane.mask = ImmersiveArtworkVisibility.mask(frame: layout.video,
                fade: bottomFade(for: .video), strength: tuning[.bottomFade].opacity)
            reflectionPlane.mask = ImmersiveArtworkVisibility.mask(frame: layout.reflection,
                fade: bottomFade(for: .reflection), strength: tuning[.bottomFade].opacity)
            transitionSurface.configure(amount: tuning.validatedBlur / 80,
                mask: ImmersiveArtworkVisibility.blurMask(profile: profile,
                    topFeatherLength: CGFloat(tuning.validatedTopFeatherLength),
                    opacity: tuning[.transition].opacity * layout.pageOpacity))
            let actualFeather = profile.effectiveTopFeatherLength(CGFloat(tuning.validatedTopFeatherLength))
            frames.blurLayoutDiagnostic = "模糊 Y=\(Int(profile.frame.minY))–\(Int(profile.frame.maxY)) pt；半径：\(tuning.validatedBlur) pt；显示：\(transitionSurface.isHidden ? "关闭" : "开启")；混合比例：\(tuning[.transition].opacity)；顶部羽化：\(tuning.validatedTopFeatherLength) pt（实际 \(actualFeather) pt）"
            CATransaction.commit()
            let visible = bounds.intersection(layout.reflection)
            let covered = [.background, .dimming, .video].filter {
                tuning[$0].enabled && tuning[$0].opacity > 0 && tuning.isBelow(.reflection, $0)
            }.map(\.title).joined(separator: "、")
            frames.layoutDiagnostic = "视频 Y=\(Int(layout.video.minY))–\(Int(layout.video.maxY)) pt；倒影 Y=\(Int(layout.reflection.minY))–\(Int(layout.reflection.maxY)) pt\n倒影屏内高度：\(visible.isNull ? 0 : Int(visible.height)) pt；显示：\(reflectionPlane.isHidden ? "关闭" : "开启")；不透明度：\(tuning[.reflection].opacity)\n倒影上方可能遮盖的层：\(covered.isEmpty ? "无" : covered)"
            reflectionSurface.setNeedsLayout()
            frames.replayLatest()
        }

        /// Snapshot only actual lower planes. AVPlayerLayer cannot be rendered
        /// using CALayer.render, so its current frame comes from the same player.
        /// No offscreen/hidden/upper video is kept in the blur input.
        private func captureBlurInput() -> ImmersiveBlurInput? {
            guard frames.ownsPresentation(presentation), let layout = previousLayout, let profile = blurProfile,
                  window != nil, !transitionSurface.isHidden else { return nil }
            // Sample now rather than using the older asynchronously rendered
            // reflection. Both media planes below use this exact pixel buffer.
            videoSurface.refreshReflectionFrame(hostTime: CACurrentMediaTime())
            let currentBuffer = frames.currentBuffer
            let padding = CGFloat(layout.tuning.validatedBlur * 3)
            let region = profile.frame.insetBy(dx: -padding, dy: -padding).intersection(bounds)
            guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
            let scale = min(1.5, window?.screen.scale ?? 1)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: region.size, format: format)
            var layers: [ImmersiveBlurInput.Plane] = []
            // Read the real hierarchy each time, including any additional lower sibling.
            // Equal zPosition values use UIKit's insertion order. Never capture this
            // effect or an upper plane, which would feed yesterday's blur back into itself.
            let ordered = subviews.enumerated().sorted { lhs, rhs in
                if lhs.element.layer.zPosition != rhs.element.layer.zPosition {
                    return lhs.element.layer.zPosition < rhs.element.layer.zPosition
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
            guard let effectIndex = ordered.firstIndex(where: { $0 === transitionSurface }) else { return nil }
            frames.blurInputs = []
            frames.blurWaitingForVideoFrame = false
            for view in ordered.prefix(effectIndex) {
                guard !view.isHidden, view.alpha > 0,
                      view.frame.intersects(region) else { continue }
                if view === videoPlane {
                    guard layout.presentsFrame, videoSurface.layer.opacity > 0 else { continue }
                    guard let buffer = currentBuffer else {
                        // A background-only clone over a displayed video is not
                        // a backdrop blur. Wait for this resource's actual pixels.
                        frames.blurWaitingForVideoFrame = true
                        transitionSurface.discardComposition()
                        return nil
                    }
                    let mask = (videoPlane.mask as? UIImageView)?.image?.cgImage
                    layers.append(.video(buffer, frame: videoPlane.frame, mask: mask, opacity: Double(videoPlane.alpha)))
                    frames.blurInputs.append("完整视频")
                } else if view === reflectionPlane {
                    guard let buffer = currentBuffer, reflectionSurface.layer.opacity > 0 else { continue }
                    let mask = (reflectionPlane.mask as? UIImageView)?.image?.cgImage
                    layers.append(.reflection(buffer, frame: reflectionPlane.frame, mask: mask,
                        opacity: Double(reflectionPlane.alpha) * Double(reflectionSurface.layer.opacity)))
                    frames.blurInputs.append("封面倒影")
                } else if view === dimmingSurface, let color = view.backgroundColor {
                    layers.append(.solid(CIColor(color: color), frame: view.frame))
                    frames.blurInputs.append("暗度")
                } else {
                    let image = renderer.image { context in
                        context.cgContext.translateBy(x: view.frame.minX - region.minX, y: view.frame.minY - region.minY)
                        // Public hierarchy capture includes the hosting view's Metal backgrounds.
                        view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
                    }
                    if let image = image.cgImage { layers.append(.bitmap(image)) }
                    frames.blurInputs.append(view === reflectionPlane ? "封面倒影"
                        : view === backgroundSurface ? "背景" : view === dimmingSurface ? "暗度" : "附加下层")
                }
            }
            return ImmersiveBlurInput(region: region, profile: profile, scale: scale, planes: layers)
        }

        func stop() {
            frames.recordLifecycle("停止视图（\(window == nil ? "未挂载" : "已挂载")，\(Int(bounds.width))×\(Int(bounds.height)) pt）", presentation: presentation)
            pendingConfiguration = nil
            waitingForAttachment = false
            previousLayout = nil
            appliedLayout = nil
            appliedBounds = nil
            videoSurface.stop()
            reflectionSurface.clear()
            transitionSurface.stop()
            frames.release(presentation)
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
    /// A reusable display mask, outside the video/blur color pipeline. It is
    /// rebuilt only with layout/tuning, never captured back into the blur input.
    static func blurMask(profile: ImmersiveBackgroundBlurProfile, topFeatherLength: CGFloat,
                         opacity: Double = 1) -> UIView? {
        let opacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
        let length = profile.effectiveTopFeatherLength(topFeatherLength)
        guard length > 0, profile.frame.width > 0, profile.frame.height > 0 else {
            return mask(frame: profile.frame, fade: nil, strength: 0, opacity: opacity)
        }
        let view = UIView(frame: CGRect(origin: .zero, size: profile.frame.size))
        view.isOpaque = false
        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        var locations = (0 ... 16).map { NSNumber(value: Double(length * CGFloat($0) / 16 / profile.frame.height)) }
        var colors = (0 ... 16).map { sample in
            UIColor(white: 1, alpha: CGFloat(opacity) * profile.topFeatherOpacity(
                at: profile.frame.minY + length * CGFloat(sample) / 16, length: length)).cgColor
        }
        if length < profile.frame.height {
            locations.append(1)
            colors.append(UIColor(white: 1, alpha: CGFloat(opacity)).cgColor)
        }
        gradient.locations = locations
        gradient.colors = colors
        view.layer.addSublayer(gradient)
        return view
    }

    /// Media fading is independent of the continuous background blur profile.
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
