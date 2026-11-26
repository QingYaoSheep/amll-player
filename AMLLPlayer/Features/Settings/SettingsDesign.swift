import SwiftUI

enum SettingsCorners {
    static let card: CGFloat = 22
    static let hero: CGFloat = 24
    static let button: CGFloat = 16
    static let badge: CGFloat = 8.5
    static let inset: CGFloat = 14

    // Compatibility aliases for callers transitioning to grouped cards.
    static let row: CGFloat = 18
    static let primary: CGFloat = 16
}

enum SettingsMotion {
    static let feedback = MusicProductMotion.feedback
    static let change = MusicProductMotion.change
    /// Critically damped spring for disclosure and layout expansions without overshoot.
    static let disclosure = Animation.spring(response: 0.30, dampingFraction: 1.0)
}

struct SettingsPage<Content: View>: View {
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .frame(maxWidth: 580)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background {
            if quickSettingsNavigation == nil {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .pickerStyle(.menu)
        .toggleStyle(SettingsToggleStyle())
        .tint(MusicProductStyle.accent)
    }
}

struct SettingsSection<Content: View>: View {
    private let title: LocalizedStringKey?
    private let footer: LocalizedStringKey?
    private let content: Content

    init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 12)
            }
            content
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Unified grouped card container for related settings rows.
struct SettingsGroup<Content: View>: View {
    var radius: CGFloat = SettingsCorners.card
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface(radius: radius)
    }
}

struct SettingsDivider: View {
    var inset: CGFloat = 58

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 0.5)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// Tinted soft continuous-corner badge for settings rows.
struct SettingsIconBadge: View {
    let systemImage: String
    var color: Color = MusicProductStyle.accent
    var busy = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation

    var body: some View {
        let usesDarkSurface = colorScheme == .dark || quickSettingsNavigation != nil
        ZStack {
            RoundedRectangle(cornerRadius: SettingsCorners.badge, style: .continuous)
                .fill(color.opacity(usesDarkSurface ? 0.22 : 0.13))
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

/// Instant row press highlight inside a grouped card (never scales a row inside a container).
struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
                    : .clear
            )
            .opacity(isEnabled ? 1 : 0.45)
            .animation(SettingsMotion.feedback, value: configuration.isPressed)
    }
}

/// Subtle tactile press feedback for standalone hero cards and primary buttons.
struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.50)
            .animation(SettingsMotion.feedback, value: configuration.isPressed)
    }
}

struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var iconColor: Color = MusicProductStyle.accent
    var subtitle: String? = nil
    var value: String? = nil
    var navigates = false
    var busy = false
    var role: ButtonRole? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let effectiveColor = role == .destructive ? Color.red : iconColor
        let titleColor = role == .destructive ? Color.red : Color.primary
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))

        HStack(spacing: 12) {
            if let icon {
                SettingsIconBadge(systemImage: icon, color: effectiveColor, busy: busy)
            } else if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(effectiveColor)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(role == .destructive ? .medium : .regular))
                        .foregroundStyle(titleColor)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let value, !value.isEmpty {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .contentTransition(.numericText())
                }
            }
            if navigates {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .contentShape(Rectangle())
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
    var iconColor: Color = MusicProductStyle.accent

    var body: some View {
        Group {
            if style == .primary {
                HStack(spacing: 10) {
                    if busy {
                        ProgressView().tint(.white)
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: icon)
                            .font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    Text(title).font(.body.weight(.semibold))
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 16)
                .background(
                    MusicProductStyle.filledAccent,
                    in: RoundedRectangle(cornerRadius: SettingsCorners.button, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: SettingsCorners.button, style: .continuous))
            } else {
                SettingsRowLabel(
                    title: title,
                    icon: icon,
                    iconColor: iconColor,
                    subtitle: detail,
                    navigates: navigates,
                    busy: busy,
                    role: style == .destructive ? .destructive : nil
                )
                .settingsCardSurface(radius: SettingsCorners.card)
            }
        }
    }
}

