import MusicKit
import SwiftUI

struct AppleMusicLoginView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Label(status, systemImage: model.appleMusicState.connected ? "checkmark.circle" : "music.note")
                if !model.appleMusicState.connected {
                    Button("登录到 Apple Music") { Task { await model.connectAppleMusic() } }
                        .disabled(model.appleMusicState.requesting)
                        .accessibilityIdentifier("appleMusicAuthorize")
                }
                if model.appleMusicState.requesting {
                    ProgressView("正在授权…")
                }
                if let region = model.appleMusicState.storefront {
                    LabeledContent("地区", value: region.uppercased())
                }
                if model.appleMusicState.connected {
                    LabeledContent("系统歌曲同步", value: "已启用")
                    LabeledContent("歌单与搜索", value: catalogStatus)
                    if model.appleMusicState.capabilities.canBrowse {
                        LabeledContent("订阅播放", value: model.appleMusicState.capabilities.canPlayCatalog ? "可用" : "当前订阅不可播放")
                        LabeledContent("云资料库", value: model.appleMusicState.capabilities.canModifyLibrary ? "已启用" : "未启用")
                    }
                    Text("选择 Apple Music 来源，在系统音乐 App 中播放歌曲，即可检查歌曲及歌词同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("断开 Apple Music", role: .destructive) { model.disconnectAppleMusic() }
                }
                if let error = model.appleMusicState.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.appleMusicState.connected ? "系统歌曲同步可用；歌单与搜索暂不可用。" : "连接未完成，请重新检查状态。")
                        DisclosureGroup("查看技术详情") { Text(error.localizedDescription).textSelection(.enabled) }
                    }.font(.subheadline).foregroundStyle(.secondary)
                }
                Button("重新检查状态") { Task { await model.refreshAppleMusic() } }
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("Apple Music")
            } footer: {
                Text("通过系统授权连接，无需输入 Apple ID 密码。断开仅停止本应用观察，不退出系统账号或撤销系统权限。")
            }
            Section("当前音乐来源") { MusicSourcePicker(model: model) }
            Section {
                NavigationLink("连接诊断与安装帮助") { AppleMusicDiagnosticsView(model: model) }
            }
        }
        .navigationTitle("登录到 Apple Music")
        .task { await model.refreshAppleMusic() }
    }

    private var status: String {
        if model.appleMusicState.requesting {
            return "授权中"
        }
        if model.appleMusicState.connected {
            return model.appleMusicState.capabilities.canBrowse ? "已连接" : "已连接（系统歌曲同步）"
        }
        switch model.appleMusicState.authorization {
        case .denied: return "系统权限被拒绝"
        case .restricted: return "系统权限受限"
        default: return "未连接"
        }
    }

    private var catalogStatus: String {
        if model.appleMusicState.catalogChecking {
            return "正在检查"
        }
        return model.appleMusicState.capabilities.canBrowse ? "可用" : "未能验证"
    }


}

struct MusicSourcePicker: View {
    @Bindable var model: AppModel
    var body: some View {
        Picker("当前音乐来源", selection: Binding(get: { model.selectedMusicService }, set: { model.selectMusicService($0) })) {
            ForEach(MusicServiceID.allCases) { service in Text(service.title).tag(service) }
        }
        .accessibilityIdentifier("musicSourcePicker")
    }
}
