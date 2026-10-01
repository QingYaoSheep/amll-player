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
                    Text(model.appleMusicState.connected ? "目录服务：\(error.localizedDescription)" : error.localizedDescription).foregroundStyle(.secondary)
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
                Text("系统歌曲同步与目录服务分别验证。目录请求需要官方开发者令牌；自动令牌要求实际 App ID 配置 MusicKit 服务。令牌失败不再关闭系统歌曲观察。可安装 IPA 或其他应用可同步歌曲，均不能证明本应用的目录请求可用。")
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

    private func checkInstallation() async {
        checking = true
        defer { checking = false }
        let context = model.appleMusicState.contextID
        // Read the system player before catalog requests so token failures cannot
        // hide the result of this independent authorization check.
        let player = SystemMusicPlayer.shared
        let time = player.playbackTime
        var results = [
            "系统当前歌曲：\(player.queue.currentEntry?.title ?? "未读取到歌曲，请先在系统音乐播放")",
            "真实进度：\(time.isFinite ? String(format: "%.2f", time) : "无有效时间") 秒",
        ]
        let store = model.appleCatalog
        do {
            let lists = try await store.page(.collection(.playlists), next: nil)
            results.append("歌单请求通过（本页 \(lists.items.count) 项）")
            let songs = try await store.page(.search("Apple Music", .track), next: nil)
            results.append("搜索请求通过（本页 \(songs.items.count) 项）")
        } catch is CancellationError { return }
        catch { results.append("目录服务：\(error.localizedDescription)") }
        guard !Task.isCancelled, model.appleMusicState.connected,
              context == model.appleMusicState.contextID else { return }
        results.append("外部切歌、暂停、seek 与重签授权需在实际设备验证。")
        diagnostic = results.joined(separator: "\n")
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
