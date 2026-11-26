import SwiftUI

struct MusicHomeFMCard: View {
    @Bindable var model: AppModel
    let width: CGFloat
    let openPlayer: () -> Void
    @State private var failure: String?
    var body: some View {
        Button {
            if model.netEasePlayback.isPersonalFM, model.playbackSnapshot?.isPlaying == true { openPlayer(); return }
            let context = model.catalog.identity
            Task {
                do {
                    try await model.netEasePlayback.startPersonalFM()
                    if model.selectedMusicService == .netease, context == model.catalog.identity { openPlayer() }
                } catch is CancellationError {} catch { failure = error.localizedDescription }
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 82, height: 82)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 42, weight: .semibold))
                }
                .padding(.top, 18)
                Spacer(minLength: 24)
                Text("私人 FM").font(.title.bold())
                Text(model.netEasePlayback.isStartingRadio ? "正在准备音乐…" : model.netEasePlayback.isPersonalFM ? "继续收听，为你自动续播" : "从一首喜欢的歌，听见更多惊喜")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                Label(model.netEasePlayback.isPersonalFM ? "继续收听" : "开始收听", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.22), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: MusicHomeLayout.featuredHeight(for: width))
            .background(
                LinearGradient(
                    colors: [
                        MusicProductStyle.accent,
                        MusicProductStyle.filledAccent,
                        Color(red: 0.16, green: 0.03, blue: 0.06),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }.buttonStyle(MusicContentButtonStyle()).disabled(model.netEasePlayback.isStartingRadio)
            .accessibilityIdentifier("homePersonalFM")
            .contextMenu {
                if model.netEasePlayback.isPersonalFM {
                    Button("退出 FM，恢复普通队列") { model.netEasePlayback.exitPersonalFM() }
                }
            }
            .alert("私人 FM 暂不可用", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
                if model.netEasePlayback.isPersonalFM { Button("恢复普通队列") { model.netEasePlayback.exitPersonalFM() } }
            } message: { Text(failure ?? "") }
    }
}
