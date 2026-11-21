import SwiftUI

struct NetEaseConversationView: View {
    private struct Pending: Identifiable {
        let id = UUID()
        let content: NetEaseDirectMessage.Content
        let baseline: Set<String>
        let started: Int64

        func matches(_ message: NetEaseDirectMessage) -> Bool {
            message.outgoing && message.content == content && !baseline.contains(message.id)
                && message.time >= started - 5_000
        }
    }

    let model: AppModel
    let peer: NetEaseRoomMember
    let actions: NetEaseFriendRoomActions
    var duetRoomID: String? = nil
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var messages: [NetEaseDirectMessage] = []
    @State private var receipts: [Pending] = []
    @State private var unconfirmed: Pending?
    @State private var older: Int64?
    @State private var didLoad = false
    @State private var loading = false
    @State private var sending = false
    @State private var historyError: String?
    @State private var sendError: String?
    @State private var draft = ""
    @State private var song: MusicCatalogItem?
    @State private var pickingSong = false
    @State private var songDetail: String?
    @State private var joinInvite: NetEaseRoomInvite?
    @State private var position = ScrollPosition(idType: String.self)
    @State private var nearBottom = true
    @State private var unseen = false
    @State private var roomVisibilityToken = UUID()

    private var api: NetEaseMessaging { .init(session: model.netEaseSession) }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var available: Bool {
        guard model.selectedMusicService == .netease, model.netEaseSession.currentState.connected else { return false }
        guard let duetRoomID else { return true }
        return model.netEasePlayback.listeningRoom?.id == duetRoomID && model.netEasePlayback.duetChatPeer?.id == peer.id
    }
    private var canSend: Bool {
        available && !sending && unconfirmed == nil && (song != nil || (1...500).contains(trimmedDraft.utf16.count))
    }
    private var visibleRoomChat: NetEaseRoomDestination? {
        guard available, phase == .active, !pickingSong, songDetail == nil, !actions.showingRoom,
              let account = model.netEaseSession.profile?.id,
              let room = model.netEasePlayback.listeningRoom, room.chattingPeer(viewer: account)?.id == peer.id else {
            return nil
        }
        return .init(account: account, room: room, chat: true, peer: peer.id)
    }

