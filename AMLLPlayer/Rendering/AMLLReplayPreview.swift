#if DEBUG
    import SwiftUI

    struct AMLLReplayPreview: View {
        @State private var frame = 0
        @State private var fps = 60
        @State private var exportURL: URL?
        @State private var error: String?
        var body: some View {
            VStack {
                ReplayCanvas(frameIndex: frame, fps: fps, completed: { data, message in
                    error = message
                    guard let data else { return }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("amll-scenario-trace.json")
                    do { try data.write(to: url, options: .atomic); exportURL = url }
                    catch { self.error = error.localizedDescription }
                })
                HStack {
                    Button("重置") { frame = 0 }
                    Button("上一帧") { frame = max(0, frame - 1) }
                    Button("下一帧") { frame = min(fps * 8 - 1, frame + 1) }
                }
                Slider(value: Binding(get: { Double(frame) }, set: { frame = Int($0) }), in: 0 ... Double(fps * 8 - 1), step: 1)
                Picker("帧率", selection: $fps) { Text("60 Hz").tag(60); Text("120 Hz").tag(120) }
                    .pickerStyle(.segmented).onChange(of: fps) { frame = 0 }
                Text("帧 \(frame)：播放 → 暂停 → seek → 浏览 → 恢复跟随。向后定位从起点重放。")
                    .font(.caption)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if let exportURL {
                    ShareLink("导出实际引擎帧", item: exportURL)
                }
            }
            .padding().background(Color.black).foregroundStyle(.white)
            .navigationTitle("确定性原生回放")
        }
    }

    private struct ReplayCanvas: UIViewRepresentable {
        let frameIndex: Int
        let fps: Int
        let completed: (Data?, String?) -> Void
        func makeUIView(context _: Context) -> AMLLNativeCanvas {
            AMLLNativeCanvas()
        }

        func updateUIView(_ view: AMLLNativeCanvas, context _: Context) {
            do {
                let reference = try AMLLSharedReference.load()
                var configuration = LyricsRenderConfiguration()
                configuration.fontSize = reference.fontSize
                configuration.sizePreset = nil
                configuration.anchor = reference.anchor
                view.configure(document: reference.document, configuration: configuration,
                               input: .init(position: 1, playing: true), active: false, reduceMotion: false)
                let scenario = try AMLLReplayScenario.shared(framesPerSecond: fps)
                var resources: [AMLLNativeCanvas.ResourceCounts] = []
                let frames = try view.replay(scenario, through: frameIndex) { resources.append($0) }
                struct Export: Encodable {
                    let schema = 3
                    let scenario: AMLLReplayScenario
                    let width: Double
                    let height: Double
                    let frames: [AMLLFrameState]
                    let resources: [AMLLNativeCanvas.ResourceCounts]
                }
                let data = try JSONEncoder().encode(Export(scenario: scenario, width: view.bounds.width, height: view.bounds.height, frames: frames, resources: resources))
                DispatchQueue.main.async { completed(data, nil) }
            } catch { DispatchQueue.main.async { completed(nil, error.localizedDescription) } }
        }

        static func dismantleUIView(_ view: AMLLNativeCanvas, coordinator _: ()) {
            view.stop()
        }
    }
#endif
