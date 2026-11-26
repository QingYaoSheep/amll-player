import SwiftUI

struct PlaybackSeekDiagnosticsView: View {
    @State private var exportURL: URL?
    @State private var failure: String?
    @State private var confirmClear = false

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsGroup {
                    SettingsTextButton(title: "生成诊断文件", icon: "doc.badge.plus", iconColor: MusicProductStyle.accent, inGroup: true) {
                        do { exportURL = try PlaybackSeekDiagnostics.shared.export(); failure = nil }
                        catch { failure = "导出失败，请重试。" }
                    }
                    if let exportURL {
                        SettingsDivider()
                        ShareLink(item: exportURL) {
                            SettingsRowLabel(title: "分享跳转诊断", icon: "square.and.arrow.up", iconColor: MusicProductStyle.accent)
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "清除诊断记录", icon: "trash", role: .destructive, inGroup: true) {
                        confirmClear = true
                    }
                }
                if let failure {
                    Text(LocalizedStringKey(failure))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }
        }
        .navigationTitle("播放跳转诊断")
        .confirmationDialog("清除诊断记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除诊断记录", role: .destructive) {
                PlaybackSeekDiagnostics.shared.clear()
                exportURL = nil
            }
        }
    }
}
