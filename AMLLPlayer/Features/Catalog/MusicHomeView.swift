import SwiftUI

struct MusicHomeAccountMenu: View {
    @Bindable var model: AppModel
    let profile: MusicProfile?
    let devices: () -> Void
    var body: some View {
        Menu {
            Text(model.selectedMusicService.title + " · " + model.connectionSummary(model.selectedMusicService))
            ForEach(MusicServiceID.allCases) { service in
                Button { model.selectMusicService(service) } label: {
                    Label(service.title + " · " + model.connectionSummary(service),
                          systemImage: service == model.selectedMusicService ? "checkmark" : "music.note")
                }
            }
            Divider()
            NavigationLink { MusicAccountsView(model: model) } label: { Label("管理音乐来源", systemImage: "person.crop.circle") }
            NavigationLink { SettingsView(model: model) } label: { Label("settings.open", systemImage: "gearshape") }
                .accessibilityIdentifier("openSettings")
            if model.currentServiceConnected { Button("player.devices", systemImage: "airplayaudio", action: devices) }
        } label: {
            Group {
                if let url = profile?.avatarURL { CatalogArtwork(url: url, size: 40, isArtist: true) }
                else { Image(systemName: "person.crop.circle.fill").font(.system(size: 32)).foregroundStyle(MusicProductStyle.accent) }
            }.frame(width: 44, height: 44).contentShape(Circle())
        }
        .accessibilityLabel("账户与音乐来源，" + model.selectedMusicService.title)
        .accessibilityIdentifier("musicSourceMenu")
    }
}

struct CatalogHomeView: View {
    @Bindable var model: AppModel
    @Bindable var store: MusicCatalogStore
    let openPlayer: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var context: String { "\(store.identity):\(model.currentServiceConnected):\(model.canBrowseCurrentService)" }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    if !model.currentServiceConnected || !model.canBrowseCurrentService {
                        MusicConnectionCard(model: model).padding(.horizontal, 20)
                    }
                    if model.currentServiceConnected && !model.canBrowseCurrentService, let item = model.playbackSnapshot?.item {
                        Button(action: openPlayer) { Label("打开 " + item.title + " 的歌词", systemImage: "quote.bubble").frame(minHeight: 44) }
                            .padding(.horizontal, 20)
                    }
                    if model.canBrowseCurrentService {
                        featured(width: MusicHomeLayout.featuredWidth(in: geometry.size.width, largeText: typeSize.isAccessibilitySize))
                        ForEach(store.home.sections) { section in
                            MusicHomeShelf(model: model, home: store.home, section: section, state: store.home.state(section.query),
                                           width: MusicHomeLayout.coverWidth(in: geometry.size.width, largeText: typeSize.isAccessibilitySize))
                        }
                    }
                }.frame(maxWidth: MusicCatalogLayout.maximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemBackground))
            .refreshable { await store.home.refresh(); if model.currentServiceConnected { await store.loadProfile(force: true) } }
        }
        .navigationTitle("catalog.home").navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("catalogHome")
        .task(id: context) {
            store.home.configure(connected: model.currentServiceConnected, browsing: model.canBrowseCurrentService)
            async let featured: Void = store.home.prime()
            if model.currentServiceConnected && model.canBrowseCurrentService { await store.loadProfile() }
            await featured
        }
    }
    @ViewBuilder private func featured(width: CGFloat) -> some View {
        let cards = store.home.featured
        let fm = model.selectedMusicService == .netease && model.currentServiceConnected
        if !cards.isEmpty || fm {
            VStack(alignment: .leading, spacing: 12) {
                Text("为你精选").font(.title2.bold()).accessibilityAddTraits(.isHeader).padding(.horizontal, 20)
                if let name = store.profile?.displayName {
                    Text("为 " + name + " 精选").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        if fm { MusicHomeFMCard(model: model, width: width, openPlayer: openPlayer) }
                        ForEach(cards, id: \.0.id) { row, category in
                            MusicHomeCard(model: model, row: row, width: width, category: category)
                        }
                    }.scrollTargetLayout()
                }.contentMargins(.horizontal, 20, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            }
        }
    }
}

private struct MusicHomeShelf: View {
    @Bindable var model: AppModel
    let home: MusicHomeStore
    let section: MusicHomeSection
    @Bindable var state: MusicHomeSectionState
    let width: CGFloat
    var body: some View {
        Group {
            if section.query == .recommendations {
                ForEach(state.groups) { group in
                    AnyView(MusicHomeShelf(model: model, home: home, section: group, state: home.state(group.query), width: width))
                }
                if state.next != nil {
                    Button("更多推荐栏目") { Task { await home.load(section.query, more: true) } }.padding(.horizontal, 20)
                }
            } else if let replay = state.replay {
                NavigationLink(value: CatalogRoute.replay) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(replay.year) 年度回顾").font(.title.bold())
                        Text("重温你听过的歌曲、专辑与歌手").font(.body)
                        Label("查看回顾", systemImage: "arrow.right").font(.headline)
                    }.foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
                        .background(LinearGradient(colors: [.pink, .orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(MusicContentButtonStyle()).padding(.horizontal, 20)
            } else if !state.rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: CatalogRoute.home(section)) {
                        HStack(spacing: 6) { Text(section.title); Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary) }
                            .font(.title2.bold()).foregroundStyle(.primary).frame(minHeight: 44, alignment: .leading)
                    }.padding(.horizontal, 20).accessibilityAddTraits(.isHeader)
                    if let subtitle = section.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20) }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(state.rows.prefix(12))) { row in MusicHomeCard(model: model, row: row, width: width) }
                        }.scrollTargetLayout()
                    }.contentMargins(.horizontal, 20, for: .scrollContent)
                        .scrollTargetBehavior(.viewAligned).scrollPosition(id: $state.scrollAnchor).scrollIndicators(.hidden)
                }
            }
            if state.isLoading && state.loadedAt == nil { MusicSkeleton().padding(.horizontal, 20) }
            if let error = state.error {
                VStack(alignment: .leading) {
                    Text(section.title).font(.headline)
                    CatalogErrorView(error: error) { await home.load(section.query, force: true) }
                }.padding(.horizontal, 20)
            }
        }.task { await home.load(section.query) }
    }
}

