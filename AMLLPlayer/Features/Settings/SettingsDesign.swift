import SwiftUI

enum SettingsCorners {
    static let row: CGFloat = 26
    static let primary: CGFloat = 30
    static let card: CGFloat = 38
    static let inset: CGFloat = 20
}

struct SettingsPage<Content: View>: View {
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background {
            if quickSettingsNavigation == nil { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
        }
        .scrollDismissesKeyboard(.interactively)
        .pickerStyle(.menu)
        .toggleStyle(SettingsToggleStyle())
        .tint(MusicProductStyle.accent)
    }
}

struct SettingsSection<Content: View>: View {
    private let title: LocalizedStringKey?
    private let content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 4)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsActionLabel: View {
    enum Style { case secondary, primary, destructive }

    let title: LocalizedStringKey
    var icon: String
    var detail: String? = nil
    var navigates = false
    var busy = false
    var style: Style = .secondary

    var body: some View {
        HStack(spacing: 12) {
            if busy {
                ProgressView().tint(style == .primary ? .white : MusicProductStyle.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if navigates {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(style == .primary ? Color.white : style == .destructive ? Color.red : Color.primary)
        .settingsSurface(prominent: style == .primary, radius: style == .primary ? SettingsCorners.primary : SettingsCorners.row)
    }

    private var iconColor: Color {
        if style == .primary { return .white }
        if style == .destructive { return .red }
        return MusicProductStyle.accent
    }
}

struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.55)
            .animation(MusicProductMotion.feedback, value: configuration.isPressed)
    }
}

private struct SettingsToggleStyle: ToggleStyle {
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        Button { configuration.isOn.toggle() } label: {
            layout {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: configuration.$isOn) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .fixedSize()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

struct SettingsTextButton: View {
    let title: LocalizedStringKey
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            SettingsActionLabel(title: title, icon: icon, style: role == .destructive ? .destructive : .secondary)
        }
        .buttonStyle(SettingsButtonStyle())
    }
}

struct SettingsAccountHeader: View {
    let service: MusicServiceID
    var name: String? = nil
    var avatar: URL? = nil
    let status: String
    var connected = false
    var action: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let avatar {
                CatalogArtwork(url: avatar, size: 52, isArtist: true)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: service.settingsIcon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MusicProductStyle.accent)
                    .frame(width: 52, height: 52)
                    .background(MusicProductStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: SettingsCorners.inset, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let name, !name.isEmpty {
                    Text(name).font(.title2.bold())
                    Text(LocalizedStringKey(service.title)).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(LocalizedStringKey(service.title)).font(.title2.bold())
                }
                Label(status, systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(MusicProductMotion.change, value: status)
            }
            if let action {
                Label(action, systemImage: "arrow.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MusicProductStyle.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .settingsSurface(padded: false, radius: SettingsCorners.card)
    }
}

extension MusicServiceID {
    var settingsIcon: String {
        switch self {
        case .spotify: "dot.radiowaves.left.and.right"
        case .appleMusic: "music.note"
        case .netease: "music.note.house"
        }
    }
}

extension AppModel {
    func settingsConnectionStatus(_ service: MusicServiceID) -> String {
        if service == .appleMusic, appleMusicState.connected, !appleMusicState.capabilities.canBrowse {
            return String(localized: "已连接 · 系统歌曲同步")
        }
        return isConnected(to: service) ? String(localized: "settings.connected") : String(localized: "未连接")
    }
}

extension View {
    func settingsSurface(prominent: Bool = false, padded: Bool = true, radius: CGFloat = SettingsCorners.row) -> some View {
        modifier(SettingsSurface(prominent: prominent, padded: padded, radius: radius))
    }

    func settingsPickerRow(_ title: LocalizedStringKey) -> some View {
        modifier(SettingsPickerRow(title: title))
    }
}

private struct SettingsPickerRow: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).accessibilityHidden(true)
            content.labelsHidden()
        }
        .frame(minHeight: 44)
    }
}

private struct SettingsSurface: ViewModifier {
    let prominent: Bool
    let padded: Bool
    let radius: CGFloat
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(.horizontal, padded ? 14 : 0)
            .padding(.vertical, padded ? 10 : 0)
            .frame(maxWidth: .infinity, minHeight: prominent ? 60 : 52, alignment: .leading)
            .background(fill, in: shape)
            .contentShape(shape)
    }

    private var fill: Color {
        if prominent { return MusicProductStyle.filledAccent }
        if quickSettingsNavigation != nil, !reduceTransparency { return .white.opacity(0.10) }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }
}