    var body: some View {
        timeline
            .navigationTitle(peer.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        CatalogArtwork(url: peer.avatar, size: 28, isArtist: true)
                        Text(peer.name).font(.headline).lineLimit(1)
                    }
                    .accessibilityAddTraits(.isHeader)
                }
                if duetRoomID == nil {
                    ToolbarItem(placement: .primaryAction) { NetEaseListenButton(peer: peer, actions: actions) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if duetRoomID == nil { NetEaseFriendRoomStatus(actions: actions) }
                    composer
                }
            }
            .task(id: "\(phase):\(available):\(actions.showingRoom):\(pickingSong):\(songDetail != nil)") {
                guard phase == .active, available, !actions.showingRoom, !pickingSong, songDetail == nil else { return }
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .onChange(of: visibleRoomChat, initial: true) {
                model.netEasePlayback.roomActivity.setChatVisible(visibleRoomChat, token: roomVisibilityToken)
            }
            .onDisappear {
                model.netEasePlayback.roomActivity.setChatVisible(nil, token: roomVisibilityToken)
            }
            .sheet(isPresented: $pickingSong) {
                NetEaseSongPicker(model: model) {
                    song = $0
                    pickingSong = false
                }
            }
            .sheet(isPresented: Binding(get: { songDetail != nil }, set: { if !$0 { songDetail = nil } })) {
                if let songDetail {
                    NetEaseSharedSongDetail(model: model, songID: songDetail)
                }
            }
            .confirmationDialog("离开当前房间并加入好友的房间？",
                                isPresented: Binding(get: { joinInvite != nil }, set: { if !$0 { joinInvite = nil } }),
                                titleVisibility: .visible, presenting: joinInvite) { invite in
                Button("切换房间", role: .destructive) {
                    Task { await actions.join(invite, replacing: true) }
                }
            }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if older != nil {
                    Button("查看更早的消息") { Task { await refresh(more: true) } }
                        .font(.footnote).frame(minHeight: 44).disabled(loading)
                        .id("older")
                }
                if let historyError {
                    Button("重新加载私信") { Task { await refresh() } }
                    Text(historyError).font(.footnote).foregroundStyle(.secondary)
                } else if !didLoad {
                    ProgressView().frame(minHeight: 60)
                } else if messages.isEmpty, receipts.isEmpty {
                    ContentUnavailableView("还没有消息", systemImage: "bubble.left.and.bubble.right")
                }
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    VStack(spacing: 8) {
                        if index == 0 || message.time - messages[index - 1].time >= 1_800_000 {
                            Text(message.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .accessibilityAddTraits(.isHeader)
                        }
                        bubble(message.content, outgoing: message.outgoing)
                    }
                        .id("message:" + message.id)
                        .contextMenu {
                            if case .text(let text) = message.content {
                                Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                            }
                        }
                }
                ForEach(receipts) { receipt in
                    bubble(receipt.content, outgoing: true)
                        .transition(reduceMotion ? .opacity : .offset(x: 0, y: 7).combined(with: .opacity))
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 660)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .scrollPosition($position, anchor: .top)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY <= 48
        } action: { _, close in
            nearBottom = close
            if close { unseen = false }
        }
        .overlay(alignment: .bottom) {
            if unseen {
                Button("新消息", systemImage: "arrow.down") {
                    withAnimation(reduceMotion ? nil : MusicProductMotion.change) { position.scrollTo(edge: .bottom) }
                    unseen = false
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, 8)
            }
        }
    }

    private func bubble(_ content: NetEaseDirectMessage.Content, outgoing: Bool) -> some View {
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 28) }
            switch content {
            case .text(let text):
                Text(verbatim: text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(outgoing ? Color.white : Color.primary)
                    .background(outgoing ? MusicProductStyle.filledAccent : Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 19))
            case .song(let id):
                NetEaseSharedSongCard(model: model, songID: id) { songDetail = id }
            case .invitation(let invite):
                invitation(invite, outgoing: outgoing)
            case .unsupported:
                Text("在网易云音乐查看此消息").font(.footnote).foregroundStyle(.secondary)
                    .padding(10)
            }
            if !outgoing { Spacer(minLength: 28) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(outgoing ? "我发送的消息" : peer.name + "发送的消息")
    }

    private func invitation(_ invite: NetEaseRoomInvite, outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("邀请一起听", systemImage: "headphones")
                .font(.headline)
            Text(invite.kind.title).font(.caption).foregroundStyle(.secondary)
            if !outgoing, duetRoomID == nil {
                Button("加入房间", systemImage: "arrow.right") {
                    if let room = model.netEasePlayback.listeningRoom,
                       room.id != invite.room || room.kind != invite.kind {
                        joinInvite = invite
                    } else {
                        Task { await actions.join(invite, replacing: false) }
                    }
                }
                .buttonStyle(MusicContentButtonStyle())
                .frame(minHeight: 44)
                .disabled(actions.busy || !available)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(0.2))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage = sendError {
                Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                if unconfirmed != nil {
                    Button("检查发送结果", systemImage: "arrow.clockwise") { Task { await verifyPending() } }
                        .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                        .disabled(sending || !available)
                    Button("结束确认") {
                        if let unconfirmed { clearSentDraft(unconfirmed) }
                        unconfirmed = nil
                        sendError = nil
                    }
                    .font(.footnote).frame(minHeight: 44)
                }
            }
            if !available {
                Label("会话当前不可用", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let song {
                HStack(spacing: 8) {
                    CatalogArtwork(url: song.artworkURL, size: 32)
                    VStack(alignment: .leading) {
                        Text(song.name).font(.subheadline.weight(.semibold))
                        Text(song.subtitle).font(.caption).foregroundStyle(.secondary)
                    }.lineLimit(1)
                    Spacer()
                    Button("移除待分享歌曲", systemImage: "xmark.circle.fill") { self.song = nil }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button { pickingSong = true } label: {
                    Image(systemName: "plus.circle").font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(MusicContentButtonStyle())
                .accessibilityLabel("分享歌曲")
                .accessibilityIdentifier("netEaseShareSong")
                TextField("网易云私信", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(minHeight: 44)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("netEaseMessageDraft")
                Button { Task { await send() } } label: {
                    if sending { ProgressView().frame(width: 44, height: 44) }
                    else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(MusicContentButtonStyle())
                .accessibilityLabel("发送")
                .accessibilityIdentifier("netEaseSendMessage")
                .disabled(!canSend)
            }
            if trimmedDraft.utf16.count > 500 {
                Text("单条消息最多 500 字").font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!available || sending)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background {
            if reduceTransparency { Color(uiColor: .secondarySystemBackground) }
            else { Rectangle().fill(.regularMaterial) }
        }
    }

    private func refresh(more: Bool = false) async {
        guard available, !loading, !more || older != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.history(with: peer, before: more ? older ?? 0 : 0)
            try Task.checkCancellation()
            guard available else { return }
            update(page, more: more)
            historyError = nil
        } catch is CancellationError {
        } catch {
            if more || !didLoad { historyError = error.localizedDescription }
        }
    }

    private func update(_ page: NetEaseMessagePage<NetEaseDirectMessage>, more: Bool) {
        let ids = Set(messages.map(\.id))
        let formerLast = messages.last?.time ?? 0
        let newArrivals = !more && page.items.contains { !ids.contains($0.id) && $0.time >= formerLast }
        let follow = !didLoad || (newArrivals && nearBottom)
        var merged = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in page.items { merged[message.id] = message }
        messages = merged.values.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        var consumed = Set<String>()
        receipts.removeAll { receipt in
            guard let match = page.items.first(where: { !consumed.contains($0.id) && receipt.matches($0) }) else { return false }
            consumed.insert(match.id)
            return true
        }
        if let pending = unconfirmed,
           page.items.contains(where: { !consumed.contains($0.id) && pending.matches($0) }) {
            clearSentDraft(pending)
            unconfirmed = nil
            sendError = nil
        }
        if !didLoad || more { older = page.next }
        didLoad = true
        if follow { position.scrollTo(edge: .bottom) }
        else if newArrivals { unseen = true }
    }

    private func send() async {
        guard canSend else { return }
        let messaging = api
        let content: NetEaseDirectMessage.Content = song.map { .song($0.spotifyID) } ?? .text(trimmedDraft)
        let pending = Pending(content: content, baseline: Set(messages.map(\.id)),
                              started: Int64(Date().timeIntervalSince1970 * 1_000))
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            let roomAPI = model.netEasePlayback.roomAPI
            if let duetRoomID {
                guard let room = model.netEasePlayback.listeningRoom, room.id == duetRoomID else {
                    throw NetEaseRoomError.roomChanged
                }
                try await roomAPI.checkDuetChat(room, peer: peer)
            }
            guard available else { return }
            switch content {
            case .text(let text): try await messaging.sendText(text, to: peer)
            case .song(let id): try await messaging.sendSong(id, to: peer)
            default: return
            }
            clearSentDraft(pending)
            withAnimation(MusicProductMotion.change) {
                receipts.append(pending)
                if receipts.count > 30 { receipts.removeFirst() }
            }
            position.scrollTo(edge: .bottom)
            await refresh()
        } catch is CancellationError {
        } catch {
            if NetEaseMessageError.mayHaveDelivered(error) {
                unconfirmed = pending
                await verifyPending()
            } else {
                sendError = error.localizedDescription
            }
        }
    }

    private func verifyPending() async {
        guard unconfirmed != nil, available else { return }
        sendError = NetEaseMessageError.deliveryUnknown.localizedDescription
        do {
            let page = try await api.history(with: peer)
            guard available else { return }
            update(page, more: false)
            // Keep an ambiguous send locked. A missing echo alone cannot establish
            // failure, and retrying it could deliver a duplicate to the friend.
        } catch is CancellationError {
        } catch {
            sendError = NetEaseMessageError.deliveryUnknown.localizedDescription
        }
    }

    private func clearSentDraft(_ pending: Pending) {
        if pending.content == .text(trimmedDraft) { draft = "" }
        if let song, pending.content == .song(song.spotifyID) { self.song = nil }
    }
}
