#if DEBUG
    import Darwin
    import SwiftUI

    struct LyricsRenderPreview: View {
        @State private var configuration = LyricsRenderConfiguration()
        @State private var position = 0.0
        @State private var playing = false
        @State private var anchor = ProcessInfo.processInfo.systemUptime
        @State private var resume = 0
        @State private var browsing = false
        @State private var renderer: LyricsRenderView?
        @State private var lineTiming = false
        @State private var visible = false
        @Environment(\.scenePhase) private var scenePhase
        var body: some View {
            VStack {
                PreviewRenderer(configuration: configuration, document: lineTiming ? LyricsRenderFixture.lineDocument : LyricsRenderFixture.document,
                                position: currentPosition, playing: playing, active: visible && scenePhase == .active,
                                resume: resume, browsing: { browsing = $0 }, seek: { position = $0; anchor = ProcessInfo.processInfo.systemUptime },
                                created: { renderer = $0 })
                Button("render.returnCurrent") { resume += 1 }
                    .frame(height: 44).opacity(browsing ? 1 : 0).disabled(!browsing).accessibilityHidden(!browsing)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(String(format: "%.0f FPS · %.2f ms · %d rows · %d layouts · %.1f MB", renderer?.measuredFPS ?? 0,
                                renderer?.frameMilliseconds ?? 0, renderer?.visibleRowCount ?? 0, renderer?.cachedLayoutCount ?? 0, memoryMB()))
                        .font(.caption.monospaced()).accessibilityIdentifier("renderMetrics")
                }
                Slider(value: Binding(get: { currentPosition() }, set: { position = $0; anchor = ProcessInfo.processInfo.systemUptime }), in: 0 ... 1800)
                    .accessibilityLabel(Text("render.progress"))
                HStack {
                    Button(playing ? "player.pause" : "player.play") { position = currentPosition(); anchor = ProcessInfo.processInfo.systemUptime; playing.toggle() }
                    Button("render.restart") { position = 0; anchor = ProcessInfo.processInfo.systemUptime; resume += 1 }
                    Toggle("render.translation", isOn: $configuration.translation)
                }
                Slider(value: $configuration.fontSize, in: 24 ... 52).accessibilityLabel(Text("render.fontSize"))
                Toggle("render.preview.line", isOn: $lineTiming)
                Slider(value: $configuration.backgroundBlur, in: 0 ... 80).accessibilityLabel(Text("render.backgroundBlur"))
            }
            .padding().background {
                AlbumArtworkBackground(url: nil, blur: configuration.backgroundBlur, previewImage: Image(uiImage: LyricsRenderFixture.cover))
            }.foregroundStyle(.white)
            .navigationTitle("render.debug")
            .onAppear { visible = true }
            .onDisappear { position = currentPosition(); playing = false; visible = false; renderer?.stop() }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    position = currentPosition(); playing = false
                }
            }
        }

        private func currentPosition() -> Double {
            min(1800, position + (playing ? ProcessInfo.processInfo.systemUptime - anchor : 0))
        }

        private func memoryMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
        }
    }

    private struct PreviewRenderer: UIViewRepresentable {
        let configuration: LyricsRenderConfiguration
        let document: LyricsDocument
        let position: () -> Double
        let playing: Bool
        let active: Bool
        let resume: Int
        let browsing: (Bool) -> Void
        let seek: (Double) -> Void
        let created: (LyricsRenderView) -> Void
        func makeUIView(context _: Context) -> LyricsRenderView {
            let view = LyricsRenderView()
            DispatchQueue.main.async { created(view) }
            return view
        }

        func updateUIView(_ view: LyricsRenderView, context _: Context) {
            view.position = position; view.browsing = browsing; view.seek = seek
            view.update(document: document, configuration: configuration, offset: 0, duration: 1800,
                        playing: playing, active: active, canSeek: true, reduceMotion: UIAccessibility.isReduceMotionEnabled, resumeToken: resume)
        }

        static func dismantleUIView(_ uiView: LyricsRenderView, coordinator _: ()) {
            uiView.stop()
        }
    }

    enum LyricsRenderFixture {
        static let cover = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { context in
            UIColor(red: 0.12, green: 0.24, blue: 0.54, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            UIColor(red: 0.87, green: 0.42, blue: 0.23, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 90, y: -50, width: 220, height: 240))
            UIColor(red: 0.52, green: 0.17, blue: 0.4, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: -70, y: 130, width: 290, height: 180))
        }

        static var lineDocument: LyricsDocument {
            var result = document
            result.lines = result.lines.map { line in
                var line = line; line.words = []; line.precision = .line; return line
            }
            return result
        }

        static let document: LyricsDocument = {
            var lines: [LyricLine] = []
            let samples = ["原生歌词，跟随每一个字。", "A long note held across the light", "こんにちは 世界", "مرحبا بالعالم", "e\u{301} 👩🏽‍🚀 family 👨‍👩‍👧‍👦"]
            for index in 0 ..< 300 {
                let text = samples[index % samples.count]
                let start = Double(index * 6 + 5)
                let characters = Array(text)
                let words = characters.enumerated().map { offset, value in
                    LyricWord(text: String(value), start: start + Double(offset) * 4 / Double(characters.count),
                              end: start + Double(offset + 1) * 4 / Double(characters.count))
                }
                lines.append(LyricLine(id: "preview-\(index)", text: text, start: start, end: start + 4, words: words,
                                       translation: "Synthetic translation \(index)", romanization: "rōmaji / transliteration", isDuet: index % 3 == 1,
                                       isRTL: index % 5 == 3, precision: .word))
                if index % 6 == 2 {
                    lines.append(LyricLine(id: "back-\(index)", text: "(Background)", start: start + 1, end: start + 3, isBackground: true))
                }
            }
            return LyricsDocument(candidate: .init(source: .apple, sourceID: "render-fixture", title: "Native render fixture", artists: ["AMLL"]),
                                  lines: lines, language: "mul", selectionReason: "Synthetic Debug fixture")
        }()
    }
#endif
