import SwiftUI

struct NetEaseRoomView: View {
    let playback: NetEasePlayback
    @Environment(\.dismiss) private var dismiss
    @State private var pastedLink = ""
    @State private var pendingInvite: NetEaseRoomInvite?
    @State private var confirmingSwitch = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let room = playback.listeningRoom { activeRoom(room) }
                else {
                    Section("创建房间") {
                        ForEach(NetEaseRoomKind.allCases) { kind in
                            Button(kind.title, systemImage: kind == .duet ? "person.2" : "person.3") {
                                run { try await playback.createRoom(kind) }
                            }
                        }
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
                    }
                }
                if playback.roomBusy { ProgressView("正在处理房间操作") }
                if let error = error ?? playback.roomNotice ?? (playback.isListeningTogether ? playback.failure : nil) {
                    Section {
                        Text(verbatim: error).foregroundStyle(.secondary)
                        Button("刷新房间") { run { try await playback.refreshListeningRoom() } }
                    }
                }
            }
            .navigationTitle("与好友一起听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .disabled(playback.roomBusy)
            .refreshable { await perform { try await playback.refreshListeningRoom() } }
            .task { await perform { try await playback.refreshListeningRoom() } }
            .confirmationDialog("离开当前房间并加入新房间？", isPresented: $confirmingSwitch, titleVisibility: .visible) {
                if let pendingInvite {
                    Button("切换房间", role: .destructive) {
                        run { try await playback.joinRoom(pendingInvite, replacing: true); clearInvite() }
                    }
                }
            }
        }
    }

    @ViewBuilder private func activeRoom(_ room: NetEaseListeningRoom) -> some View {
        Section(room.kind.title) {
            if let track = playback.currentEntry?.item {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.name).font(.headline)
                    Text(track.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            } else { Text("等待房间播放").foregroundStyle(.secondary) }
            if let invite = playback.roomShareLink {
                ShareLink(item: invite.url) { Label("分享邀请", systemImage: "square.and.arrow.up") }
                NavigationLink("邀请网易云好友") {
                    NetEaseRoomContacts(playback: playback, invite: invite) { _ in }
                }.accessibilityIdentifier("netEaseRoomInviteFriend")
            }
            if room.kind == .group, room.chatID != nil {
                NavigationLink("房间聊天") { NetEaseRoomChat(playback: playback, room: room) }
            }
            if room.kind == .duet {
                if let peer = playback.duetChatPeer {
                    NavigationLink {
                        NetEaseRoomChat(playback: playback, room: room, peer: peer)
                    } label: {
                        Label("与好友聊天", systemImage: "bubble.left.and.bubble.right")
                    }.accessibilityIdentifier("netEaseDuetChat")
                } else {
                    Label("好友加入后可聊天", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                }
            }
            Button("离开房间", role: .destructive) { run { try await playback.leaveRoom() } }
                .accessibilityIdentifier("netEaseRoomLeave")
        }
        if !room.members.isEmpty {
            Section("成员") {
                ForEach(room.members) { member in Label(member.name, systemImage: "person.crop.circle") }
            }
        }
        Section("房间队列") {
            if playback.roomQueue.isEmpty { Text("暂无待播歌曲").foregroundStyle(.secondary) }
            ForEach(Array(playback.roomQueue.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accept(_ invite: NetEaseRoomInvite) {
        if let room = playback.listeningRoom, room.id != invite.room || room.kind != invite.kind {
            confirmingSwitch = true
        } else {
            run { try await playback.joinRoom(invite, replacing: false); clearInvite() }
        }
    }

    private func clearInvite() { pendingInvite = nil; pastedLink = "" }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { await perform(work) }
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
    var peer: NetEaseRoomMember? = nil
    @State private var messages: [NetEaseRoomMessage] = []
    @State private var text = ""
    @State private var error: String?
    @State private var readError: String?
    @State private var sending = false
    @State private var reading = false

    private var active: Bool {
        guard let current = playback.listeningRoom, current.id == room.id, current.kind == room.kind else { return false }
        return peer.map { playback.duetChatPeer?.id == $0.id } ?? true
    }
    private var textLimit: Int { peer == nil ? 100 : 500 }

    var body: some View {
        List {
            if peer != nil { Text("网易云私信").font(.caption).foregroundStyle(.secondary) }
            if !active { Text("房间成员已变更。").foregroundStyle(.secondary) }
            if let error = error ?? readError { Text(verbatim: error).foregroundStyle(.secondary) }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.sender).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: message.text)
                }
            }
        }
        .navigationTitle(peer.map { "与\($0.name)聊天" } ?? "房间聊天")
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("消息", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("发送") { Task { await send() } }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > textLimit)
            }
            .padding()
            .background(.regularMaterial)
            .disabled(!active)
        }
        .refreshable { await refresh() }
        .task {
            while !Task.isCancelled, active {
                if !sending { await refresh() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: active) { if !active { messages.removeAll() } }
    }

    private func refresh() async {
        guard active, !reading, let current = playback.listeningRoom else { return }
        reading = true
        defer { reading = false }
        do {
            let updated = if let peer { try await playback.roomAPI.duetMessages(current, peer: peer) }
                          else { try await playback.roomAPI.messages(current) }
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
            if let peer { try await playback.roomAPI.sendDuetMessage(current, peer: peer, text: draft) }
            else { try await playback.roomAPI.sendMessage(current, text: draft) }
            if text == draft { text = "" }
            error = nil
            await refresh()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
