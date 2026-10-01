import MusicKit
import SwiftUI

struct AppleMusicLoginView: View {
    @Bindable var model: AppModel
    @State private var checking = false
    @State private var diagnostic: String?

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
                    LabeledContent("订阅播放", value: model.appleMusicState.capabilities.canPlayCatalog ? "可用" : "当前订阅不可播放")
                    LabeledContent("云资料库", value: model.appleMusicState.capabilities.canModifyLibrary ? "已启用" : "未启用")
                    Button("断开 Apple Music", role: .destructive) { model.disconnectAppleMusic() }
                }
                if let error = model.appleMusicState.error {
                    Text(error.localizedDescription).foregroundStyle(.secondary)
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
            Section("安装环境验证") {
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "未知")
                Button("验证歌单、搜索及系统歌曲同步") { Task { await checkInstallation() } }
                    .disabled(checking || !model.appleMusicState.connected)
                if checking {
                    ProgressView()
                }
                if let diagnostic {
                    Text(diagnostic).font(.footnote).textSelection(.enabled)
                }
                Text("重签后的显式 App ID 必须启用 MusicKit 服务。可安装 IPA 不代表自动开发者 token 可用；配置异常请联系签名方。播放测试请选择 Apple Music 来源，在搜索结果中手动点击播放。")
                    .font(.footnote).foregroundStyle(.secondary)
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
            return "已连接"
        }
        switch model.appleMusicState.authorization {
        case .denied: return "系统权限被拒绝"
        case .restricted: return "系统权限受限"
        default: return "未连接"
        }
    }

    private func checkInstallation() async {
        checking = true
        defer { checking = false }
        let store = model.appleCatalog
        do {
            let lists = try await store.page(.collection(.playlists), next: nil)
            let songs = try await store.page(.search("Apple Music", .track), next: nil)
            try Task.checkCancellation()
            let player = SystemMusicPlayer.shared
            let time = player.playbackTime
            diagnostic = "歌单请求通过（本页 \(lists.items.count) 项）\n搜索请求通过（本页 \(songs.items.count) 项）\n系统当前歌曲：\(player.queue.currentEntry?.title ?? "未在播放")\n真实进度：\(time.isFinite ? String(format: "%.2f", time) : "无有效时间") 秒\n外部切歌、暂停、seek 与重签授权请在实际设备继续验证。"
        } catch is CancellationError {}
        catch { diagnostic = error.localizedDescription }
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
