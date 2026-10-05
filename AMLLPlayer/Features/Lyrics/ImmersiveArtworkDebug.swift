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
        case .bottomFade: "底部渐隐"
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
    /// Top to bottom, matching the editor's visible order. Optional for old saved tuning.
    var order: [ImmersiveArtworkLayer]?
    /// Optional so existing calibration is retained when upgrading.
    var topFeatherLength: Double?

    private enum CodingKeys: String, CodingKey {
        case layers, blurRadius, order, topFeatherLength
    }

    var orderedLayers: [ImmersiveArtworkLayer] {
        var result: [ImmersiveArtworkLayer] = []
        for layer in (order ?? Array(ImmersiveArtworkLayer.allCases.reversed())) where !result.contains(layer) {
            result.append(layer)
        }
        for layer in ImmersiveArtworkLayer.allCases.reversed() where !result.contains(layer) { result.append(layer) }
        return result
    }

    func isBelow(_ layer: ImmersiveArtworkLayer, _ other: ImmersiveArtworkLayer) -> Bool {
        orderedLayers.firstIndex(of: layer)! > orderedLayers.firstIndex(of: other)!
    }

    mutating func moveLayers(fromOffsets: IndexSet, toOffset: Int) {
        var updated = orderedLayers
        updated.move(fromOffsets: fromOffsets, toOffset: toOffset)
        order = updated
    }

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
    var validatedTopFeatherLength: Double {
        guard let value = topFeatherLength, value.isFinite else { return 24 }
        return min(80, max(0, value))
    }

    mutating func resetLayer(_ layer: ImmersiveArtworkLayer) {
        layers.removeValue(forKey: layer.rawValue)
        if layer == .transition { topFeatherLength = nil }
    }
}

extension ImmersiveArtworkDebugConfiguration {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layers = try values.decodeIfPresent([String: ImmersiveArtworkLayerAdjustment].self, forKey: .layers) ?? [:]
        blurRadius = try values.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 32
        order = try values.decodeIfPresent([ImmersiveArtworkLayer].self, forKey: .order)
        // A malformed new field cannot discard otherwise valid layer tuning.
        topFeatherLength = try? values.decode(Double.self, forKey: .topFeatherLength)
    }
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
    func exportedValues(backgroundDimming: Double) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var complete = configuration
        if complete.layers[ImmersiveArtworkLayer.dimming.rawValue] == nil {
            var dimming = complete[.dimming]
            dimming.opacity = backgroundDimming
            complete[.dimming] = dimming
        }
        for layer in ImmersiveArtworkLayer.allCases { complete[layer] = complete[layer] }
        complete.order = complete.orderedLayers
        complete.topFeatherLength = complete.validatedTopFeatherLength
        return (try? encoder.encode(complete)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct ImmersiveArtworkDebugPanel: View {
    @State private var store = ImmersiveArtworkDebugStore.shared
    @Environment(\.dismiss) private var dismiss
    var viewport: CGSize = .zero
    var video: CGRect = .zero
    var backgroundDimming: Double = 0.16
    var frames: ArtworkReflectionFrames? = nil
    @State private var frameDiagnostic = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("临时调试：可调整下方所有层的顺序。前景文字与控件不参与这些调节。")
                        .font(.footnote)
                    if viewport.width > 0 {
                        Text("视口 \(Int(viewport.width)) × \(Int(viewport.height)) pt；视频底边 \(video.maxY, specifier: "%.1f") pt")
                            .font(.caption).monospacedDigit()
                    }
                    Text("位置为相对默认位置的 pt 偏移；宽高为默认尺寸的倍数，模糊层的纵向参数只调整上方渐变。视频在调整后的容器内始终等比完整显示。倒影开关还需开启原有封面倒影设置。底部渐隐的不透明度表示渐隐强度。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("独立模糊层实时处理它下方所有可见内容，底部保持完整模糊，向上减小模糊半径。顶部短距离另做透明羽化：最上沿透明，向下恢复整层混合比例，消除与原画面的硬分界。不叠加材质底色或暗度；羽化长度独立于半径和过渡高度，设为 0 可关闭。纯背景模糊不做顶部羽化。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(store.configuration.orderedLayers) { layer in Text(layer.title) }
                        .onMove { from, to in store.configuration.moveLayers(fromOffsets: from, toOffset: to) }
                } header: { Text("层级顺序（最上层 → 最下层）") } footer: {
                    Text("点击编辑后拖动排序，与歌词来源顺序使用相同控件。上移提高层级；实时模糊只作用于它下方可见的内容。底部渐隐只作用于它下方的视频和倒影，背景模糊持续到屏幕底边。")
                }
                if frames != nil {
                    Section("倒影实时诊断") {
                        Text(frameDiagnostic).font(.caption).monospacedDigit()
                        Button("复制倒影诊断") { UIPasteboard.general.string = frameDiagnostic }
                    }
                    .task {
                        while !Task.isCancelled {
                            frameDiagnostic = frames?.diagnosticText ?? ""
                            do { try await Task.sleep(for: .milliseconds(500)) }
                            catch { return }
                        }
                    }
                }
                ForEach(ImmersiveArtworkLayer.allCases) { layer in
                    Section(layer.title) {
                        Toggle("显示此层", isOn: binding(layer, \.enabled))
                        slider("水平位置", value: binding(layer, \.x), range: -1200 ... 1200, step: 1, unit: "pt")
                        slider(layer == .transition ? "上沿偏移" : "纵向位置", value: binding(layer, \.y), range: -1200 ... 1200, step: 1, unit: "pt")
                        slider("宽度", value: binding(layer, \.width), range: 0.1 ... 2, step: 0.01, unit: "×")
                        slider(layer == .transition ? "向上渐变长度" : "高度", value: binding(layer, \.height), range: 0.1 ... 2, step: 0.01, unit: "×")
                        slider(layer == .bottomFade ? "渐隐强度" : "不透明度", value: binding(layer, \.opacity), range: 0 ... 1, step: 0.01, unit: "")
                        if layer == .transition {
                            slider("实时模糊强度", value: Binding(get: { store.configuration.validatedBlur }, set: { store.configuration.blurRadius = $0 }), range: 0 ... 80, step: 1, unit: "pt")
                            slider("顶部透明羽化长度", value: Binding(get: { store.configuration.validatedTopFeatherLength }, set: { store.configuration.topFeatherLength = $0 }), range: 0 ... 80, step: 1, unit: "pt")
                        }
                        Button("重置此层") { store.configuration.resetLayer(layer) }
                    }
                }
                Section {
                    Button("复制全部调试数值") { UIPasteboard.general.string = store.exportedValues(backgroundDimming: backgroundDimming) }
                    ShareLink("导出调试数值", item: store.exportedValues(backgroundDimming: backgroundDimming))
                    Button("恢复全部调试默认值") { store.reset() }
                } footer: {
                    Text("数值仅用于沉浸封面，独立保存。调整满意后复制发给开发者，再固化参数并删除本面板。")
                }
            }
            .navigationTitle("沉浸封面层级调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
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
