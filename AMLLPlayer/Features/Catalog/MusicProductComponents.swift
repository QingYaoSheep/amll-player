import SwiftUI

enum MusicProductStyle {
    static let accent = Color("MusicAccent")
    static let filledAccent = Color("MusicAccentFill")
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
}

struct MusicSourceMenu: View {
    @Bindable var model: AppModel
    var body: some View {
        Menu {
            ForEach(MusicServiceID.allCases) { service in
                Button { model.selectMusicService(service) } label: {
                    Label(service.title + " · " + model.connectionSummary(service),
                          systemImage: service == model.selectedMusicService ? "checkmark" : "music.note")
                }
            }
            Divider()
            NavigationLink { MusicAccountsView(model: model) } label: {
                Label("管理音乐来源", systemImage: "person.crop.circle")
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.selectedMusicService.title)
                Image(systemName: "chevron.down").font(.caption2.bold())
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
        }
        .accessibilityLabel(Text("当前音乐来源，\(model.selectedMusicService.title)"))
        .accessibilityIdentifier("musicSourceMenu")
    }
}

struct MusicLoginDestination: View {
    @Bindable var model: AppModel
    let service: MusicServiceID
    var body: some View {
        switch service {
        case .spotify: SpotifyLoginView(model: model)
        case .appleMusic: AppleMusicLoginView(model: model)
        case .netease: NetEaseLoginView(model: model)
        }
    }
}

struct MusicLoginSheet: View {
    @Bindable var model: AppModel
    let service: MusicServiceID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            MusicLoginDestination(model: model, service: service)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .tint(MusicProductStyle.accent)
        .onChange(of: model.isConnected(to: service)) { _, connected in if connected { dismiss() } }
    }
}

struct MusicConnectionCard: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MusicProductStyle.accent.opacity(0.14))
                    Image(systemName: "music.note")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(MusicProductStyle.accent)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentServiceConnected ? "歌曲同步已连接" : "连接你的音乐")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text(model.selectedMusicService.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NavigationLink {
                MusicLoginDestination(model: model, service: model.selectedMusicService)
            } label: {
                HStack(spacing: 8) {
                    Text(model.currentServiceConnected ? String(localized: "查看连接与帮助") : String(localized: "连接 \(model.selectedMusicService.title)"))
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    MusicProductStyle.filledAccent,
                    in: RoundedRectangle(cornerRadius: SettingsCorners.button, style: .continuous)
                )
            }
            .buttonStyle(SettingsButtonStyle())
            .accessibilityIdentifier("connectCurrentMusic")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .settingsCardSurface(radius: SettingsCorners.card)
    }
    private var message: String {
        if model.selectedMusicService == .appleMusic, model.currentServiceConnected {
            return String(localized: "可以同步系统音乐 App 的歌曲和歌词。歌单和搜索暂不可用，请检查 Apple Music 的连接设置。")
        }
        switch model.selectedMusicService {
        case .spotify: return String(localized: "连接 Spotify 后，可以查看自己的歌单。也可以控制正在播放的设备并查看同步歌词。")
        case .appleMusic: return String(localized: "授权后，AMLL 会同步系统音乐 App 的歌曲和歌词。歌单和搜索能否使用，取决于当前安装版本的配置。")
        case .netease: return String(localized: "先浏览推荐与排行榜，登录后解锁个人歌单与每日推荐。")
        }
    }
}

struct MusicSectionHeading: View {
    let title: String
    var route: CatalogRoute?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold()).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 3) { Text("查看全部"); Image(systemName: "chevron.right") }
                        .font(.subheadline)
                }.frame(minHeight: 44)
            }
        }
    }
}

struct MusicCatalogCard: View {
    @Bindable var model: AppModel
    let row: MusicCatalogRow
    let width: CGFloat
    var onSelect: (() -> Void)? = nil
    var libraryShelf = false
    @State private var failure: String?
    @State private var showingLogin = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.item.kind == .track, row.item.canPlay {
                Button {
                    onSelect?()
                    guard model.isConnected(to: row.item.service) else { showingLogin = true; return }
                    Task {
                        do { try await model.playCatalog(row.item) }
                        catch is CancellationError {} catch { failure = error.localizedDescription }
                    }
                } label: { label }.buttonStyle(MusicContentButtonStyle())
            } else if let resource = row.item.resource {
                NavigationLink(value: CatalogRoute.resource(resource)) { label }
                    .buttonStyle(MusicContentButtonStyle()).simultaneousGesture(TapGesture().onEnded { onSelect?() })
            } else { label }
            if row.item.availability == .restricted {
                Text("catalog.restricted").font(.caption).foregroundStyle(.secondary)
            } else if row.item.availability == .unsupported {
                Text("catalog.unsupported").font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            if row.item.canPlay {
                CatalogPlayButton(model: model, item: row.item)
                    .modifier(MusicArtworkPlaySurface())
                    .padding(10)
                    .offset(y: max(0, width - 64))
            }
        }
        .frame(width: width, alignment: .topLeading)
        .sheet(isPresented: $showingLogin) { MusicLoginSheet(model: model, service: row.item.service) }
        .alert("播放未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private var label: some View {
        VStack(alignment: .leading, spacing: 8) {
            let corner = row.item.kind == .artist ? width / 2 : min(16, width / 6)
            CatalogArtwork(url: row.item.artworkURL, size: width, isArtist: row.item.kind == .artist)
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(libraryShelf ? 0.12 : 0.06), radius: libraryShelf ? 8 : 5, y: 3)
            Text(row.item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
            let subtitle = libraryShelf ? row.item.playlist?.ownerName ?? row.item.subtitle : row.item.subtitle
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct MusicSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).frame(height: 150)
                    RoundedRectangle(cornerRadius: 5, style: .continuous).frame(height: 14).padding(.trailing, 24)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).frame(height: 10).padding(.trailing, 52)
                }
            }
        }
        .foregroundStyle(.quaternary)
        .opacity(pulsing ? 0.45 : 0.9)
        .onAppear {
            guard !reduceMotion, !pulsing else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载音乐")
    }
}
