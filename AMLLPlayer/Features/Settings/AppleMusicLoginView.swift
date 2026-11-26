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
                    LabeledContent("系统歌曲同步", value: String(localized: "已启用")).settingsSurface()
                    LabeledContent("歌单与搜索", value: catalogStatus).settingsSurface()
                    if state.capabilities.canBrowse {
                        LabeledContent("订阅播放", value: state.capabilities.canPlayCatalog ? String(localized: "可用") : String(localized: "当前订阅不可播放"))
                            .settingsSurface()
                        LabeledContent("云资料库", value: state.capabilities.canModifyLibrary ? String(localized: "已启用") : String(localized: "未启用"))
                            .settingsSurface()
                    }
                    if let region = state.storefront {
                        LabeledContent("地区", value: region.uppercased()).settingsSurface()
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
                    .disabled(isBusy)
                    .accessibilityIdentifier("appleMusicAuthorize")
                }

                if let error = state.error {
                    DisclosureGroup("查看连接错误") {
                        Text(error.localizedDescription).font(.footnote).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .settingsSurface()
                }
                Button { perform(.refresh) } label: {
                    SettingsActionLabel(title: "重新检查状态", icon: "arrow.clockwise", busy: operation == .refresh)
                }
                .disabled(isBusy)

                if !requiresSystemSettings { systemSettingsButton(primary: false) }
                if state.connected {
                    Button(role: .destructive) { model.disconnectAppleMusic() } label: {
                        SettingsActionLabel(title: "断开 Apple Music", icon: "link.badge.minus", style: .destructive)
                    }
                    .disabled(isBusy)
                }
            }
            SettingsSection {
                MusicSourcePicker(model: model).settingsSurface()
                NavigationLink { AppleMusicDiagnosticsView(model: model) } label: {
                    SettingsActionLabel(title: "Apple Music 连接诊断", icon: "stethoscope", navigates: true)
                }
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .animation(reduceMotion ? nil : MusicProductMotion.change, value: state.connected)
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

    private func systemSettingsButton(primary: Bool) -> some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            SettingsActionLabel(title: "打开系统设置", icon: "gearshape", style: primary ? .primary : .secondary)
        }
        .disabled(isBusy)
        .accessibilityIdentifier("appleMusicSystemSettings")
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
        .settingsPickerRow("当前音乐来源")
    }
}
