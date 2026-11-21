import SwiftUI
import UIKit

struct NetEaseRoomView: View {
    private struct DuetConversation: Identifiable {
        let roomID: String
        let peer: NetEaseRoomMember
        var id: String { "\(roomID):\(peer.id)" }
    }

    let model: AppModel
    private let opensChat: Bool
    private let onClose: (() -> Void)?
    private var playback: NetEasePlayback { model.netEasePlayback }
    private var activity: NetEaseRoomActivity { playback.roomActivity }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pastedLink = ""
    @State private var pendingInvite: NetEaseRoomInvite?
    @State private var confirmingSwitch = false
    @State private var error: String?
    @State private var chatActions: NetEaseFriendRoomActions
    @State private var duetConversation: DuetConversation?
    @State private var showingGroupChat = false
    @State private var didOpenRequestedChat = false
    @State private var pickingSong = false
    @State private var changingNotifications = false
    @State private var pendingOperation: LocalizedStringKey?

    init(model: AppModel, opensChat: Bool = false, onClose: (() -> Void)? = nil) {
        self.model = model
        self.opensChat = opensChat
        self.onClose = onClose
        _chatActions = State(initialValue: NetEaseFriendRoomActions(playback: model.netEasePlayback, session: model.netEaseSession))
    }

    var body: some View {
        NavigationStack {
            List {
                if let room = playback.listeningRoom { activeRoom(room) }
                else {
                    Section("创建房间") {
                        roomControls {
                            ForEach(NetEaseRoomKind.allCases) { kind in
                                Button {
                                    run("正在创建房间…") { try await playback.createRoom(kind) }
                                } label: {
                                    QuickSettingsControlLabel(title: kind == .duet ? "创建双人房" : "创建多人房",
                                        symbol: kind == .duet ? "person.2" : "person.3")
                                }
                                .buttonStyle(MusicContentButtonStyle())
                            }
                        }
                        if let pendingOperation, pendingInvite == nil { ProgressView(pendingOperation) }
                    }
                }
                Section("接受邀请") {
                    TextField("粘贴网易云一起听链接", text: $pastedLink, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("netEaseRoomInviteLink")
                    Button("查看邀请", systemImage: "link") {
                        guard let invite = NetEaseRoomInvite.parse(pastedLink) else {
                            error = NetEaseRoomError.invalidInvite.localizedDescription
                            return
                        }
                        pendingInvite = invite
                    }.disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    NavigationLink("收到的邀请") {
                        NetEaseRoomContacts(playback: playback, invite: nil) { pendingInvite = $0 }
                    }.accessibilityIdentifier("netEaseRoomInbox")
                }
                if let pendingInvite {
                    Section("待加入") {
                        Label(pendingInvite.kind.title, systemImage: "person.2")
                        Button("加入房间") { accept(pendingInvite) }
                            .accessibilityIdentifier("netEaseRoomJoin")
                        if let pendingOperation { ProgressView(pendingOperation) }
                    }
                }
                if playback.roomBusy, pendingOperation == nil { ProgressView("正在处理房间操作") }
                if let error = error ?? playback.roomNotice ?? (playback.isListeningTogether ? playback.failure : nil) {
                    Section {
                        Text(verbatim: error).foregroundStyle(.secondary)
                        Button("刷新房间") { run { try await playback.refreshListeningRoom() } }
                    }
                }
            }
            .accessibilityIdentifier("netEaseRoomContent")
            .disabled(playback.roomBusy)
            .navigationTitle("与好友一起听")
            .navigationBarTitleDisplayMode(.inline)
            .lyricsQuickSettingsDestination("与好友一起听")
            .toolbar {
                if quickSettingsNavigation == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            if let onClose { onClose() } else { dismiss() }
                        }.accessibilityIdentifier("netEaseRoomDone")
                    }
                }
            }
            .refreshable { await perform { try await playback.refreshListeningRoom() } }
            .task {
                if opensChat, !didOpenRequestedChat, let room = playback.listeningRoom {
                    didOpenRequestedChat = true
                    openChat(room)
                }
                await activity.refreshAuthorization()
                if playback.listeningRoom == nil { await perform { try await playback.refreshListeningRoom() } }
            }
            .navigationDestination(isPresented: $showingGroupChat) {
                if let room = playback.listeningRoom, room.kind == .group {
                    NetEaseRoomChat(playback: playback, room: room, account: model.netEaseSession.profile?.id)
                        .id(room.id)
                        .toolbar(.visible, for: .navigationBar)
                }
            }
            .confirmationDialog("离开当前房间并加入新房间？", isPresented: $confirmingSwitch, titleVisibility: .visible) {
                if let pendingInvite {
                    Button("切换房间", role: .destructive) {
                        run("正在加入房间…") { try await playback.joinRoom(pendingInvite, replacing: true); clearInvite() }
                    }
                }
            }
        }
        .sheet(isPresented: $pickingSong) {
            NetEaseSongPicker(model: model, title: "添加到房间") { item in
                pickingSong = false
                run("正在添加歌曲…") { try await playback.recommendRoomSong(item) }
            }
        }
        .fullScreenCover(item: $duetConversation) { conversation in
            NavigationStack {
                NetEaseConversationView(model: model, peer: conversation.peer, actions: chatActions,
                                        duetRoomID: conversation.roomID)
                    .id(model.netEaseSession.currentState.contextID)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭", systemImage: "xmark") { duetConversation = nil }
                                .accessibilityIdentifier("netEaseDuetChatClose")
                        }
                    }
            }
        }
    }

    @ViewBuilder private func activeRoom(_ room: NetEaseListeningRoom) -> some View {
        Section {
            roomHero(room)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        Section {
            roomControls {
                if let invite = playback.roomShareLink { inviteButton(invite) }
                Button { openChat(room) } label: {
                    QuickSettingsControlLabel(title: room.kind == .duet ? "与好友聊天" : "房间聊天",
                        symbol: "bubble.left.and.bubble.right")
                }
                .buttonStyle(MusicContentButtonStyle())
                .disabled(room.kind == .duet ? playback.duetChatPeer == nil : room.chatID == nil)
                .accessibilityIdentifier(room.kind == .duet ? "netEaseDuetChat" : "netEaseRoomGroupChat")
                Button { pickingSong = true } label: {
                    QuickSettingsControlLabel(title: "添加歌曲", symbol: "plus.circle",
                        indicator: "chevron.forward", selected: true)
                }
                .buttonStyle(MusicContentButtonStyle())
                .accessibilityIdentifier("netEaseRoomAddSong")
                if let invite = playback.roomShareLink {
                    ShareLink(item: invite.url) {
                        QuickSettingsControlLabel(title: "分享邀请链接", symbol: "square.and.arrow.up")
                    }
                    .buttonStyle(MusicContentButtonStyle())
                }
            }
            if let pendingOperation, pendingInvite == nil { ProgressView(pendingOperation) }
        }
        if let track = playback.currentEntry?.item {
            Section("正在一起听") {
                HStack(spacing: 12) {
                    CatalogArtwork(url: track.artworkURL, size: 48).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name).font(.headline)
                        Text(track.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "waveform").foregroundStyle(MusicProductStyle.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        Section("房间队列") {
            if playback.roomQueue.isEmpty { Text("暂无待播歌曲").foregroundStyle(.secondary) }
            ForEach(Array(playback.roomQueue.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    CatalogArtwork(url: item.artworkURL, size: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
            }
        }
        if !activity.events.isEmpty {
            Section("最近房间动态") {
                ForEach(activity.events.prefix(10)) { event in
                    Label(event.text, systemImage: event.symbol).font(.subheadline)
                }
            }
        }
        Section {
            Toggle("锁屏与后台提醒", systemImage: "bell", isOn: Binding(
                get: { activity.systemAlertsEnabled },
                set: { enabled in
                    changingNotifications = true
                    Task {
                        await activity.setSystemAlerts(enabled)
                        changingNotifications = false
                    }
                }
            ).hapticSelection()).disabled(changingNotifications)
            if activity.systemStatus == .denied,
               let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("在系统设置中开启通知") { openURL(settings) }
            }
        } footer: {
            Text("App 在后台收到房间动态时发送提醒。")
        }
        Section {
            Button("离开房间", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                run("正在离开房间…") { try await playback.leaveRoom() }
            }.accessibilityIdentifier("netEaseRoomLeave")
        }
    }

    private func roomHero(_ room: NetEaseListeningRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(room.kind.title, systemImage: "headphones")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MusicProductStyle.accent)
                .accessibilityAddTraits(.isHeader)
            if room.kind == .duet {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { duetMembers(room) }
                    VStack(alignment: .leading, spacing: 14) { duetMembers(room) }
                }
            } else {
                groupMembers(room)
            }
            if room.members.count >= 2 {
                NetEaseRoomDurationLabel(activity: activity)
                    .font(.headline)
            } else {
                Text("等待好友加入").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22)
            if reduceTransparency {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            } else {
                shape.fill(Color(uiColor: .tertiarySystemFill))
                    .overlay {
                        shape.fill(.linearGradient(colors: [MusicProductStyle.accent.opacity(0.16), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
        }
    }

    @ViewBuilder private func duetMembers(_ room: NetEaseListeningRoom) -> some View {
        ForEach(room.members) { member in
            VStack(alignment: .leading, spacing: 8) {
                CatalogArtwork(url: member.avatar, size: 54, isArtist: true).accessibilityHidden(true)
                Text(member.name).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if room.members.count < 2 {
            if let invite = playback.roomShareLink {
                NavigationLink {
                    NetEaseRoomContacts(playback: playback, invite: invite) { _ in }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "person.badge.plus").font(.title3)
                            .frame(width: 54, height: 54)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                            .accessibilityHidden(true)
                        Text("邀请好友").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(MusicProductStyle.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MusicContentButtonStyle())
            }
        }
    }

    @ViewBuilder private func groupMembers(_ room: NetEaseListeningRoom) -> some View {
        if !room.members.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(room.members) { member in
                        CatalogArtwork(url: member.avatar, size: 42, isArtist: true)
                            .accessibilityLabel(Text(member.name))
                    }
                }
            }.scrollIndicators(.hidden)
            DisclosureGroup("查看成员（\(room.members.count)）") {
                ForEach(room.members) { member in
                    HStack {
                        Text(member.name)
                        Spacer()
                        if member.id == model.netEaseSession.profile?.id {
                            Text("你").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
            .font(.subheadline)
        }
    }

    private func inviteButton(_ invite: NetEaseRoomInvite) -> some View {
        NavigationLink {
            NetEaseRoomContacts(playback: playback, invite: invite) { _ in }
        } label: {
            QuickSettingsControlLabel(title: "邀请网易云好友", symbol: "person.badge.plus", indicator: "chevron.forward")
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityIdentifier("netEaseRoomInviteFriend")
    }

    private func roomControls<Controls: View>(@ViewBuilder _ controls: () -> Controls) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                 count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8, content: controls)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func openChat(_ room: NetEaseListeningRoom) {
        if room.kind == .group, room.chatID != nil { showingGroupChat = true }
        if room.kind == .duet, let peer = playback.duetChatPeer {
            duetConversation = .init(roomID: room.id, peer: peer)
        }
    }

    private func accept(_ invite: NetEaseRoomInvite) {
        if let room = playback.listeningRoom, room.id != invite.room || room.kind != invite.kind {
            confirmingSwitch = true
        } else {
            run("正在加入房间…") { try await playback.joinRoom(invite, replacing: false); clearInvite() }
        }
    }

    private func clearInvite() { pendingInvite = nil; pastedLink = "" }

    private func run(_ label: LocalizedStringKey? = nil, _ work: @escaping @MainActor () async throws -> Void) {
        guard pendingOperation == nil else { return }
        pendingOperation = label
        Task {
            defer { pendingOperation = nil }
            await perform(work)
        }
    }

    private func perform(_ work: @MainActor () async throws -> Void) async {
        error = nil
        do { try await work() } catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

private struct NetEaseRoomContacts: View {
    let playback: NetEasePlayback
    let invite: NetEaseRoomInvite?
    let onInvite: (NetEaseRoomInvite) -> Void
    @State private var contacts: [NetEaseRoomMember] = []
    @State private var offset = 0
    @State private var more = true
    @State private var loading = false
    @State private var recipient: NetEaseRoomMember?
    @State private var sent: String?
    @State private var error: String?

    var body: some View {
        List {
            if let sent {
                Label("已发送给 \(sent)", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ForEach(contacts) { member in
                if invite != nil { Button(member.name) { recipient = member } }
                else {
                    NavigationLink(member.name) {
                        NetEaseRoomInvitations(api: playback.roomAPI, contact: member, onInvite: onInvite)
                    }
                }
            }
            if loading { ProgressView() }
            else if more { Button(offset == 0 ? "加载" : "加载更多") { Task { await load() } } }
            else if contacts.isEmpty { Text(invite == nil ? "暂无私信会话" : "暂无关注好友").foregroundStyle(.secondary) }
            if let error { Text(verbatim: error).foregroundStyle(.secondary) }
        }
        .navigationTitle(invite == nil ? "收到的邀请" : "邀请网易云好友")
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
        .confirmationDialog("将一起听链接发送给 \(recipient?.name ?? "")？",
                            isPresented: Binding(get: { recipient != nil }, set: { if !$0 { recipient = nil } }),
                            titleVisibility: .visible) {
            if let recipient, let invite {
                Button("发送邀请") { Task { await send(invite, to: recipient) } }
            }
        }
    }

    private func load() async {
        guard !loading, more else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            let page = if invite == nil { try await playback.roomAPI.inbox(offset: offset) }
                       else { try await playback.roomAPI.contacts(offset: offset) }
            var seen = Set(contacts.map(\.id))
            contacts += page.filter { seen.insert($0.id).inserted }
            offset += 30
            more = page.count == 30
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func send(_ invite: NetEaseRoomInvite, to peer: NetEaseRoomMember) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            try await playback.roomAPI.sendInvite(invite, to: peer)
            withAnimation(MusicProductMotion.change) { sent = peer.name }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NetEaseRoomInvitations: View {
    let api: NetEaseRoomAPI
    let contact: NetEaseRoomMember
    let onInvite: (NetEaseRoomInvite) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var invites: [NetEaseRoomInvite] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if loading { ProgressView() }
            else if let error { Text(verbatim: error).foregroundStyle(.secondary) }
            else if invites.isEmpty { Text("最近的私信里没有一起听邀请").foregroundStyle(.secondary) }
            ForEach(invites) { invite in
                Button {
                    onInvite(invite)
                    dismiss()
                } label: { Label(invite.kind.title, systemImage: "link") }
            }
        }
        .navigationTitle(contact.name)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        defer { loading = false }
        do { invites = try await api.invites(from: contact); error = nil }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NetEaseRoomChat: View {
    let playback: NetEasePlayback
    let room: NetEaseListeningRoom
    let account: String?
    @Environment(\.scenePhase) private var phase
    @State private var visibilityToken = UUID()
    @State private var messages: [NetEaseRoomMessage] = []
    @State private var text = ""
    @State private var error: String?
    @State private var readError: String?
    @State private var sending = false
    @State private var reading = false

    private var active: Bool {
        playback.listeningRoom?.id == room.id && playback.listeningRoom?.kind == room.kind
    }

    var body: some View {
        List {
            if !active { Text("房间成员已变更。").foregroundStyle(.secondary) }
            if let error = error ?? readError { Text(verbatim: error).foregroundStyle(.secondary) }
            ForEach(messages) { message in
                VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
                    if !message.outgoing { Text(message.sender).font(.caption).foregroundStyle(.secondary) }
                    Text(verbatim: message.text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(message.outgoing ? MusicProductStyle.accent.opacity(0.18) :
                            Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
                .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("房间聊天")
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("消息", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                Button(sending ? "发送中…" : "发送") { Task { await send() } }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 100)
            }
            .padding()
            .background(.regularMaterial)
            .disabled(!active)
        }
        .refreshable { await refresh() }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled, active {
                if !sending { await refresh() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onAppear {
            if let account {
                playback.roomActivity.setChatVisible(.init(account: account, room: room, chat: true), token: visibilityToken)
            }
        }
        .onDisappear { playback.roomActivity.setChatVisible(nil, token: visibilityToken) }
        .onChange(of: active) { if !active { messages.removeAll() } }
    }

    private func refresh() async {
        guard active, !reading, let current = playback.listeningRoom else { return }
        reading = true
        defer { reading = false }
        do {
            let updated = try await playback.roomAPI.messages(current)
            if active { messages = updated; readError = nil }
        }
        catch is CancellationError {} catch { if active { readError = error.localizedDescription } }
    }

    private func send() async {
        guard !sending, active, let current = playback.listeningRoom else { return }
        sending = true
        defer { sending = false }
        let draft = text
        do {
            try await playback.roomAPI.sendMessage(current, text: draft)
            if text == draft { text = "" }
            error = nil
            await refresh()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
