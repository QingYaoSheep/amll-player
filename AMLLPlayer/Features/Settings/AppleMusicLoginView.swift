import MusicKit
import SwiftUI

struct AppleMusicLoginView: View {
    @Bindable var model: AppModel
    @State private var operation: Operation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Operation { case connect, refresh }

    var body: some View {
        SettingsPage {
            SettingsAccountHeader(service: .appleMusic, status: status, connected: state.connected)

            if state.connected {
                SettingsSection {
                    SettingsGroup {
                        SettingsInfoRow(title: "系统歌曲同步", value: String(localized: "已启用"), valueColor: MusicProductStyle.accent)
                        SettingsDivider(inset: 16)
                        SettingsInfoRow(title: "歌单与搜索", value: catalogStatus)
                        if state.capabilities.canBrowse {
                            SettingsDivider(inset: 16)
                            SettingsInfoRow(
                                title: "订阅播放",
                                value: state.capabilities.canPlayCatalog ? String(localized: "可用") : String(localized: "当前订阅不可播放")
                            )
                            SettingsDivider(inset: 16)
                            SettingsInfoRow(
                                title: "云资料库",
                                value: state.capabilities.canModifyLibrary ? String(localized: "已启用") : String(localized: "未启用")
                            )
                        }
                        if let region = state.storefront {
                            SettingsDivider(inset: 16)
                            SettingsInfoRow(title: "地区", value: region.uppercased())
                        }
                    }
                }
                .transition(.opacity)
            }

            SettingsSection {
                if requiresSystemSettings {
                    systemSettingsButton(primary: true)
                } else if !state.connected {
                    Button { perform(.connect) } label: {
                        SettingsActionLabel(
                            title: operation == .connect || state.requesting ? "正在授权…" : "连接 Apple Music",
                            icon: "music.note", busy: operation == .connect || state.requesting, style: .primary
                        )
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(isBusy)
                    .accessibilityIdentifier("appleMusicAuthorize")
                }

                SettingsGroup {
                    if let error = state.error {
                        SettingsDisclosureRow(title: "查看连接错误", icon: "exclamationmark.triangle", iconColor: MusicProductStyle.accent) {
                            Text(error.localizedDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }
                        SettingsDivider()
                    }

                    Button { perform(.refresh) } label: {
                        SettingsRowLabel(
                            title: "重新检查状态",
                            icon: "arrow.clockwise",
                            iconColor: MusicProductStyle.accent,
                            busy: operation == .refresh
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .disabled(isBusy)

                    if !requiresSystemSettings {
                        SettingsDivider()
                        systemSettingsButton(primary: false)
                    }

                    if state.connected {
                        SettingsDivider()
                        Button(role: .destructive) { model.disconnectAppleMusic() } label: {
                            SettingsRowLabel(
                                title: "断开 Apple Music",
                                icon: "link.badge.minus",
                                role: .destructive
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .disabled(isBusy)
                    }
                }
            }

            SettingsSection {
                SettingsGroup {
                    MusicSourcePicker(model: model)
                    if AppDiagnosticsVisibility.shared.isUnlocked {
                        SettingsDivider()
                        NavigationLink { AppleMusicDiagnosticsView(model: model) } label: {
                            SettingsRowLabel(
                                title: "Apple Music 连接诊断",
                                icon: "stethoscope",
                                iconColor: MusicServiceID.appleMusic.brandColor,
                                navigates: true
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : SettingsMotion.change, value: state.connected)
        .navigationTitle("登录到 Apple Music")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshAppleMusic() }
    }

    private var state: MusicConnectionState { model.appleMusicState }
    private var isBusy: Bool { operation != nil || state.requesting }
    private var requiresSystemSettings: Bool {
        !state.connected && (state.authorization == .denied || state.authorization == .restricted)
    }

    private var status: String {
        if state.requesting || operation == .connect { return String(localized: "正在授权…") }
        if state.connected { return model.settingsConnectionStatus(.appleMusic) }
        switch state.authorization {
        case .denied: return String(localized: "系统权限被拒绝")
        case .restricted: return String(localized: "系统权限受限")
        default: return String(localized: "未连接")
        }
    }

    private var catalogStatus: String {
        if state.catalogChecking { return String(localized: "正在检查") }
        return state.capabilities.canBrowse ? String(localized: "可用") : String(localized: "暂不可用")
    }

    @ViewBuilder
    private func systemSettingsButton(primary: Bool) -> some View {
        if primary {
            Button(action: openSystemSettings) {
                SettingsActionLabel(title: "打开系统设置", icon: "gearshape", style: .primary)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(isBusy)
            .accessibilityIdentifier("appleMusicSystemSettings")
        } else {
            Button(action: openSystemSettings) {
                SettingsRowLabel(title: "打开系统设置", icon: "gearshape", iconColor: MusicProductStyle.accent)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .disabled(isBusy)
            .accessibilityIdentifier("appleMusicSystemSettings")
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func perform(_ next: Operation) {
        guard !isBusy else { return }
        operation = next
        Task {
            defer { operation = nil }
            switch next {
            case .connect: await model.connectAppleMusic()
            case .refresh: await model.refreshAppleMusic()
            }
        }
    }
}

struct MusicSourcePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker("当前音乐来源", selection: Binding(get: { model.selectedMusicService }, set: { model.selectMusicService($0) })) {
            ForEach(MusicServiceID.allCases) { service in Text(LocalizedStringKey(service.title)).tag(service) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("musicSourcePicker")
        .settingsPickerRow("当前音乐来源", icon: "music.note.list", iconColor: MusicProductStyle.accent)
    }
}
