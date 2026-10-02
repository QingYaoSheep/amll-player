import SwiftUI

struct PlaybackSeekDiagnosticsView: View {
    @State private var exportURL: URL?
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                Text("出现跳转不同步后，在这里导出最近的跳转记录。记录包含目标时间、播放器确认、画布时间和行运动，不包含账号、Cookie、播放地址或歌词正文。")
                    .foregroundStyle(.secondary)
                Button("生成诊断文件") {
                    do { exportURL = try PlaybackSeekDiagnostics.shared.export(); failure = nil }
                    catch { failure = "导出失败，请重试。" }
                }
                if let exportURL { ShareLink("分享跳转诊断", item: exportURL) }
                if let failure { Text(failure).foregroundStyle(.secondary) }
                Button("清除诊断记录", role: .destructive) {
                    PlaybackSeekDiagnostics.shared.clear(); exportURL = nil
                }
            }
        }.navigationTitle("播放跳转诊断")
    }
}