struct SettingsIconToggleLabel: View {
    let title: LocalizedStringKey
    let icon: String
    var color: Color = MusicProductStyle.accent

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(systemImage: icon, color: color)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
        }
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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
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
    var iconColor: Color = MusicProductStyle.accent
    var inGroup = false
    let action: () -> Void

    var body: some View {
        if inGroup {
            Button(role: role, action: action) {
                SettingsRowLabel(title: title, icon: icon, iconColor: iconColor, role: role)
            }
            .buttonStyle(SettingsRowButtonStyle())
        } else {
            Button(role: role, action: action) {
                SettingsActionLabel(
                    title: title,
                    icon: icon,
                    style: role == .destructive ? .destructive : .secondary,
                    iconColor: iconColor
                )
            }
            .buttonStyle(SettingsButtonStyle())
        }
    }
}

struct SettingsInfoRow: View {
    let title: LocalizedStringKey
    let value: String
    var icon: String? = nil
    var iconColor: Color = MusicProductStyle.accent
    var valueColor: Color = .secondary
    var monospacedValue = false
    var selectable = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize || monospacedValue
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))

        HStack(spacing: 12) {
            if let icon {
                SettingsIconBadge(systemImage: icon, color: iconColor)
            }
            layout {
                Text(title)
                    .font(monospacedValue ? .subheadline.weight(.medium) : .body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
                if !stacked { Spacer(minLength: 8) }
                valueView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }

    @ViewBuilder private var valueView: some View {
        let base = Text(value)
            .font(monospacedValue ? .footnote.monospaced() : .subheadline)
            .foregroundStyle(valueColor)
            .monospacedDigit()
            .contentTransition(.numericText())
        if selectable {
            base.textSelection(.enabled)
        } else {
            base
        }
    }
}

struct SettingsSliderRow: View {
    private let titleText: Text
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var disabled = false
    var sliderIdentifier: String? = nil
    var readoutIdentifier: String? = nil

    init(_ title: LocalizedStringKey, valueText: String, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double = 1, disabled: Bool = false, sliderIdentifier: String? = nil, readoutIdentifier: String? = nil)
    {
        self.titleText = Text(title)
        self.valueText = valueText
        self._value = value
        self.range = range
        self.step = step
        self.disabled = disabled
        self.sliderIdentifier = sliderIdentifier
        self.readoutIdentifier = readoutIdentifier
    }

    init(verbatim title: String, valueText: String, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double = 1, disabled: Bool = false, sliderIdentifier: String? = nil, readoutIdentifier: String? = nil)
    {
        self.titleText = Text(title)
        self.valueText = valueText
        self._value = value
        self.range = range
        self.step = step
        self.disabled = disabled
        self.sliderIdentifier = sliderIdentifier
        self.readoutIdentifier = readoutIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                titleText
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                readoutView
            }
            sliderView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(disabled ? 0.45 : 1)
    }

    @ViewBuilder private var readoutView: some View {
        let pill = Text(valueText)
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
        if let readoutIdentifier {
            pill.accessibilityIdentifier(readoutIdentifier)
        } else {
            pill
        }
    }

    @ViewBuilder private var sliderView: some View {
        let base = Slider(value: $value, in: range, step: step)
            .disabled(disabled)
            .accessibilityLabel(titleText)
            .accessibilityValue(Text(valueText))
        if let sliderIdentifier {
            base.accessibilityIdentifier(sliderIdentifier)
        } else {
            base
        }
    }
}