struct MusicHomeCard: View {
    @Bindable var model: AppModel
    let row: MusicCatalogRow
    let width: CGFloat
    var category: String?
    @State private var failure: String?
    @State private var login = false
    @State private var choosing: MusicCatalogItem?
    private var featured: Bool { category != nil }
    var body: some View {
        Group {
            if row.item.kind == .track || row.item.kind == .station {
                Button { play() } label: { content }
            } else if let resource = row.item.resource {
                NavigationLink(value: CatalogRoute.resource(resource)) { content }
            } else { content }
        }.buttonStyle(MusicContentButtonStyle())
            .accessibilityIdentifier("homeCard:" + row.item.id)
            .contextMenu {
                if row.item.canPlay {
                    Button("播放", systemImage: "play.fill") { play() }
                    if row.item.kind == .playlist || row.item.kind == .album { Button("随机播放", systemImage: "shuffle") { play(shuffled: true) } }
                }
                if row.item.service == .netease {
                    NetEaseItemActions(model: model, item: row.item, onChoosePlaylist: { choosing = $0 }, onFailure: { failure = $0 })
                } else if row.item.service == .appleMusic {
                    AppleMusicItemActions(model: model, item: row.item, onChoosePlaylist: { choosing = $0 }, onFailure: { failure = $0 })
                }
                CatalogExternalLink(item: row.item)
            }
            .sheet(isPresented: $login) { MusicLoginSheet(model: model, service: row.item.service) }
            .sheet(item: $choosing) { item in
                if item.service == .netease { NetEasePlaylistChooser(model: model, item: item) }
                else { AppleMusicPlaylistChooser(model: model, item: item) }
            }
            .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if featured {
                ZStack(alignment: .bottomLeading) {
                    MusicHomePoster(url: row.item.artworkURL, width: width)
                    LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category ?? "").font(.caption)
                        Text(row.item.name).font(.headline)
                        Text(row.item.subtitle).font(.subheadline)
                    }.foregroundStyle(.white).padding(16)
                }.frame(width: width).frame(minHeight: width * 4 / 3).clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                CatalogArtwork(url: row.item.artworkURL, size: width, isArtist: row.item.kind == .artist)
                    .clipShape(RoundedRectangle(cornerRadius: row.item.kind == .artist ? width / 2 : 8))
                Text(row.item.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if !row.item.subtitle.isEmpty { Text(row.item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.frame(width: width, alignment: .leading).contentShape(Rectangle())
    }
    private func play(shuffled: Bool = false) {
        guard model.isConnected(to: row.item.service) else { login = true; return }
        guard row.item.canPlay else { failure = "这项内容目前不能播放，可尝试在官方 App 打开。"; return }
        Task { do { try await model.playCatalog(row.item, shuffled: shuffled) }
            catch is CancellationError {} catch { failure = error.localizedDescription } }
    }
}

private struct MusicHomePoster: View {
    let url: URL?
    let width: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
        }.frame(width: width, height: width * 4 / 3).clipped().accessibilityHidden(true)
            .task(id: "\(url?.absoluteString ?? ""):\(width):\(scale)") {
                image = nil
                guard let url else { return }
                let value = await CatalogImageCache.shared.image(url, pixels: Int(width * 4 / 3 * scale))
                if !Task.isCancelled { image = value }
            }
    }
}

struct MusicHomeCollectionView: View {
    @Bindable var model: AppModel
    let home: MusicHomeStore
    let section: MusicHomeSection
    var body: some View {
        let state = home.state(section.query)
        List {
            ForEach(state.rows) { CatalogRowView(model: model, row: $0, tapToPlay: true) }
            if state.next != nil { Button("加载更多") { Task { await home.load(section.query, more: true) } }.disabled(state.isLoading) }
            if state.isLoading { ProgressView() }
            if let error = state.error { CatalogErrorView(error: error) { await home.load(section.query, more: state.next != nil, force: true) } }
            if state.loadedAt != nil && state.rows.isEmpty && state.error == nil { Text("暂无内容").foregroundStyle(.secondary) }
        }.navigationTitle(section.title).task { await home.load(section.query) }.refreshable { await home.load(section.query, force: true) }
    }
}

struct MusicReplayView: View {
    @Bindable var model: AppModel
    let home: MusicHomeStore
    var body: some View {
        let state = home.state(.replay)
        List {
            if let summary = state.replay {
                ForEach(summary.sections) { section in
                    Section(section.title) { ForEach(section.items) { CatalogRowView(model: model, row: $0, tapToPlay: true) } }
                }
            }
            if state.isLoading { ProgressView() }
            if let error = state.error { CatalogErrorView(error: error) { await home.load(.replay, force: true) } }
        }.navigationTitle(state.replay.map { $0.year + " 年度回顾" } ?? "年度回顾").task { await home.load(.replay) }
    }
}
