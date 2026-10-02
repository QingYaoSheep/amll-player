import MusicKit
import SwiftUI

struct AppleMusicDiagnosticsView: View {
    @Bindable var model: AppModel
    @State private var checking = false
    @State private var diagnostic: String?
    var body: some View {
        Form {
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
        }.navigationTitle("Apple Music 连接诊断")
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