struct SettingsDisclosureRow<Content: View>: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var iconColor: Color = MusicProductStyle.accent
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : SettingsMotion.disclosure) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    if let icon {
                        SettingsIconBadge(systemImage: icon, color: iconColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
            .accessibilityValue(Text(LocalizedStringKey(isExpanded ? "settings.disclosure.expanded" : "settings.disclosure.collapsed")))

            if isExpanded {
                VStack(spacing: 0) {
                    SettingsDivider(inset: icon == nil ? 16 : 58)
                    content
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }
}

struct SettingsAccountHeader: View {
    let service: MusicServiceID
    var name: String? = nil
    var avatar: URL? = nil
    let status: String
    var connected = false
    var action: LocalizedStringKey? = nil
    var showsChevron = false
    var serviceStatuses: [(MusicServiceID, Bool)]? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let avatar {
                    CatalogArtwork(url: avatar, size: 56, isArtist: true)
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [service.brandColor.opacity(0.24), service.brandColor.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: service.settingsIcon)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(service.brandColor)
                    }
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let name, !name.isEmpty {
                        Text(name)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(LocalizedStringKey(service.title))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(LocalizedStringKey(service.title))
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 5) {
                        Circle()
                            .fill(connected ? MusicProductStyle.accent : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(connected ? .primary : .secondary)
                            .contentTransition(.opacity)
                            .animation(SettingsMotion.change, value: status)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        connected ? MusicProductStyle.accent.opacity(0.16) : Color.primary.opacity(0.06),
                        in: Capsule()
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(16)

            if let serviceStatuses, !serviceStatuses.isEmpty {
                SettingsDivider(inset: 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(serviceStatuses, id: \.0.id) { itemService, itemConnected in
                            let selected = itemService == service
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(itemConnected ? itemService.brandColor : Color.secondary.opacity(0.35))
                                    .frame(width: 6, height: 6)
                                Text(LocalizedStringKey(itemService.title))
                                    .font(.caption.weight(selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selected ? itemService.brandColor.opacity(0.12) : Color.primary.opacity(0.045),
                                in: Capsule()
                            )
                            .overlay {
                                if selected {
                                    Capsule().strokeBorder(itemService.brandColor.opacity(0.35), lineWidth: 0.75)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            } else if let action {
                SettingsDivider(inset: 16)
                HStack {
                    Text(action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MusicProductStyle.accent)
                    Spacer()
                    Image(systemName: "arrow.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MusicProductStyle.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface(radius: SettingsCorners.hero)
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

    var brandColor: Color {
        MusicProductStyle.accent
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
    func settingsCardSurface(radius: CGFloat = SettingsCorners.card) -> some View {
        modifier(SettingsCardSurface(radius: radius))
    }

    func settingsSurface(prominent: Bool = false, padded: Bool = true, radius: CGFloat = SettingsCorners.card) -> some View {
        modifier(SettingsSurface(prominent: prominent, padded: padded, radius: radius))
    }

    func settingsPickerRow(_ title: LocalizedStringKey, icon: String? = nil, iconColor: Color = MusicProductStyle.accent) -> some View {
        modifier(SettingsPickerRow(title: title, icon: icon, iconColor: iconColor))
    }
}

private struct SettingsPickerRow: ViewModifier {
    let title: LocalizedStringKey
    var icon: String? = nil
    var iconColor: Color = MusicProductStyle.accent
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        HStack(spacing: 12) {
            if let icon {
                SettingsIconBadge(systemImage: icon, color: iconColor)
            }
            layout {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                content.labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

private struct SettingsCardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .contentShape(shape)
    }

    private var fill: Color {
        if quickSettingsNavigation != nil {
            return reduceTransparency ? Color(uiColor: .secondarySystemBackground) : .white.opacity(0.09)
        }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var borderColor: Color {
        if contrast == .increased {
            return Color.primary.opacity(0.28)
        }
        if quickSettingsNavigation != nil || colorScheme == .dark {
            return .white.opacity(0.09)
        }
        return .black.opacity(0.05)
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
            .padding(.horizontal, padded ? 16 : 0)
            .padding(.vertical, padded ? 11 : 0)
            .frame(maxWidth: .infinity, minHeight: prominent ? 52 : 48, alignment: .leading)
            .background(fill, in: shape)
            .clipShape(shape)
            .contentShape(shape)
    }

    private var fill: Color {
        if prominent { return MusicProductStyle.filledAccent }
        if quickSettingsNavigation != nil, !reduceTransparency { return .white.opacity(0.09) }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }
}
