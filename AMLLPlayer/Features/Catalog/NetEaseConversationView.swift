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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private var isActiveListeningPeer: Bool {
        guard let account = model.netEaseSession.profile?.id,
              let room = model.netEasePlayback.listeningRoom else { return false }
        return room.chattingPeer(viewer: account)?.id == peer.id
    }

    var body: some View {
        timeline
            .navigationTitle(peer.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        CatalogArtwork(url: peer.avatar, size: 30, isArtist: true)
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(peer.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if isActiveListeningPeer {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(MusicProductStyle.accent)
                                        .frame(width: 5, height: 5)
                                    Text("一起听中")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(MusicProductStyle.accent)
                                }
                            }
                        }
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
            LazyVStack(spacing: 0) {
                if older != nil {
                    Button {
                        Task { await refresh(more: true) }
                    } label: {
                        HStack(spacing: 6) {
                            if loading { ProgressView().controlSize(.small) }
                            Text("查看更早的消息")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }
                    .frame(minHeight: 44)
                    .disabled(loading)
                    .padding(.bottom, 6)
                    .id("older")
                }
                if let historyError {
                    VStack(spacing: 6) {
                        Button("重新加载私信") { Task { await refresh() } }
                            .font(.subheadline.weight(.semibold))
                        Text(historyError).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                } else if !didLoad {
                    ProgressView().frame(minHeight: 80)
                } else if messages.isEmpty, receipts.isEmpty {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(MusicProductStyle.accent.opacity(0.12))
                                .frame(width: 60, height: 60)
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(MusicProductStyle.accent)
                        }
                        Text("还没有消息")
                            .font(.headline)
                        Text("发送文本、分享一首歌，或邀请\(peer.name)一起听")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 48)
                    .padding(.horizontal, 24)
                }
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    let timestamp = showsTimestamp(at: index)
                    let grouped = isGroupedWithPrevious(at: index)
                    let showsTail = isLastInBurst(at: index)
                    VStack(spacing: 0) {
                        if timestamp {
                            Text(IMessageStyle.formatChatHeader(message.date))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 4 : 14)
                                .padding(.bottom, 8)
                                .accessibilityAddTraits(.isHeader)
                        }
                        bubble(message.content, outgoing: message.outgoing, showsTail: showsTail)
                    }
                    .padding(.top, timestamp ? 0 : (grouped ? 3 : 12))
                    .id("message:" + message.id)
                    .contextMenu {
                        if case .text(let text) = message.content {
                            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        }
                    }
                }
                ForEach(Array(receipts.enumerated()), id: \.element.id) { index, receipt in
                    let grouped = index > 0 || messages.last?.outgoing == true
                    let showsTail = index == receipts.count - 1
                    bubble(receipt.content, outgoing: true, showsTail: showsTail)
                        .padding(.top, grouped ? 3 : 12)
                        .transition(reduceMotion ? .opacity : .offset(x: 0, y: 7).combined(with: .opacity))
                }
                if !receipts.isEmpty {
                    HStack {
                        Spacer()
                        Text("发送中…")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                } else if messages.last?.outgoing == true {
                    HStack {
                        Spacer()
                        Text("已送达")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 660)
            .padding(.horizontal, 12)
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
                Button {
                    withAnimation(reduceMotion ? nil : MusicProductMotion.change) { position.scrollTo(edge: .bottom) }
                    unseen = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(MusicProductStyle.accent)
                        Text("新消息")
                            .foregroundStyle(.primary)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .iMessageLiquidGlass(in: Capsule(), interactive: true)
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func showsTimestamp(at index: Int) -> Bool {
        index == 0 || messages[index].time - messages[index - 1].time >= 1_800_000
    }

    private func isGroupedWithPrevious(at index: Int) -> Bool {
        index > 0
            && !showsTimestamp(at: index)
            && messages[index].outgoing == messages[index - 1].outgoing
            && messages[index].time - messages[index - 1].time < 180_000
    }

    private func isLastInBurst(at index: Int) -> Bool {
        guard index < messages.count - 1 else {
            return !(messages[index].outgoing && !receipts.isEmpty)
        }
        let current = messages[index]
        let next = messages[index + 1]
        if next.time - current.time >= 1_800_000 { return true }
        if next.outgoing != current.outgoing { return true }
        return next.time - current.time >= 180_000
    }

    private func bubble(_ content: NetEaseDirectMessage.Content, outgoing: Bool, showsTail: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            if outgoing {
                Spacer(minLength: 44)
            } else {
                if showsTail {
                    CatalogArtwork(url: peer.avatar, size: 28, isArtist: true)
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                } else {
                    Color.clear
                        .frame(width: 28, height: 1)
                        .accessibilityHidden(true)
                }
            }

            switch content {
            case .text(let text):
                Group {
                    if outgoing {
                        Text(verbatim: text)
                            .font(.body)
                            .foregroundStyle(.white)
                            .padding(.leading, 14)
                            .padding(.trailing, showsTail ? 19 : 14)
                            .padding(.vertical, 9.5)
                            .background(
                                IMessageStyle.outgoingFill(),
                                in: IMessageBubbleShape(outgoing: true, showsTail: showsTail)
                            )
                            .padding(.trailing, showsTail ? 0 : 5)
                    } else {
                        Text(verbatim: text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .padding(.leading, showsTail ? 19 : 14)
                            .padding(.trailing, 14)
                            .padding(.vertical, 9.5)
                            .background(
                                IMessageStyle.incomingFill(for: colorScheme),
                                in: IMessageBubbleShape(outgoing: false, showsTail: showsTail)
                            )
                            .padding(.leading, showsTail ? 0 : 5)
                    }
                }
            case .song(let id):
                NetEaseSharedSongCard(model: model, songID: id) { songDetail = id }
                    .padding(outgoing ? .trailing : .leading, 5)
            case .invitation(let invite):
                invitation(invite, outgoing: outgoing)
                    .padding(outgoing ? .trailing : .leading, 5)
            case .unsupported:
                Text("在网易云音乐查看此消息")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9.5)
                    .background(
                        IMessageStyle.incomingFill(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                    )
                    .padding(outgoing ? .trailing : .leading, 5)
            }

            if !outgoing { Spacer(minLength: 44) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(outgoing ? "我发送的消息" : peer.name + "发送的消息")
    }

    private func invitation(_ invite: NetEaseRoomInvite, outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(MusicProductStyle.accent.opacity(0.14))
                    Image(systemName: "headphones")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MusicProductStyle.accent)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("邀请一起听")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(invite.kind.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !outgoing, duetRoomID == nil {
                Button {
                    if let room = model.netEasePlayback.listeningRoom,
                       room.id != invite.room || room.kind != invite.kind {
                        joinInvite = invite
                    } else {
                        Task { await actions.join(invite, replacing: false) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("加入房间")
                        Image(systemName: "arrow.forward")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(MusicProductStyle.filledAccent, in: Capsule())
                }
                .buttonStyle(MusicContentButtonStyle())
                .disabled(actions.busy || !available)
            }
        }
        .padding(14)
        .frame(maxWidth: 268, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [MusicProductStyle.accent.opacity(0.10), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(MusicProductStyle.accent.opacity(0.22), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = sendError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(MusicProductStyle.accent)
                    Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if unconfirmed != nil {
                        Button("检查发送结果") { Task { await verifyPending() } }
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: 36)
                            .disabled(sending || !available)
                        Button("结束确认") {
                            if let unconfirmed { clearSentDraft(unconfirmed) }
                            unconfirmed = nil
                            sendError = nil
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 36)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .iMessageLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if !available {
                Label("会话当前不可用", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .iMessageLiquidGlass(in: Capsule())
            }
            if let song {
                HStack(spacing: 10) {
                    CatalogArtwork(url: song.artworkURL, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待分享歌曲")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MusicProductStyle.accent)
                        Text(song.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(song.subtitle).font(.caption).foregroundStyle(.secondary)
                    }.lineLimit(1)
                    Spacer(minLength: 0)
                    Button("移除待分享歌曲", systemImage: "xmark.circle.fill") { self.song = nil }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .iMessageLiquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { pickingSong = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(MusicContentButtonStyle())
                .iMessageLiquidGlass(in: Circle(), interactive: true)
                .contextMenu {
                    Button("选择歌曲", systemImage: "music.note.list") { pickingSong = true }
                    if let current = model.netEasePlayback.currentEntry?.item {
                        Button("分享当前播放", systemImage: "music.note") { song = current }
                    }
                    if duetRoomID == nil {
                        Button("邀请一起听", systemImage: "headphones") {
                            Task { await actions.listen(peer) }
                        }
                    }
                }
                .accessibilityLabel("分享歌曲")
                .accessibilityIdentifier("netEaseShareSong")

                HStack(alignment: .bottom, spacing: 4) {
                    TextField("网易云私信", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("netEaseMessageDraft")
                    Button {
                        AppHaptics.shared.play(.selection)
                        Task { await send() }
                    } label: {
                        Group {
                            if sending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(canSend ? MusicProductStyle.filledAccent : Color.secondary.opacity(0.28), in: Circle())
                                    .scaleEffect(canSend ? 1.0 : 0.94)
                                    .animation(reduceMotion ? nil : MusicProductMotion.feedback, value: canSend)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(MusicContentButtonStyle())
                    .accessibilityLabel("发送")
                    .accessibilityIdentifier("netEaseSendMessage")
                    .disabled(!canSend)
                }
                .iMessageLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            if trimmedDraft.utf16.count > 500 {
                Text("单条消息最多 500 字").font(.caption).foregroundStyle(MusicProductStyle.accent)
                    .padding(.leading, 56)
            }
        }
        .disabled(!available || sending)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
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

struct IMessageBubbleShape: Shape {
    let outgoing: Bool
    let showsTail: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard showsTail, w >= 14, h >= 14 else {
            return RoundedRectangle(cornerRadius: min(19, min(w, h) / 2), style: .continuous).path(in: rect)
        }
        let tail: CGFloat = 5
        let right = w - tail
        let r = min(18, min(right / 2, h / 2))
        var path = Path()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: right - r, y: 0))
        path.addQuadCurve(to: CGPoint(x: right, y: r), control: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: max(r, h - 12)))
        path.addCurve(
            to: CGPoint(x: w, y: h),
            control1: CGPoint(x: right, y: max(r, h - 4.5)),
            control2: CGPoint(x: w - 0.5, y: h - 1)
        )
        path.addCurve(
            to: CGPoint(x: max(r, right - 6), y: h - 2.5),
            control1: CGPoint(x: w - 2.5, y: h),
            control2: CGPoint(x: max(r, right - 3), y: h - 0.5)
        )
        path.addCurve(
            to: CGPoint(x: max(r, right - 15), y: h),
            control1: CGPoint(x: max(r, right - 8), y: h),
            control2: CGPoint(x: max(r, right - 11), y: h)
        )
        path.addLine(to: CGPoint(x: r, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        path.closeSubpath()

        if outgoing { return path }
        return path.applying(CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1))
    }
}

enum IMessageStyle {
    static func outgoingFill() -> LinearGradient {
        LinearGradient(
            colors: [MusicProductStyle.accent, MusicProductStyle.filledAccent],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func incomingFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.17) : Color(uiColor: .systemGray5)
    }

    static func formatInboxTime(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1_000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "昨天")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: Date()), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }

    static func formatChatHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return String(localized: "今天 \(time)")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "昨天 \(time)")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct IMessageLiquidGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay { border }
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(interactive && !reduceMotion), in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                    }
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { border }
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        }
    }

    private var border: some View {
        shape.strokeBorder(
            contrast == .increased ? Color.primary.opacity(0.35) : Color.primary.opacity(0.10),
            lineWidth: contrast == .increased ? 1 : 0.5
        )
    }
}

extension View {
    func iMessageLiquidGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(IMessageLiquidGlass(shape: shape, interactive: interactive))
    }
}
