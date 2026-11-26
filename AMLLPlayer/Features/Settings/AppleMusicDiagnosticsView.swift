import MusicKit
import SwiftUI

struct AppleMusicDiagnosticsView: View {
    @Bindable var model: AppModel
    @State private var checking = false
    @State private var diagnostic: String?
    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsGroup {
                    SettingsInfoRow(
                        title: "Bundle ID",
                        value: Bundle.main.bundleIdentifier ?? String(localized: "未知"),
                        monospacedValue: true,
                        selectable: true
                    )
                }

                if model.appleMusicState.connected {
                    Button {
                        Task { await checkInstallation() }
                    } label: {
                        SettingsActionLabel(title: "检查 Apple Music 连接", icon: "stethoscope", busy: checking, style: .primary)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(checking)
                } else {
                    SettingsGroup {
                        NavigationLink { AppleMusicLoginView(model: model) } label: {
                            SettingsRowLabel(
                                title: "连接 Apple Music",
                                icon: "music.note",
                                iconColor: MusicServiceID.appleMusic.brandColor,
                                navigates: true
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                }

                if let diagnostic {
                    SettingsGroup {
                        Text(diagnostic)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
        }
        .navigationTitle("Apple Music 连接诊断")
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
        diagnostic = results.joined(separator: "\n")
    }
}
