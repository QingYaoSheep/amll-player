import SwiftUI

/// Content metrics belong to browsing, never to the lyric renderer.
enum MusicCatalogLayout {
    static let maximumWidth: CGFloat = 1120
    static func cardWidth(in width: CGFloat, largeText: Bool) -> CGFloat {
        let available = max(1, min(maximumWidth, width) - MusicProductStyle.pageInset * 2)
        return min(largeText ? 280 : 224, max(largeText ? 200 : 145, available * (largeText ? 0.72 : 0.45)))
    }
    static func columns(in width: CGFloat, largeText: Bool) -> Int {
        max(1, Int((max(1, width) + 12) / ((largeText ? 240 : 160) + 12)))
    }
}

enum MusicProductMotion {
    static let feedback = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    static let change = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
}

enum MusicCatalogText {
    /// Service descriptions are text, never rendered HTML or executable content.
    static func description(_ source: String?) -> String? {
        guard var text = source else { return nil }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Touch-down feedback is local to the pressed item; lists never animate in a loop.
struct MusicContentButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(MusicProductMotion.feedback, value: configuration.isPressed)
    }
}

struct MusicFilterPill: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).frame(minHeight: 44)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? MusicProductStyle.accent : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : MusicProductMotion.change, value: selected)
    }
}

struct MusicArtworkPlaySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: Circle())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

struct MusicDetailDescription: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
            if text.count > 100 || text.contains("\n") {
                Button(expanded ? "收起介绍" : "显示完整介绍") { expanded.toggle() }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .buttonStyle(MusicContentButtonStyle())
                    .accessibilityIdentifier("catalogExpandDescription")
            }
        }
    }
}

struct MusicCatalogGrid: View {
    @Bindable var model: AppModel
    let rows: [MusicCatalogRow]
    var onSelect: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 320
    var body: some View {
        let count = MusicCatalogLayout.columns(in: width, largeText: typeSize.isAccessibilitySize)
        let edge = max(1, (width - CGFloat(count - 1) * 12) / CGFloat(count))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count),
                  alignment: .leading, spacing: 24) {
            ForEach(rows) { row in MusicCatalogCard(model: model, row: row, width: edge, onSelect: onSelect) }
        }
        .scrollTargetLayout()
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { measured in
            if measured > 0, abs(width - measured) > 0.5 { width = measured }
        }
    }
}
