import MetalKit
import UIKit

/// A user-requested, one-shot inspection. No screenshots, URLs, lyric text,
/// playback changes or recurring sampling are involved.
@MainActor enum LyricsCompositingDiagnostics {
    static func text(configuration: LyricsRenderConfiguration, profile: LyricsPresentationProfile,
                     recovery: LyricsCompositingRecovery? = nil) -> String {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func metalLayers(_ layer: CALayer) -> [CAMetalLayer] {
            (layer as? CAMetalLayer).map { [$0] } ?? (layer.sublayers ?? []).flatMap(metalLayers)
        }
        func scrollAncestor(_ view: UIView) -> UIScrollView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView { return scroll }
                ancestor = current.superview
            }
            return nil
        }
        func number(_ value: Double) -> String { String(format: "%.3f", value) }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden }
        let views = windows.flatMap(descendants)
        let canvases = views.compactMap { $0 as? AMLLNativeCanvas }.filter { $0.window != nil }
        let build = Bundle.main.object(forInfoDictionaryKey: "AMLLBuildCommit") as? String ?? "unknown"
        var lines = ["歌词混色诊断：\(build.prefix(8))", "系统：\(UIDevice.current.systemVersion)；布局：\(profile.rawValue)",
            "自动混色刷新：\(recovery?.phase.rawValue ?? "无")；完成次数：\(recovery?.completedRefreshes ?? 0)；当前透明度乘数：\(String(format: "%.8f", recovery?.opacity ?? 1))",
            "背景：\((configuration.backgroundMode ?? .mesh).rawValue)；沉浸歌词：\(configuration.immersiveLyrics == true)",
            "HDR 设置：\(configuration.hdr?.enabled == true)；减少透明度：\(UIAccessibility.isReduceTransparencyEnabled)",
            "原生画布：\(canvases.count)"]
        for (index, canvas) in canvases.prefix(2).enumerated() {
            guard let screen = canvas.window?.screen else { continue }
            let metal = metalLayers(canvas.layer)
            lines.append("画布\(index)：\(canvas.bounds)；alpha：\(number(Double(canvas.alpha)))；隐藏：\(canvas.isHidden)")
            lines.append("EDR 当前／潜在：\(number(Double(screen.currentEDRHeadroom)))／\(number(Double(screen.potentialEDRHeadroom)))；显示缩放：\(screen.scale)")
            lines.append("歌词帧率：\(number(canvas.measuredFPS))；帧耗时：\(number(canvas.frameMilliseconds)) ms；HDR Metal 层：\(metal.count)")
            if let frame = canvas.frameState {
                lines.append("歌词时间：\(number(frame.lyricTime))；浏览：\(frame.browsing)；稳定：\(frame.settled)")
                for row in frame.rows.filter({ !$0.hidden && $0.y > -200 && $0.y < Double(canvas.bounds.height) + 200 }).prefix(8) {
                    lines.append("行\(row.lineIndex)：\(row.visualFocus.rawValue)；活动：\(row.active)；亮／暗：\(number(row.brightAlpha))／\(number(row.darkAlpha))；透明度：\(number(row.opacity))；模糊：\(number(row.blur))；缩放：\(number(row.scale))")
                }
            }
            for (index, layer) in metal.prefix(4).enumerated() {
                lines.append("Metal\(index)：格式\(layer.pixelFormat.rawValue)；EDR：\(layer.wantsExtendedDynamicRangeContent)；透明度：\(number(Double(layer.opacity)))；隐藏：\(layer.isHidden)；尺寸：\(layer.drawableSize)")
            }
            var ancestor: UIView? = canvas
            for depth in 0 ..< 14 {
                guard let view = ancestor else { break }
                let layer = view.layer
                var description = "父层\(depth)：\(String(describing: type(of: view)).prefix(96))；alpha：\(String(format: "%.8f", Double(view.alpha)))；opaque：\(view.isOpaque)；裁剪：\(layer.masksToBounds)；遮罩：\(layer.mask != nil)；组透明：\(layer.allowsGroupOpacity)"
                description += "；混色：\(String(describing: layer.compositingFilter ?? "无"))"
                if #available(iOS 26.0, *) { description += "；动态范围：\(layer.preferredDynamicRange)" }
                if let scroll = view as? UIScrollView { description += "；滚动：\(scroll.isScrollEnabled)；偏移：\(scroll.contentOffset)" }
                lines.append(description)
                ancestor = view.superview
            }
        }
        for view in views.compactMap({ $0 as? MTKView }).prefix(4) {
            lines.append("背景 Metal：\(view.bounds)；alpha：\(number(Double(view.alpha)))；暂停：\(view.isPaused)；目标帧率：\(view.preferredFramesPerSecond)；framebufferOnly：\(view.framebufferOnly)")
            if let canvas = canvases.first {
                lines.append("背景与歌词共享滚动容器：\(scrollAncestor(view) === scrollAncestor(canvas))")
            }
        }
        lines.append("父层混色字段仅表示对应 CALayer 属性；单独为无不代表 SwiftUI 混色未生效。")
        return lines.joined(separator: "\n")
    }
}
