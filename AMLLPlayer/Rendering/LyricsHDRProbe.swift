#if DEBUG
    import MetalKit
    import SwiftUI

    /// A frozen, real Core Text glyph probe for device EDR validation. This is
    /// intentionally separate from the production canvas until motion parity is verified.
    struct LyricsHDRProbe: UIViewRepresentable {
        var time: Double
        var enabled: Bool

        func makeUIView(context _: Context) -> ProbeView {
            ProbeView()
        }

        func updateUIView(_ view: ProbeView, context _: Context) {
            view.draw(time: time, enabled: enabled)
        }

        @MainActor
        final class ProbeView: UIView {
            private let renderer = LyricsHDRRenderer()
            private var output: CAMetalLayer?
            private var texture: MTLTexture?
            private var layout: AMLLCoreTextLayout?
            private var lastSize = CGSize.zero
            private var time = 0.0
            private var enabled = false
            private let line = LyricLine(id: "hdr-probe", text: "HDR 高光", start: 0, end: 4,
                                         words: [.init(text: "HDR ", start: 0, end: 2), .init(text: "高光", start: 2, end: 4)], precision: .word)

            override func layoutSubviews() {
                super.layoutSubviews()
                draw(time: time, enabled: enabled)
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                lastSize = .zero
                draw(time: time, enabled: enabled)
            }

            func draw(time: Double, enabled: Bool) {
                self.time = time; self.enabled = enabled
                guard bounds.width > 0, bounds.height > 0, window != nil, let renderer else { return }
                if lastSize != bounds.size {
                    let layout = AMLLCoreTextLayout(line: line, width: bounds.width, font: .systemFont(ofSize: 32, weight: .bold), configuration: .init())
                    self.layout = layout
                    texture = layout.raster(scale: window?.screen.scale ?? 1, auxiliary: false, ruby: false).cgImage.flatMap(renderer.glyphTexture)
                    output?.removeFromSuperlayer()
                    output = renderer.makeLayer(size: bounds.size, scale: window?.screen.scale ?? 1)
                    if let output {
                        layer.addSublayer(output)
                    }
                    lastSize = bounds.size
                }
                guard let output, let layout, let texture else { return }
                output.wantsExtendedDynamicRangeContent = enabled
                let capabilities = LyricsHDRCapabilities(supportsEDR: (window?.screen.potentialEDRHeadroom ?? 1) > 1,
                                                         headroom: Double(window?.screen.currentEDRHeadroom ?? 1))
                let state = LyricsHDRFrameState.sample(lines: [line], lyricTime: time,
                                                       configuration: .init(enabled: enabled), capabilities: capabilities)
                let gain = state.activeLineIndexes.contains(0) ? state.outputBrightness : 1
                var vertices: [LyricsHDRRenderer.Vertex] = []
                var consumed: [Int: Double] = [:]
                let indexes = layout.maskWords.indices.filter { layout.maskWords[$0].width > 0 }
                let words = indexes.map { layout.maskWords[$0] }
                for fragment in layout.fragments {
                    guard let index = indexes.firstIndex(of: fragment.wordIndex) else { continue }
                    let edge = AMLLWordMask.edge(time: time, index: index, words: words, feather: 8) - consumed[fragment.wordIndex, default: 0]
                    consumed[fragment.wordIndex, default: 0] += fragment.rect.width
                    for (u, v) in [(0.0, 0.0), (0, 1), (1, 0), (1, 0), (0, 1), (1, 1)] {
                        let x = fragment.rect.minX + u * fragment.rect.width
                        let y = fragment.rect.minY + v * fragment.rect.height
                        vertices.append(.init(position: .init(Float(x / bounds.width * 2 - 1), Float(1 - y / bounds.height * 2)),
                                              uv: .init(Float(x / layout.size.width), Float(y / layout.size.height)),
                                              mask: .init(Float((fragment.rtl ? 1 - u : u) * fragment.rect.width), Float(edge)),
                                              appearance: .init(8, 0.3, 1, Float(gain))))
                    }
                }
                guard let drawable = output.nextDrawable() else { return }
                _ = renderer.render(vertices: vertices, glyphs: texture, target: drawable.texture, drawable: drawable)
            }
        }
    }
#endif
