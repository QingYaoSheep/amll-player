import Observation
import SwiftUI

/// Temporary, independent tuning storage. Removing this file does not migrate lyric preferences.
enum ImmersiveArtworkLayer: String, CaseIterable, Identifiable, Codable {
    case background, dimming, video, reflection, transition, bottomFade
    var id: String { rawValue }
    var title: String {
        switch self {
        case .background: "全页背景"
        case .dimming: "背景暗度蒙层"
        case .video: "完整视频"
        case .reflection: "封面倒影（无额外模糊）"
        case .transition: "渐变模糊过渡"
        case .bottomFade: "最上层底部渐隐"
        }
    }
}

struct ImmersiveArtworkLayerAdjustment: Codable, Equatable {
    var enabled = true
    var x = 0.0
    var y = 0.0
    var width = 1.0
    var height = 1.0
    var opacity = 1.0

    func frame(_ original: CGRect) -> CGRect {
        CGRect(x: original.midX + x - original.width * width / 2,
               y: original.midY + y - original.height * height / 2,
               width: original.width * width, height: original.height * height)
    }

    func validated() -> Self {
        var value = self
        func finite(_ value: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        value.x = finite(x, 0, -1200 ... 1200)
        value.y = finite(y, 0, -1200 ... 1200)
        value.width = finite(width, 1, 0.1 ... 2)
        value.height = finite(height, 1, 0.1 ... 2)
        value.opacity = finite(opacity, 1, 0 ... 1)
        return value
    }
}

struct ImmersiveArtworkDebugConfiguration: Codable, Equatable {
    var layers: [String: ImmersiveArtworkLayerAdjustment] = [:]
    var blurRadius = 32.0

    subscript(_ layer: ImmersiveArtworkLayer) -> ImmersiveArtworkLayerAdjustment {
        get {
            var fallback = ImmersiveArtworkLayerAdjustment()
            if layer == .reflection { fallback.opacity = 0.32 }
            if layer == .dimming { fallback.opacity = 0.16 }
            return (layers[layer.rawValue] ?? fallback).validated()
        }
        set { layers[layer.rawValue] = newValue.validated() }
    }
    var validatedBlur: Double { blurRadius.isFinite ? min(80, max(0, blurRadius)) : 32 }
}

@MainActor @Observable
final class ImmersiveArtworkDebugStore {
    static let shared = ImmersiveArtworkDebugStore()
    private static let key = "AMLL.temporaryImmersiveLayerTuning.v1"
    var configuration: ImmersiveArtworkDebugConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }
    private init() {
        configuration = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ImmersiveArtworkDebugConfiguration.self, from: $0) } ?? .init()
    }
    func reset() { configuration = .init() }
    var exportedValues: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var complete = configuration
        for layer in ImmersiveArtworkLayer.allCases { complete[layer] = configuration[layer] }
        return (try? encoder.encode(complete)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct ImmersiveArtworkDebugPanel: View {
    @State private var store = ImmersiveArtworkDebugStore.shared
    @Environment(\.dismiss) private var dismiss
    var viewport: CGSize = .zero
    var video: CGRect = .zero
    var backgroundDimming: Double = 0.16

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("临时调试：背景＋暗度 → 视频＋倒影 → 渐变模糊 → 底部渐隐。前景文字与控件不参与这些调节。")
                        .font(.footnote)
                    if viewport.width > 0 {
                        Text("视口 \(Int(viewport.width)) × \(Int(viewport.height)) pt；视频底边 \(video.maxY, specifier: "%.1f") pt")
                            .font(.caption).monospacedDigit()
                    }
                    Text("位置为相对默认位置的 pt 偏移；宽高为默认尺寸的倍数。视频在调整后的容器内始终等比完整显示，倒影与模糊自动对齐实际画面。倒影开关还需开启原有封面倒影设置。底部渐隐的不透明度表示渐隐强度。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(ImmersiveArtworkLayer.allCases) { layer in
                    Section(layer.title) {
                        Toggle("显示此层", isOn: binding(layer, \.enabled))
                        slider("水平位置", value: binding(layer, \.x), range: -1200 ... 1200, step: 1, unit: "pt")
                        slider("纵向位置", value: binding(layer, \.y), range: -1200 ... 1200, step: 1, unit: "pt")
                        slider("宽度", value: binding(layer, \.width), range: 0.1 ... 2, step: 0.01, unit: "×")
                        slider("高度", value: binding(layer, \.height), range: 0.1 ... 2, step: 0.01, unit: "×")
                        slider(layer == .bottomFade ? "渐隐强度" : "不透明度", value: binding(layer, \.opacity), range: 0 ... 1, step: 0.01, unit: "")
                        if layer == .transition {
                            slider("最大模糊半径", value: Binding(get: { store.configuration.validatedBlur }, set: { store.configuration.blurRadius = $0 }), range: 0 ... 80, step: 1, unit: "pt")
                        }
                        Button("重置此层") { store.configuration.layers.removeValue(forKey: layer.rawValue) }
                    }
                }
                Section {
                    Button("复制全部调试数值") { UIPasteboard.general.string = store.exportedValues }
                    ShareLink("导出调试数值", item: store.exportedValues)
                    Button("恢复全部调试默认值") { store.reset() }
                } footer: {
                    Text("数值仅用于沉浸封面，独立保存。调整满意后复制发给开发者，再固化参数并删除本面板。")
                }
            }
            .navigationTitle("沉浸封面层级调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func binding<T>(_ layer: ImmersiveArtworkLayer, _ key: WritableKeyPath<ImmersiveArtworkLayerAdjustment, T>) -> Binding<T> {
        Binding(get: { adjustment(layer)[keyPath: key] }, set: { value in
            var adjustment = adjustment(layer)
            adjustment[keyPath: key] = value
            store.configuration[layer] = adjustment
        })
    }

    private func adjustment(_ layer: ImmersiveArtworkLayer) -> ImmersiveArtworkLayerAdjustment {
        var value = store.configuration[layer]
        if layer == .dimming, store.configuration.layers[layer.rawValue] == nil { value.opacity = backgroundDimming }
        return value
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.2f")\(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

/// Applied last to the media group, never to the background or foreground controls.
struct ImmersiveArtworkBottomFade: View {
    let frame: CGRect
    let strength: Double
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            context.blendMode = .destinationOut
            let colors = AMLLImmersiveArtworkGeometry.bottomFadeStops.map {
                Gradient.Stop(color: .white.opacity((1 - $0.alpha) * strength), location: CGFloat($0.location))
            }
            context.fill(Path(frame), with: .linearGradient(Gradient(stops: colors),
                startPoint: CGPoint(x: frame.midX, y: frame.minY), endPoint: CGPoint(x: frame.midX, y: frame.maxY)))
            if frame.maxY < size.height {
                context.fill(Path(CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: size.height - frame.maxY)), with: .color(.white.opacity(strength)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
