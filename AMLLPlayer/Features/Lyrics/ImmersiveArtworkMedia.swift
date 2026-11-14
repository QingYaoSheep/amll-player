import AVFoundation
import SwiftUI

/// One native hierarchy determines the visible backdrop used by the untinted blur.
struct ImmersiveArtworkMedia: UIViewRepresentable {
    let video: AnimatedArtwork?
    let frames: ArtworkReflectionFrames
    let layout: Layout
    var background: AMLLBackground?
    var still: ImmersiveStillFrame? = nil

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
        var videoCornerRadius: CGFloat = 0

        static func inline(frame: CGRect, visible: Bool, presentsFrame: Bool, radius: CGFloat) -> Self {
            var tuning = ImmersiveArtworkDebugConfiguration()
            for layer in ImmersiveArtworkLayer.allCases { tuning[layer].enabled = false }
            tuning[.video].enabled = visible
            return .init(video: frame, reflection: .zero, transition: .zero, bottomFade: .zero,
                tuning: tuning, presentsFrame: presentsFrame, reflectionEnabled: false,
                reduceTransparency: false, videoCornerRadius: radius)
        }

        /// Both immersive pages use the same calibrated content rectangles.
        /// Lyrics and controls live above this native backdrop, never in its blur.
        static func immersive(cover: CGRect, viewport: CGSize, configuration: LyricsRenderConfiguration,
                              tuning: ImmersiveArtworkDebugConfiguration, presentsFrame: Bool,
                              reduceTransparency: Bool, cornerRadius: CGFloat = 0, opacity: Double = 1) -> Self {
            let video = AMLLImmersiveArtworkGeometry.fittedFrame(container: tuning[.video].frame(cover), source: cover.size)
            let profile = ImmersiveBackgroundBlurProfile.extendingBackground(video: video, viewport: viewport,
                adjustment: tuning[.transition])
            return .init(video: video,
                reflection: tuning[.reflection].frame(ArtworkReflectionGeometry.frame(cover: video, viewportHeight: viewport.height)),
                transition: profile.frame,
                bottomFade: tuning[.bottomFade].frame(AMLLImmersiveArtworkGeometry.bottomFadeFrame(video: video, viewport: viewport)),
                tuning: tuning, presentsFrame: presentsFrame,
                reflectionEnabled: configuration.animatedArtwork?.reflection == true && tuning[.reflection].enabled,
                reduceTransparency: reduceTransparency,
                background: tuning[.background].frame(CGRect(origin: .zero, size: viewport)),
                dimming: tuning[.dimming].frame(CGRect(origin: .zero, size: viewport)),
                backgroundDimming: configuration.backgroundDimming ?? 0.16,
                cornerRadius: cornerRadius, pageOpacity: opacity, blurProfile: profile)
        }
    }

    func makeUIView(context _: Context) -> Surface { Surface(frames: frames) }
    func updateUIView(_ view: Surface, context: Context) {
        view.configure(video: video, layout: layout, background: background, still: still,
            animation: context.transaction.animation)
    }
    static func dismantleUIView(_ view: Surface, coordinator _: ()) { view.dismantle() }

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
        let reflectionSurface = ArtworkReflection.Surface()
        let reflectionPlane = UIView()
        let transitionSurface = ImmersiveLiveBlurSurface()
        let videoPlane = UIView()
        let stillSurface = UIImageView()
        private let outgoingSurface = UIImageView()
        private let outgoingReflection = ArtworkReflection.Surface()
        private var outgoingBuffer: CVPixelBuffer?
        private var snapshotTask: Task<Void, Never>?
        private var snapshotRevision = 0
        private var configuredURL: URL?
        private(set) var outgoingFrameCount = 0
        let backgroundSurface = UIView()
        let dimmingSurface = UIView()
        private let frames: ArtworkReflectionFrames
        private let presentation: ArtworkFramePresentation
        private var backgroundHost: UIHostingController<AMLLBackground>?
        private let backgroundFrames = AMLLBackgroundFrameSource()
        private var usesNativeBackground = false
        private(set) var nativeBackgroundCaptures = 0
        var backgroundFrameStatistics: (copies: Int, skipped: Int, textures: Int, bytes: Int) { backgroundFrames.statistics }
        private var previousLayout: Layout?
        private var appliedLayout: Layout?
        private var appliedBounds: CGRect?
        private var blurProfile: ImmersiveBackgroundBlurProfile?
        private var rejectedConfiguration = false
        private struct PendingConfiguration {
            let video: AnimatedArtwork?
            let layout: Layout
            let background: AMLLBackground?
            let still: ImmersiveStillFrame?
            let animation: Animation?
        }
        private var pendingConfiguration: PendingConfiguration?
        private var waitingForAttachment = false
        private var dismantled = false
        private var stillFrame: ImmersiveStillFrame?
        private var hasVideo = false
        private var configuredVideo = false
        private(set) var backgroundReadbacks = 0

        init(frames: ArtworkReflectionFrames) {
            self.frames = frames
            presentation = frames.makePresentation()
            super.init(frame: .zero)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            clipsToBounds = true
            stillSurface.contentMode = .scaleAspectFit
            videoPlane.addSubview(stillSurface)
            outgoingSurface.contentMode = .scaleAspectFit
            outgoingSurface.isUserInteractionEnabled = false
            videoPlane.addSubview(outgoingSurface)
            outgoingReflection.isUserInteractionEnabled = false
            reflectionPlane.addSubview(reflectionSurface)
            reflectionPlane.addSubview(outgoingReflection)
            for view in [backgroundSurface, dimmingSurface, videoPlane, reflectionPlane, transitionSurface] {
                view.isOpaque = false
                addSubview(view)
            }
            // The blur is a live backdrop effect, never an independent video-frame copy.
            transitionSurface.capture = { [weak self] in self?.captureBlurInput() }
        }

        required init?(coder _: NSCoder) { nil }

        func configure(video: AnimatedArtwork?, layout: Layout, background: AMLLBackground? = nil,
                       still: ImmersiveStillFrame? = nil, animation: Animation? = nil) {
            guard !dismantled else { return }
            pendingConfiguration = PendingConfiguration(video: video, layout: layout, background: background, still: still, animation: animation)
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
                storedVideoSurface?.stop()
                return
            }
            let video = pendingConfiguration.video
            let layout = pendingConfiguration.layout
            let wasPresented = appliedLayout != nil
            let sourceChanged = hasVideo != (video != nil) || stillFrame?.image !== pendingConfiguration.still?.image
            if configuredURL != video?.url || (stillFrame != nil && stillFrame?.image !== pendingConfiguration.still?.image) {
                retainOutgoingFrame()
            }
            configuredURL = video?.url
            hasVideo = video != nil
            if stillFrame?.image !== pendingConfiguration.still?.image {
                stillFrame = pendingConfiguration.still
                stillSurface.image = stillFrame.map { UIImage(cgImage: $0.image) }
                transitionSurface.discardComposition()
            }
            var background = pendingConfiguration.background
            usesNativeBackground = background?.mode.isMesh == true && background?.dimming == 0
                && layout.tuning[.background].enabled && layout.tuning[.transition].enabled
                && layout.tuning.isBelow(.background, .transition) && layout.tuning.validatedBlur > 0
                && !layout.reduceTransparency
            backgroundFrames.setEnabled(usesNativeBackground)
            background?.frameSource = usesNativeBackground ? backgroundFrames : nil
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
            if let video {
                videoSurface.onFailure = video.onFailure
                videoSurface.onState = video.onState
                videoSurface.onFirstFrame = video.onFirstFrame
            }
            if background == nil, let host = backgroundHost {
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                backgroundHost = nil
            }
            let contentChanged = previousLayout?.presentsFrame != layout.presentsFrame
            previousLayout = layout
            if sourceChanged { appliedLayout = nil }
            if wasPresented, let animation = pendingConfiguration.animation ?? (contentChanged || sourceChanged ? LyricsPageMotion.content : nil) {
                UIView.animate(animation) { self.applyLayout(layout, animated: true) } completion: { [weak self] in
                    guard let self, self.appliedLayout == layout else { return }
                    self.finishVisibility(layout)
                }
            } else { applyLayout(layout) }
            if let video {
                configuredVideo = true
                videoSurface.configure(url: video.url, active: video.active, allowCellular: video.allowCellular,
                    reflectionFrames: frames, presentation: presentation, gravity: .resizeAspect, fadesBottom: false)
            } else if configuredVideo {
                storedVideoSurface?.stop()
                storedVideoSurface?.removeFromSuperview()
                storedVideoSurface = nil
                configuredVideo = false
            }
            if (!hasVideo || !layout.presentsFrame), reflectionSurface.layer.contents == nil, let stillFrame {
                reflectionSurface.display(stillFrame.buffer)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            frames.recordLifecycle(window == nil ? "离开窗口" : "进入窗口", presentation: presentation)
            attachBackgroundController()
            applyPendingConfiguration()
            if window != nil, frames.ownsPresentation(presentation) {
                storedVideoSurface?.refreshReflectionFrame()
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

        private func applyLayout(_ layout: Layout, animated: Bool = false) {
            guard frames.ownsPresentation(presentation) else { return }
            guard appliedLayout != layout || appliedBounds != bounds else { return }
            appliedLayout = layout
            appliedBounds = bounds
            CATransaction.begin(); CATransaction.setDisableActions(!animated)
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
            videoPlane.layer.cornerRadius = layout.videoCornerRadius
            videoPlane.clipsToBounds = layout.videoCornerRadius > 0
            storedVideoSurface?.frame = videoPlane.bounds
            stillSurface.frame = videoPlane.bounds
            outgoingSurface.frame = videoPlane.bounds
            stillSurface.isHidden = stillFrame == nil
            stillSurface.alpha = hasVideo && layout.presentsFrame ? 0 : 1
            // Keep the real layer drawing beneath its still fallback so its
            // first-frame readiness cannot depend on unhiding that same layer.
            storedVideoSurface?.isHidden = !hasVideo
            videoPlane.isHidden = !tuning[.video].enabled && !animated
            videoPlane.alpha = tuning[.video].enabled ? tuning[.video].opacity * layout.pageOpacity : 0
            reflectionPlane.frame = layout.reflection
            reflectionSurface.frame = reflectionPlane.bounds
            outgoingReflection.frame = reflectionPlane.bounds
            let presentsMedia = layout.presentsFrame || stillFrame != nil
            reflectionPlane.isHidden = (!layout.reflectionEnabled || !presentsMedia || !tuning[.reflection].enabled) && !animated
            reflectionPlane.alpha = layout.reflectionEnabled && presentsMedia && tuning[.reflection].enabled ? 1 : 0
            reflectionSurface.isHidden = reflectionPlane.isHidden
            reflectionSurface.configure(opacity: tuning[.reflection].opacity * layout.pageOpacity)
            var profile = layout.blurProfile ?? .init(frame: layout.transition, fullStrengthY: layout.video.maxY)
            if videoPlane.isHidden || !presentsMedia { profile = profile.backgroundOnly(viewportHeight: bounds.height) }
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
            if !hasVideo || !layout.presentsFrame, let stillFrame { reflectionSurface.display(stillFrame.buffer) }
        }

        private func finishVisibility(_ layout: Layout) {
            videoPlane.isHidden = !layout.tuning[.video].enabled
            reflectionPlane.isHidden = !layout.reflectionEnabled || !(layout.presentsFrame || stillFrame != nil)
                || !layout.tuning[.reflection].enabled
        }

        private func retainOutgoingFrame() {
            snapshotRevision &+= 1
            let ticket = snapshotRevision
            snapshotTask?.cancel()
            snapshotTask = nil
            outgoingSurface.layer.removeAllAnimations()
            outgoingReflection.layer.removeAllAnimations()
            outgoingSurface.image = nil; outgoingBuffer = nil; outgoingReflection.clear()
            outgoingFrameCount = 0
            if hasVideo, let buffer = frames.currentBuffer {
                let input = LyricsArtworkSnapshot(buffer: buffer)
                let started = CACurrentMediaTime()
                snapshotTask = Task { @MainActor [weak self] in
                    let decoded = await LyricsArtworkSnapshotDecoder.shared.decode(input)
                    guard !Task.isCancelled, let self, self.snapshotRevision == ticket, let decoded,
                          CACurrentMediaTime() - started < 0.2 else { return }
                    self.fadeOutgoing(decoded, ticket: ticket)
                }
            } else if let stillFrame { fadeOutgoing(stillFrame, ticket: ticket) }
        }

        private func fadeOutgoing(_ frame: ImmersiveStillFrame, ticket: Int) {
            outgoingSurface.image = UIImage(cgImage: frame.image)
            outgoingSurface.alpha = 1
            outgoingBuffer = frame.buffer; outgoingFrameCount = 1
            outgoingReflection.alpha = CGFloat(reflectionSurface.layer.opacity)
            outgoingReflection.display(frame.buffer)
            UIView.animate(LyricsPageMotion.content) {
                self.outgoingSurface.alpha = 0
                self.outgoingReflection.alpha = 0
            } completion: { [weak self] in
                guard let self, self.snapshotRevision == ticket else { return }
                self.outgoingSurface.image = nil; self.outgoingBuffer = nil
                self.outgoingReflection.clear(); self.outgoingFrameCount = 0
                self.snapshotTask = nil
            }
        }

        /// Snapshot only actual lower planes. AVPlayerLayer cannot be rendered
        /// using CALayer.render, so its current frame comes from the same player.
        /// No offscreen/hidden/upper video is kept in the blur input.
        private func captureBlurInput() -> ImmersiveBlurInput? {
            guard frames.ownsPresentation(presentation), let layout = previousLayout, let targetProfile = blurProfile,
                  window != nil, !transitionSurface.isHidden else { return nil }
            // UIKit/SwiftUI animations change presentation geometry before the
            // model reaches it. Sampling target rectangles makes the blur lead
            // the visible video by the entire transition duration.
            func presentedFrame(_ view: UIView) -> CGRect { view.layer.presentation()?.frame ?? view.frame }
            func presentedOpacity(_ view: UIView) -> Double { Double(view.layer.presentation()?.opacity ?? Float(view.alpha)) }
            let videoFrame = presentedFrame(videoPlane)
            let profile = ImmersiveBackgroundBlurProfile(frame: presentedFrame(transitionSurface),
                fullStrengthY: targetProfile.fullStrengthY + (videoPlane.isHidden ? 0 : videoFrame.maxY - layout.video.maxY))
            // Sample now rather than using the older asynchronously rendered
            // reflection. Both media planes below use this exact pixel buffer.
            if hasVideo { storedVideoSurface?.refreshReflectionFrame(hostTime: CACurrentMediaTime()) }
            let currentBuffer = hasVideo && layout.presentsFrame ? frames.currentBuffer : stillFrame?.buffer
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
                let frame = presentedFrame(view)
                let opacity = presentedOpacity(view)
                guard !view.isHidden, opacity > 0, frame.intersects(region) else { continue }
                if view === videoPlane {
                    guard layout.presentsFrame || stillFrame != nil, (storedVideoSurface?.layer.opacity ?? 1) > 0 else { continue }
                    guard let buffer = currentBuffer else {
                        // A background-only clone over a displayed video is not
                        // a backdrop blur. Wait for this resource's actual pixels.
                        frames.blurWaitingForVideoFrame = true
                        transitionSurface.discardComposition()
                        return nil
                    }
                    let mask = (videoPlane.mask as? UIImageView)?.image?.cgImage
                    layers.append(.video(buffer, frame: frame, mask: mask, opacity: opacity))
                    if let old = outgoingBuffer, let alpha = outgoingSurface.layer.presentation()?.opacity, alpha > 0 {
                        layers.append(.video(old, frame: AMLLImmersiveArtworkGeometry.fittedFrame(container: frame,
                            source: CGSize(width: CVPixelBufferGetWidth(old), height: CVPixelBufferGetHeight(old))),
                            mask: mask, opacity: opacity * Double(alpha)))
                    }
                    frames.blurInputs.append("完整视频")
                } else if view === reflectionPlane {
                    guard let buffer = currentBuffer, reflectionSurface.layer.opacity > 0 else { continue }
                    let mask = (reflectionPlane.mask as? UIImageView)?.image?.cgImage
                    layers.append(.reflection(buffer, frame: frame, mask: mask,
                        opacity: opacity * Double(reflectionSurface.layer.presentation()?.opacity ?? reflectionSurface.layer.opacity)))
                    if let old = outgoingBuffer, let alpha = outgoingReflection.layer.presentation()?.opacity, alpha > 0 {
                        layers.append(.reflection(old, frame: frame, mask: mask, opacity: opacity * Double(alpha)))
                    }
                    frames.blurInputs.append("封面倒影")
                } else if view === dimmingSurface, let color = view.backgroundColor {
                    layers.append(.solid(CIColor(color: color), frame: frame))
                    frames.blurInputs.append("暗度")
                } else if view === backgroundSurface, usesNativeBackground,
                          let frame = backgroundFrames.current(viewport: view.bounds.size) {
                    layers.append(.background(frame, frame: presentedFrame(view), opacity: opacity))
                    nativeBackgroundCaptures += 1
                    frames.blurInputs.append("背景（GPU 共享）")
                } else {
                    if view === backgroundSurface { backgroundReadbacks += 1 }
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
            snapshotRevision &+= 1
            snapshotTask?.cancel(); snapshotTask = nil
            outgoingSurface.image = nil; outgoingBuffer = nil
            outgoingReflection.clear(); outgoingFrameCount = 0; configuredURL = nil
            frames.recordLifecycle("停止视图（\(window == nil ? "未挂载" : "已挂载")，\(Int(bounds.width))×\(Int(bounds.height)) pt）", presentation: presentation)
            pendingConfiguration = nil
            waitingForAttachment = false
            previousLayout = nil
            appliedLayout = nil
            appliedBounds = nil
            storedVideoSurface?.stop()
            storedVideoSurface?.removeFromSuperview()
            storedVideoSurface = nil
            configuredVideo = false
            stillFrame = nil
            stillSurface.image = nil
            reflectionSurface.clear()
            transitionSurface.stop()
            backgroundFrames.setEnabled(false)
            usesNativeBackground = false
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
