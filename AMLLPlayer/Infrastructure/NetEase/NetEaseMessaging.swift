import Foundation

struct NetEaseConversation: Identifiable, Equatable {
    let peer: NetEaseRoomMember
    let preview: String
    let time: Int64?
    let unread: Int
    var id: String { peer.id }
}

struct NetEaseDirectMessage: Identifiable, Equatable {
    enum Content: Equatable {
        case text(String)
        case song(String)
        case invitation(NetEaseRoomInvite)
        case unsupported
    }

    let id: String
    let outgoing: Bool
    let time: Int64
    let content: Content

    var preview: String { content.preview }
    var date: Date { Date(timeIntervalSince1970: Double(time) / 1_000) }
}

extension NetEaseDirectMessage.Content {
    var preview: String {
        switch self {
        case .text(let text): text
        case .song: "分享了歌曲"
        case .invitation: "邀请一起听"
        case .unsupported: "在网易云音乐查看此消息"
        }
    }
}

struct NetEaseMessagePage<Item> {
    let items: [Item]
    // Advance using the wire page, including entries omitted by local validation.
    let next: Int64?
}

enum NetEaseMessageError: LocalizedError {
    case invalidRecipient, invalidText, deliveryUnknown

    var errorDescription: String? {
        switch self {
        case .invalidRecipient: "无法向此用户发送网易云私信。"
        case .invalidText: "请输入 1–500 字的消息。"
        case .deliveryUnknown: "尚未确认是否发送成功，请检查会话记录。"
        }
    }

    static func mayHaveDelivered(_ error: Error) -> Bool {
        if error is URLError || error is DecodingError { return true }
        if let error = error as? NetEaseError {
            if case let .request(code) = error { return (500...599).contains(code) }
            return error == .invalidResponse
        }
        // A successful HTTP response can still contain an invalid JSON body.
        return (error as NSError).domain == NSCocoaErrorDomain
    }
}

@MainActor struct NetEaseMessaging {
    let session: NetEaseSession
    private let context: UUID
    private let pageSize = 30

    init(session: NetEaseSession) {
        self.session = session
        context = session.currentState.contextID
    }

    private func viewer() throws -> String {
        try Task.checkCancellation()
        guard context == session.currentState.contextID else { throw CancellationError() }
        guard session.currentState.connected, let id = NetEaseRoomInvite.numericID(session.profile?.id) else {
            throw NetEaseError.expired
        }
        return id
    }

    private func recipient(_ peer: NetEaseRoomMember) throws -> String {
        let account = try viewer()
        guard NetEaseRoomInvite.numericID(peer.id) != nil, peer.id != account else {
            throw NetEaseMessageError.invalidRecipient
        }
        return account
    }

    func contacts(offset: Int64) async throws -> NetEaseMessagePage<NetEaseRoomMember> {
        let account = try viewer()
        let response = try await session.call("/user/getfollows/" + account, [
            "limit": pageSize, "offset": offset, "order": true,
        ])
        _ = try viewer()
        guard let rows = response["follow"] as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        return .init(items: rows.compactMap(NetEaseRoomMember.init).filter { $0.id != account },
                     next: offsetAfter(offset, rows: rows, response: response))
    }

    func conversations(offset: Int64) async throws -> NetEaseMessagePage<NetEaseConversation> {
        let account = try viewer()
        let root = try await session.call("/msg/private/users", ["offset": offset, "limit": pageSize, "total": "true"])
        _ = try viewer()
        let response = root["data"] as? [String: Any] ?? root
        guard let rows = response["msgs"] as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        let items = rows.compactMap { row -> NetEaseConversation? in
            let from = row["fromUser"] as? [String: Any]
            let to = row["toUser"] as? [String: Any]
            let sender = NetEaseRoomInvite.numericID(from?["userId"] ?? row["fromUserId"])
            let other = sender == account ? to : from
            let detail = Self.object(row["lastMsg"])
            guard let peer = NetEaseRoomMember(other ?? row["user"] as? [String: Any] ?? [:]),
                  peer.id != account else { return nil }
            let content = Self.content(row["lastMsg"] ?? row["msg"])
            return .init(peer: peer, preview: content.preview,
                         time: Self.integer(row["lastMsgTime"] ?? row["time"] ?? detail?["time"]),
                         unread: max(0, Int(Self.integer(row["newMsgCount"]) ?? 0)))
        }
        return .init(items: items, next: offsetAfter(offset, rows: rows, response: response))
    }

