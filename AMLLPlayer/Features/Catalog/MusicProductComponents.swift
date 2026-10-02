import SwiftUI

enum MusicProductStyle {
    static let accent = Color("MusicAccent")
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
        .accessibilityLabel("当前音乐来源，" + model.selectedMusicService.title)
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

struct MusicConnectionCard: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.currentServiceConnected ? "歌曲同步已连接" : "连接你的音乐", systemImage: "music.note")
                .font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            NavigationLink {
                MusicLoginDestination(model: model, service: model.selectedMusicService)
            } label: {
                Label(model.currentServiceConnected ? "查看连接与帮助" : "连接 " + model.selectedMusicService.title,
                      systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("connectCurrentMusic")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    private var message: String {
        if model.selectedMusicService == .appleMusic, model.currentServiceConnected {
            return "可以同步系统音乐与歌词。歌单和搜索暂不可用，请检查 Apple Music 连接配置。"
        }
        switch model.selectedMusicService {
        case .spotify: return "连接 Spotify 后查看你的歌单，控制正在播放的设备，并打开同步歌词。"
        case .appleMusic: return "授权后同步系统音乐 App 的歌曲与歌词；歌单和搜索取决于当前安装环境。"
        case .netease: return "先浏览推荐与排行榜，登录后解锁个人歌单与每日推荐。"
        }
    }
}

struct MusicSectionHeading: View {
    let title: String
    var route: CatalogRoute?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold()).foregroundStyle(.primary)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: CatalogRoute.resource(row.item.resource ?? .init(
                service: row.item.service, kind: row.item.kind ?? .album, scope: row.item.scope, rawValue: row.item.spotifyID))) {
                VStack(alignment: .leading, spacing: 8) {
                    CatalogArtwork(url: row.item.artworkURL, size: width, isArtist: row.item.kind == .artist)
                    Text(row.item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(row.item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { onSelect?() })
            if row.item.canPlay {
                CatalogPlayButton(model: model, item: row.item)
                    .accessibilityLabel("播放 " + row.item.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if row.item.availability == .restricted {
                Text("catalog.restricted").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}

struct MusicSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<2) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 16).frame(height: 150)
                    RoundedRectangle(cornerRadius: 4).frame(height: 14).padding(.trailing, 24)
                    RoundedRectangle(cornerRadius: 4).frame(height: 10).padding(.trailing, 52)
                }
            }
        }
        .foregroundStyle(.quaternary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载音乐")
    }
}
