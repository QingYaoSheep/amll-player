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
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 58)).padding(.top, 24)
                Spacer(minLength: 30)
                Text("私人 FM").font(.title.bold())
                Text(model.netEasePlayback.isStartingRadio ? "正在准备音乐…" : model.netEasePlayback.isPersonalFM ? "继续收听，为你自动续播" : "从一首喜欢的歌，听见更多惊喜")
                    .font(.subheadline)
                Label(model.netEasePlayback.isPersonalFM ? "继续收听" : "开始收听", systemImage: "play.fill").font(.headline)
            }.foregroundStyle(.white).padding(20).frame(width: width, alignment: .leading)
                .frame(minHeight: width * 4 / 3)
                .background(LinearGradient(colors: [.red, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
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
