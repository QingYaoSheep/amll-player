import SwiftUI

struct PlaybackSeekDiagnosticsView: View {
    @State private var exportURL: URL?
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                Text("跳转后出现不同步时，可以在这里导出最近的跳转记录。记录会保存目标时间和播放器确认结果，也会记下歌词画布上的时间与歌词行的移动。不包含账号、Cookie、播放地址或歌词正文。")
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
