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
                if let url = profile?.avatarURL {
                    CatalogArtwork(url: url, size: 40, isArtist: true)
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        }
                } else {
                    ZStack {
                        Circle()
                            .fill(MusicProductStyle.accent.opacity(0.14))
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MusicProductStyle.accent)
                    }
                    .frame(width: 38, height: 38)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
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
                        ForEach(cards.prefix(1), id: \.0.id) { row, category in
                            MusicHomeCard(model: model, row: row, width: width, category: category)
                        }
                        if fm { MusicHomeFMCard(model: model, width: width, openPlayer: openPlayer) }
                        ForEach(cards.dropFirst(), id: \.0.id) { row, category in
                            MusicHomeCard(model: model, row: row, width: width, category: category)
                        }
                    }.scrollTargetLayout()
                }.contentMargins(.horizontal, 20, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
                    .accessibilityIdentifier("musicHomeFeatured")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.20))
                            Image(systemName: "sparkles")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)

                        Spacer(minLength: 12)
                        Text("\(replay.year) 年度回顾").font(.title.bold())
                        Text("重温你听过的歌曲、专辑与歌手").font(.subheadline).foregroundStyle(.white.opacity(0.88))
                        Label("查看回顾", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [
                                MusicProductStyle.accent,
                                MusicProductStyle.filledAccent,
                                Color(red: 0.28, green: 0.04, blue: 0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    }
                    .shadow(color: MusicProductStyle.filledAccent.opacity(0.22), radius: 14, y: 6)
                }
                .buttonStyle(MusicContentButtonStyle())
                .padding(.horizontal, 20)
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
            if state.loadedAt == nil && state.error == nil { MusicSkeleton().padding(.horizontal, 20) }
            if let error = state.error {
                VStack(alignment: .leading) {
                    Text(section.title).font(.headline)
                    CatalogErrorView(error: error) { await home.load(section.query, force: true) }
                }.padding(.horizontal, 20)
            }
        }.task { await home.load(section.query) }
            .animation(reduceMotion ? nil : MusicProductMotion.change, value: state.rows.isEmpty)
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
            if let category {
                MusicHomePoster(item: row.item, category: category, width: width)
            } else {
                let corner: CGFloat = row.item.kind == .artist ? width / 2 : 14
                CatalogArtwork(url: row.item.artworkURL, size: width, isArtist: row.item.kind == .artist)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                Text(row.item.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if !row.item.subtitle.isEmpty { Text(row.item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.frame(width: width, alignment: .leading).contentShape(Rectangle())
    }
    private func play(shuffled: Bool = false) {
        guard model.isConnected(to: row.item.service) else { login = true; return }
        guard row.item.canPlay else { failure = "暂时无法播放。可以试试在官方 App 中打开。"; return }
        Task { do { try await model.playCatalog(row.item, shuffled: shuffled) }
            catch is CancellationError {} catch { failure = error.localizedDescription } }
    }
}

private struct MusicHomePoster: View {
    let item: MusicCatalogItem
    let category: String
    let width: CGFloat
    @Environment(\.displayScale) private var scale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var image: UIImage?
    @State private var tint: Color?
    @State private var loadedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.88))
            Text(item.name).font(.largeTitle.weight(.bold))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.88))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 22)
        .frame(width: width, alignment: .leading)
        .background {
            GeometryReader { geometry in
                // Tie contrast to the caption bounds, including when a title
                // wraps or Dynamic Type takes up more of the poster.
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.72), location: min(1, 28 / max(1, geometry.size.height))),
                    .init(color: .black.opacity(0.95), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(minHeight: MusicHomeLayout.featuredHeight(for: width), alignment: .bottomLeading)
        .background {
            GeometryReader { geometry in
                let artworkColor = loadedURL == item.artworkURL ? tint ?? MusicProductStyle.filledAccent : MusicProductStyle.filledAccent
                ZStack {
                    LinearGradient(colors: [artworkColor, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if loadedURL == item.artworkURL, let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            .transition(.opacity)
                    } else {
                        Image(systemName: item.kind?.symbol ?? "music.note")
                            .font(.system(size: 76, weight: .light))
                            .foregroundStyle(.white.opacity(0.36))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 48)
                    }
                    LinearGradient(colors: [.clear, artworkColor.opacity(0.40)],
                        startPoint: .center, endPoint: .bottom)
                }
            }
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .task(id: "\(item.artworkURL?.absoluteString ?? ""):\(Int(width * scale))") {
            guard let url = item.artworkURL else { image = nil; tint = nil; loadedURL = nil; return }
            let pixels = Int(max(width, MusicHomeLayout.featuredHeight(for: width)) * scale)
            let artwork = await CatalogImageCache.shared.image(url, pixels: pixels)
            guard !Task.isCancelled else { return }
            let sampledColor = artwork?.cgImage.flatMap { MusicArtworkColorSampler.averageColor(of: $0) }
            withAnimation(MusicProductMotion.change) {
                loadedURL = url
                image = artwork
                tint = sampledColor
            }
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
        }.listStyle(.insetGrouped).navigationTitle(section.title).task { await home.load(section.query) }.refreshable { await home.load(section.query, force: true) }
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
                    Section(section.title) {
                        ForEach(section.items) { CatalogRowView(model: model, row: $0, tapToPlay: true) }
                        if let query = section.query, section.next != nil {
                            NavigationLink("查看全部", value: CatalogRoute.home(.init(id: section.id, title: section.title, query: query)))
                        }
                    }
                }
            }
            if state.isLoading { ProgressView() }
            if let error = state.error { CatalogErrorView(error: error) { await home.load(.replay, force: true) } }
        }.listStyle(.insetGrouped).navigationTitle(state.replay.map { $0.year + " 年度回顾" } ?? "年度回顾").task { await home.load(.replay) }
    }
}
