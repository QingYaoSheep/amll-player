import SwiftUI

struct NetEaseFriendsButton: View {
    let model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var showing = false
    @State private var unread = false
    @State private var unreadContext: UUID?

    private var session: NetEaseSession { model.netEaseSession }
    private var hasUnread: Bool { unreadContext == session.currentState.contextID && unread }

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "person.2")
                .font(.system(size: 18, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle()
                            .fill(MusicProductStyle.accent)
                            .frame(width: 8, height: 8)
                            .offset(x: -5, y: 5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityLabel(hasUnread ? "好友，有未读私信" : "好友")
        .accessibilityIdentifier("netEaseFriends")
        .fullScreenCover(isPresented: $showing) {
            Group {
                if session.currentState.connected {
                    NetEaseFriendsView(model: model)
                } else {
                    NetEaseFriendsLogin(model: model)
                }
            }
            .id(session.currentState.contextID)
            .tint(MusicProductStyle.accent)
        }
        .task(id: "\(session.currentState.contextID):\(phase):\(showing)") {
            guard phase == .active, !showing, session.currentState.connected else { return }
            let context = session.currentState.contextID
            if let page = try? await NetEaseMessaging(session: session).conversations(offset: 0),
               !Task.isCancelled, context == session.currentState.contextID {
                unread = page.items.contains { $0.unread > 0 }
                unreadContext = context
            }
        }
    }
}

private struct NetEaseFriendsLogin: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            NetEaseLoginView(model: model)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

/// One action per social screen, shared across the list and the current conversation.
@MainActor @Observable final class NetEaseFriendRoomActions {
    struct Request {
        let peer: NetEaseRoomMember
        let previous: NetEaseListeningRoom
    }

    let playback: NetEasePlayback
    private let messaging: NetEaseMessaging
    var showingRoom = false
    var confirmation: Request?
    private(set) var busy = false
    private(set) var status: String?
    private(set) var retryPeer: NetEaseRoomMember?
    private(set) var pendingInvite: (NetEaseRoomMember, NetEaseRoomInvite)?
    private var sentInvites: [String: String] = [:]

    init(playback: NetEasePlayback, session: NetEaseSession) {
        self.playback = playback
        messaging = NetEaseMessaging(session: session)
    }

    func listen(_ peer: NetEaseRoomMember, replacing previous: NetEaseListeningRoom? = nil) async {
        guard !busy else { return }
        if let (recipient, invite) = pendingInvite,
           recipient.id == peer.id, playback.listeningRoom?.id == invite.room {
            await checkInvite()
            return
        }
        if let room = playback.listeningRoom, sentInvites[peer.id] == room.id {
            showingRoom = true
            return
        }
        busy = true
        status = nil
        retryPeer = nil
        defer { busy = false }
        do {
            switch try await playback.listenWithFriend(peer, replacing: previous) {
            case .openRoom: showingRoom = true
            case .sent(let invite): recordSent(invite, to: peer)
            case .needsConfirmation(let room): confirmation = .init(peer: peer, previous: room)
            case .deliveryUnknown(let invite):
                pendingInvite = (peer, invite)
                status = NetEaseMessageError.deliveryUnknown.localizedDescription
            }
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
            retryPeer = peer
        }
    }

    private func recordSent(_ invite: NetEaseRoomInvite, to peer: NetEaseRoomMember) {
        if sentInvites.values.contains(where: { $0 != invite.room }) { sentInvites.removeAll() }
        sentInvites[peer.id] = invite.room
        pendingInvite = nil
        status = String(localized: "已向 \(peer.name) 发送一起听邀请")
    }

    func checkInvite() async {
        guard !busy, let (peer, invite) = pendingInvite else { return }
        if playback.listeningRoom?.id != invite.room {
            pendingInvite = nil
            status = NetEaseRoomError.ended.localizedDescription
            return
        }
        busy = true
        defer { busy = false }
        do {
            let page = try await messaging.history(with: peer)
            if page.items.contains(where: {
                guard $0.outgoing, case .invitation(let sent) = $0.content else { return false }
                return sent.id == invite.id
            }) {
                recordSent(invite, to: peer)
            }
        } catch is CancellationError {
        } catch {
            status = NetEaseMessageError.deliveryUnknown.localizedDescription
        }
    }

    func join(_ invite: NetEaseRoomInvite, replacing: Bool) async {
        guard !busy else { return }
        busy = true
        status = nil
        retryPeer = nil
        defer { busy = false }
        do {
            try await playback.joinRoom(invite, replacing: replacing)
            showingRoom = true
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct NetEaseFriendsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSize
    @Environment(\.scenePhase) private var phase
    @State private var actions: NetEaseFriendRoomActions
    @State private var conversations: [NetEaseConversation] = []
    @State private var search = ""
    @State private var peer: NetEaseRoomMember?
    @State private var showingContacts = false
    @State private var contactSelection: NetEaseRoomMember?
    @State private var next: Int64?
    @State private var loading = false
    @State private var showProgress = false
    @State private var loaded = false
    @State private var failure: String?

    init(model: AppModel) {
        self.model = model
        _actions = State(initialValue: NetEaseFriendRoomActions(playback: model.netEasePlayback, session: model.netEaseSession))
    }

    var body: some View {
        Group {
            if horizontalSize == .regular {
                NavigationSplitView {
                    inbox.navigationSplitViewColumnWidth(min: 300, ideal: 340)
                } detail: {
                    if let peer { conversation(peer) }
                    else { emptyDetail }
                }
            } else {
                NavigationStack {
                    inbox.navigationDestination(item: $peer) { conversation($0) }
                }
            }
        }
        .modifier(NetEaseFriendRoomPresentation(model: model, actions: actions, isActive: !showingContacts))
        .fullScreenCover(isPresented: $showingContacts, onDismiss: selectContact) {
            NetEaseContactsView(session: model.netEaseSession, actions: actions) { contact in
                contactSelection = contact
                showingContacts = false
            }
            .modifier(NetEaseFriendRoomPresentation(model: model, actions: actions, isActive: showingContacts))
        }
    }

    private var filteredConversations: [NetEaseConversation] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return conversations }
        return conversations.filter {
            $0.peer.name.localizedStandardContains(term) || $0.preview.localizedStandardContains(term)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(MusicProductStyle.accent.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(MusicProductStyle.accent)
            }
            Text("选择一段私信")
                .font(.title3.bold())
            Text("与网易云好友实时私信、分享歌曲或开启一起听")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingContacts = true
            } label: {
                Label("发起新私信", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(MusicProductStyle.filledAccent, in: Capsule())
            }
            .buttonStyle(MusicContentButtonStyle())
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inbox: some View {
        List {
            if !filteredConversations.isEmpty {
                ForEach(filteredConversations) { item in
                    HStack(spacing: 6) {
                        Button { peer = item.peer } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(item.unread > 0 ? MusicProductStyle.accent : .clear)
                                    .frame(width: 9, height: 9)
                                    .accessibilityHidden(true)

                                CatalogArtwork(url: item.peer.avatar, size: 54, isArtist: true)
                                    .overlay {
                                        Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                    }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(item.peer.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        if let time = item.time, time > 0 {
                                            Text(IMessageStyle.formatInboxTime(time))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Image(systemName: "chevron.forward")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                            .accessibilityHidden(true)
                                    }

                                    HStack(alignment: .top, spacing: 6) {
                                        Text(item.preview)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                        if item.unread > 0 {
                                            Text(item.unread, format: .number)
                                                .font(.caption2.weight(.semibold))
                                                .monospacedDigit()
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2.5)
                                                .foregroundStyle(.white)
                                                .background(MusicProductStyle.filledAccent, in: Capsule())
                                                .accessibilityLabel("\(item.unread) 条未读")
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 62)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MusicContentButtonStyle())
                        .accessibilityIdentifier("netEaseConversation:\(item.id)")

                        NetEaseListenButton(peer: item.peer, actions: actions)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
                    .listRowBackground(peer?.id == item.id ? MusicProductStyle.accent.opacity(0.10) : nil)
                }
            } else if loaded, failure == nil {
                ContentUnavailableView {
                    Label(search.isEmpty ? "还没有私信" : "没有匹配的私信", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    if search.isEmpty {
                        Button("从关注列表发起聊天") { showingContacts = true }
                    }
                }
                .listRowSeparator(.hidden)
            }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
            if showProgress { ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            if !showProgress, next != nil || failure != nil {
                Button(failure == nil ? "载入更多私信" : "重试") {
                    Task { await load(more: next != nil) }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "搜索好友或消息")
        .navigationTitle("最近私信")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("我的关注", systemImage: "square.and.pencil") { showingContacts = true }
                    .accessibilityIdentifier("netEaseContacts")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { NetEaseFriendRoomStatus(actions: actions) }
        .refreshable { await load() }
        .task(id: phase) {
            guard phase == .active else { return }
            await load(quietly: loaded)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                if peer == nil, !showingContacts, !actions.showingRoom { await load(quietly: true) }
            }
        }
    }

    private func conversation(_ peer: NetEaseRoomMember) -> some View {
        NetEaseConversationView(model: model, peer: peer, actions: actions)
            .id(peer.id)
    }

    private func selectContact() {
        if let contactSelection { peer = contactSelection }
        contactSelection = nil
    }

    private func load(more: Bool = false, quietly: Bool = false) async {
        guard !loading, phase == .active else { return }
        let offset = more ? next ?? 0 : 0
        // Quiet refreshes keep the visible list and its previously loaded pages.
        loading = true
        showProgress = !quietly
        defer {
            loading = false
            showProgress = false
        }
        do {
            let page = try await NetEaseMessaging(session: model.netEaseSession).conversations(offset: offset)
            try Task.checkCancellation()
            var seen = Set<String>()
            if more {
                conversations = (conversations + page.items).filter { seen.insert($0.id).inserted }
            } else if quietly {
                let prefixCount = page.items.count
                let loadedTail = conversations.dropFirst(prefixCount)
                conversations = (page.items + loadedTail).filter { seen.insert($0.id).inserted }
            } else {
                conversations = page.items.filter { seen.insert($0.id).inserted }
            }
            if !quietly || !loaded { next = page.next }
            failure = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            if !quietly { failure = error.localizedDescription }
        }
    }
}

private struct NetEaseContactsView: View {
    let session: NetEaseSession
    let actions: NetEaseFriendRoomActions
    let select: (NetEaseRoomMember) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [NetEaseRoomMember] = []
    @State private var search = ""
    @State private var next: Int64? = 0
    @State private var loading = false
    @State private var failure: String?

    private var matches: [NetEaseRoomMember] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? contacts : contacts.filter { $0.name.localizedStandardContains(term) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { peer in
                    HStack(spacing: 8) {
                        Button { select(peer) } label: {
                            HStack(spacing: 12) {
                                CatalogArtwork(url: peer.avatar, size: 48, isArtist: true)
                                    .overlay {
                                        Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                    }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("点击发起私信")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MusicContentButtonStyle())
                        .accessibilityIdentifier("netEaseContact:\(peer.id)")
                        NetEaseListenButton(peer: peer, actions: actions)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 14))
                }
                if matches.isEmpty, next == nil, failure == nil {
                    ContentUnavailableView(search.isEmpty ? "还没有关注的人" : "没有匹配的昵称", systemImage: "person.2")
                }
                if let failure { Text(failure).foregroundStyle(.secondary).font(.footnote) }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else if next != nil {
                    Button(failure != nil ? "重试" : search.isEmpty ? "加载更多关注" : "搜索更多关注") {
                        Task { await load(searching: !search.isEmpty) }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "搜索昵称")
            .navigationTitle("我的关注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { NetEaseFriendRoomStatus(actions: actions) }
            .task { await load() }
        }
    }

    private func load(searching: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        failure = nil
        do {
            let api = NetEaseMessaging(session: session)
            var remaining = searching ? 3 : 1
            while let offset = next, remaining > 0 {
                let page = try await api.contacts(offset: offset)
                try Task.checkCancellation()
                var seen = Set(contacts.map(\.id))
                contacts += page.items.filter { seen.insert($0.id).inserted }
                next = page.next
                remaining -= 1
                if searching, !matches.isEmpty { break }
            }
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct NetEaseListenButton: View {
    let peer: NetEaseRoomMember
    let actions: NetEaseFriendRoomActions

    var body: some View {
        Button { Task { await actions.listen(peer) } } label: {
            Image(systemName: "headphones")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MusicProductStyle.accent)
                .frame(width: 34, height: 34)
                .background(MusicProductStyle.accent.opacity(0.12), in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(MusicContentButtonStyle())
        .disabled(actions.busy)
        .accessibilityLabel("与\(peer.name)一起听")
        .accessibilityIdentifier("netEaseListen:\(peer.id)")
    }
}

struct NetEaseFriendRoomStatus: View {
    let actions: NetEaseFriendRoomActions
    var body: some View {
        if actions.busy || actions.status != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { content }
                VStack(alignment: .leading, spacing: 4) { content }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .iMessageLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .transition(.opacity)
            .animation(MusicProductMotion.change, value: actions.status)
        }
    }

    @ViewBuilder private var content: some View {
        if actions.busy { ProgressView("正在处理一起听…").font(.footnote) }
        else if let status = actions.status {
            Text(status).font(.footnote).foregroundStyle(.secondary)
            if let peer = actions.retryPeer {
                Button("重发邀请") { Task { await actions.listen(peer) } }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
            } else if actions.pendingInvite != nil {
                Button("检查邀请") { Task { await actions.checkInvite() } }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
    }
}

struct NetEaseFriendRoomPresentation: ViewModifier {
    let model: AppModel
    @Bindable var actions: NetEaseFriendRoomActions
    let isActive: Bool
    private var isConfirming: Binding<Bool> {
        Binding(get: { isActive && actions.confirmation != nil }, set: { if isActive && !$0 { actions.confirmation = nil } })
    }
    private var isShowingRoom: Binding<Bool> {
        Binding(get: { isActive && actions.showingRoom }, set: { if isActive { actions.showingRoom = $0 } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: isShowingRoom) { NetEaseRoomView(model: model) }
            .confirmationDialog("切换一起听房间？", isPresented: isConfirming, titleVisibility: .visible,
                                presenting: actions.confirmation) { request in
                Button("离开并邀请", role: .destructive) {
                    Task { await actions.listen(request.peer, replacing: request.previous) }
                }
            } message: { request in
                Text("离开当前\(request.previous.kind.title)，并邀请\(request.peer.name)开始双人一起听。")
            }
    }
}
