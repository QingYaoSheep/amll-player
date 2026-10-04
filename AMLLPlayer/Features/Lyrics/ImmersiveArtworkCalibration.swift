import SwiftUI

struct ImmersiveArtworkCalibration: View {
    @State private var store = ImmersiveArtworkStyleStore.shared
    @Environment(\.dismiss) private var dismiss
    let frames: ArtworkReflectionFrames
    @State private var diagnostic = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("渐变模糊") {
                    slider("起点相对歌曲信息", key: \.blurStartOffset, range: -320 ... 160, unit: "pt")
                    slider("渐变长度", key: \.blurLength, range: 16 ... 400, unit: "pt")
                    slider("最大模糊半径", key: \.blurRadius, range: 0 ... 80, unit: "pt")
                }
                Section("封面倒影") {
                    slider("可用区域长度", key: \.reflectionLength, range: 0.1 ... 1, unit: "×", step: 0.01)
                    slider("不透明度", key: \.reflectionOpacity, range: 0 ... 1, unit: "", step: 0.01)
                    Text("倒影开关沿用歌词外观中的封面倒影选项。倒影贴合视频底边，越往下越透明。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("视频底部渐隐") {
                    Toggle("启用旧版视频渐隐", isOn: $store.style.videoFadeEnabled)
                    Text("沿用原渐变采样：上方 66% 不透明，底部 34% 渐隐至视频底边。仅处理视频。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("实时渲染诊断") {
                    Text(diagnostic).font(.caption).monospacedDigit()
                    Button("复制诊断") { UIPasteboard.general.string = diagnostic }
                }
                Section {
                    Button("恢复默认") { store.reset() }
                    ShareLink("导出校准数值", item: store.exported)
                    Button("复制校准数值") { UIPasteboard.general.string = store.exported }
                } footer: {
                    Text("临时校准入口，使用固定合成顺序。旧层级调试数值不参与本次渲染。")
                }
            }
            .navigationTitle("沉浸封面校准")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                while !Task.isCancelled {
                    diagnostic = frames.diagnosticText
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
        }
    }

    private func slider(_ title: String, key: WritableKeyPath<ImmersiveArtworkStyle, Double>,
                        range: ClosedRange<Double>, unit: String, step: Double = 1) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title); Spacer()
                Text("\(store.style[keyPath: key], specifier: "%.2f")\(unit)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { store.style[keyPath: key] }, set: { store.style[keyPath: key] = $0 }),
                   in: range, step: step)
                .accessibilityLabel(title)
        }
    }
}
