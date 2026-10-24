import Foundation

/// Stored values from the source preset matcher. UI indices are deliberately
/// kept out of the renderer: the source swaps indices only in its settings UI.
struct LyricsBlossomAnimationOptions: Codable, Equatable, Sendable {
    enum Control: String, CaseIterable {
        case background, word, scale, emphasis, selection

        var title: String {
            switch self {
            case .background: "背景歌词"
            case .word: "逐词歌词动画"
            case .scale: "缩放动画"
            case .emphasis: "强调词动画"
            case .selection: "选择句逻辑"
            }
        }

        var key: WritableKeyPath<LyricsBlossomAnimationOptions, Int> {
            switch self {
            case .background: \.background
            case .word: \.word
            case .scale: \.scale
            case .emphasis: \.emphasis
            case .selection: \.selection
            }
        }

        var help: String {
            switch self {
            case .background: "背景人声随主歌词进入焦点时的呈现方式。"
            case .word: "逐词歌词点亮与取消时的外观过渡。"
            case .scale: "歌词获取与离开焦点时的缩放效果。"
            case .emphasis: "长音、强调词及其结束阶段的动画。"
            case .selection: "选择句子的规则；27 逻辑不限制同时高亮行数。"
            }
        }

        var choices: [(value: Int, title: String)] {
            switch self {
            case .background: [(0, "16"), (1, "26")]
            case .word: [(0, "16.4"), (1, "26.4"), (2, "27"), (3, "27 预设")]
            case .scale: [(1, "16.4"), (2, "26.4")]
            case .emphasis: [(0, "16.4"), (1, "26.4")]
            case .selection: [(3, "16.4"), (0, "16.4 advance"), (2, "27")]
            }
        }
    }

    enum Preset: Int, CaseIterable, Identifiable {
        case appleMusic164 = 4, advance = 0, appleMusic264 = 1, appleMusic27 = 2, custom = 3
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .appleMusic164: "16.4"
            case .advance: "16.4 advance"
            case .appleMusic264: "26.4"
            case .appleMusic27: "27"
            case .custom: "自定义"
            }
        }
    }

    var background = 0
    var scale = 1
    var word = 0
    var emphasis = 0
    var selection = 3
    var maximum = 0

    init() {}
    private enum CodingKeys: String, CodingKey { case background, scale, word, emphasis, selection, maximum }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        background = try values.decodeIfPresent(Int.self, forKey: .background) ?? 0
        scale = try values.decodeIfPresent(Int.self, forKey: .scale) ?? 1
        word = try values.decodeIfPresent(Int.self, forKey: .word) ?? 0
        emphasis = try values.decodeIfPresent(Int.self, forKey: .emphasis) ?? 0
        selection = try values.decodeIfPresent(Int.self, forKey: .selection) ?? 3
        maximum = try values.decodeIfPresent(Int.self, forKey: .maximum) ?? 0
    }

    // [preset ID, get(9), get(10), get(0x1e), get(0x1f), get(0x20), get(0x22)].
    // The final two IDs are selection logic and the 2/3-line stepper respectively,
    // established by their decoded labels and real renderer consumers.
    static let sourceTable = [
        [0, 0, 1, 0, 0, 0, 0], [1, 1, 2, 1, 1, 2, 0],
        [2, 1, 2, 3, 1, 2, 0], [4, 0, 1, 0, 0, 3, 0],
    ]

    var matchedPreset: Preset {
        let fields = [background, scale, word, emphasis, selection, maximum]
        return Self.sourceTable.first(where: { Array($0.dropFirst()) == fields })
            .flatMap { Preset(rawValue: $0[0]) } ?? .custom
    }

    var maximumLines: Int {
        get { maximum > 0 ? 3 : 2 }
        set { maximum = newValue > 2 ? 1 : 0 }
    }
    var limitsSelection: Bool { selection != 2 }

    /// FUN_1402fb4f0 initializes a 0.25s release for the newer emphasis family;
    /// FUN_1402fc010 multiplies scale/offset residuals by remaining/new duration.
    func emphasisReleaseWeight(lineTime: Double, wordEnd: Double, reverseElapsed: Double) -> Double {
        guard emphasis == 1 else { return 1 }
        let elapsed = max(0, lineTime - wordEnd) + max(0, reverseElapsed)
        return max(0, 1 - elapsed / 0.25)
    }

    mutating func apply(_ preset: Preset) {
        guard let row = Self.sourceTable.first(where: { $0[0] == preset.rawValue }) else { return }
        background = row[1]; scale = row[2]; word = row[3]
        emphasis = row[4]; selection = row[5]; maximum = row[6]
    }

    func validated() -> Self {
        var copy = self
        if copy.selection == 1 { copy.selection = 2 }
        for control in Control.allCases where !control.choices.contains(where: { $0.value == copy[keyPath: control.key] }) {
            copy[keyPath: control.key] = Self()[keyPath: control.key]
        }
        copy.maximum = maximum > 0 ? 1 : 0
        return copy
    }
}