    func history(with peer: NetEaseRoomMember, before: Int64 = 0) async throws -> NetEaseMessagePage<NetEaseDirectMessage> {
        let account = try recipient(peer)
        let root = try await session.call("/msg/private/history", [
            "userId": peer.id, "time": before, "limit": pageSize, "total": "true",
        ])
        _ = try recipient(peer)
        let response = root["data"] as? [String: Any] ?? root
        guard let rows = response["msgs"] as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        var seen = Set<String>()
        let items = rows.compactMap { row -> NetEaseDirectMessage? in
            let from = row["fromUser"] as? [String: Any]
            let to = row["toUser"] as? [String: Any]
            guard let sender = NetEaseRoomInvite.numericID(from?["userId"] ?? row["fromUserId"]),
                  let target = NetEaseRoomInvite.numericID(to?["userId"] ?? row["toUserId"]),
                  (sender == account && target == peer.id) || (sender == peer.id && target == account),
                  let time = Self.integer(row["time"]), time > 0 else { return nil }
            let body = Self.content(row["msg"], nativeURL: row["nativeUrl"] as? String)
            if case .invitation(let invite) = body, invite.inviter != sender { return nil }
            let id = NetEaseRoomInvite.numericID(row["id"]) ?? "\(sender):\(time):\(body)"
            guard seen.insert(id).inserted else { return nil }
            return .init(id: id, outgoing: sender == account, time: time, content: body)
        }.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        let oldest = rows.compactMap { Self.integer($0["time"]) }.filter { $0 > 0 }.min()
        let next = hasMore(rows: rows, response: response) && oldest.map({ before == 0 || $0 < before }) == true
            ? oldest : nil
        return .init(items: items, next: next)
    }

    func sendText(_ raw: String, to peer: NetEaseRoomMember) async throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...500).contains(text.utf16.count) else { throw NetEaseMessageError.invalidText }
        try await send(["type": "text", "msg": text], to: peer)
    }

    func sendSong(_ song: String, to peer: NetEaseRoomMember) async throws {
        guard NetEaseRoomInvite.numericID(song) != nil else { throw NetEaseError.invalidResponse }
        do {
            try await send(["id": song, "type": "song", "msg": ""], to: peer)
        } catch let NetEaseError.request(code) where [404, 415, 501].contains(code) {
            try await sendText("https://music.163.com/song?id=" + song, to: peer)
        }
    }

    private func send(_ fields: [String: Any], to peer: NetEaseRoomMember) async throws {
        _ = try recipient(peer)
        var parameters = fields
        parameters["userIds"] = "[\(peer.id)]"
        _ = try await session.call("/msg/private/send", parameters, roomTransport: true)
        _ = try recipient(peer)
    }

    private func offsetAfter(_ offset: Int64, rows: [[String: Any]], response: [String: Any]) -> Int64? {
        hasMore(rows: rows, response: response) ? offset + Int64(rows.count) : nil
    }

    private func hasMore(rows: [[String: Any]], response: [String: Any]) -> Bool {
        !rows.isEmpty && ((response["more"] as? Bool ?? response["hasMore"] as? Bool) ?? (rows.count >= pageSize))
    }

    private static func content(_ raw: Any?, nativeURL: String? = nil) -> NetEaseDirectMessage.Content {
        let payload = object(raw)
        let text = (payload?["msg"] ?? payload?["text"]) as? String ?? (payload == nil ? raw as? String : nil)
        let card = object(payload?["generalMsg"])
        for candidate in [nativeURL, text, payload?["nativeUrl"] as? String, card?["nativeUrl"] as? String,
                          card?["webUrl"] as? String, card?["url"] as? String].compactMap({ $0 }) {
            if let invite = NetEaseRoomInvite.parse(candidate) { return .invitation(invite) }
        }
        let song = object(payload?["song"])
        let nestedTrack = object(song?["song"])
        if let id = NetEaseRoomInvite.numericID(song?["id"] ?? nestedTrack?["id"]
            ?? ((payload?["type"] as? String == "song") ? payload?["id"] : nil)) {
            return .song(id)
        }
        if let text, let id = songLink(text) { return .song(id) }
        if let text, !text.isEmpty { return .text(String(text.prefix(8_000))) }
        return .unsupported
    }

    static func songLink(_ text: String) -> String? {
        guard text.utf8.count < 2_048,
              let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "music.163.com",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let route = url.fragment.flatMap(URLComponents.init(string:)) ?? url
        guard route.path == "/song" || route.path == "/m/song" else { return nil }
        let ids = route.queryItems?.filter { $0.name == "id" } ?? []
        return ids.count == 1 ? NetEaseRoomInvite.numericID(ids.first?.value) : nil
    }

    private static func integer(_ value: Any?) -> Int64? { Int64(NetEaseDecoder.id(value)) }

    private static func object(_ raw: Any?) -> [String: Any]? {
        if let fields = raw as? [String: Any] { return fields }
        guard let text = raw as? String, text.utf8.count <= 32_768 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
