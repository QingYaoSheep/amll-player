import Foundation

enum NetEaseRoomKind: String, CaseIterable, Identifiable {
    case duet, group
    var id: Self { self }
    var title: String { self == .duet ? "双人房" : "多人好友房" }
}

struct NetEaseRoomInvite: Identifiable, Equatable {
    var kind: NetEaseRoomKind
    var room: String
    var inviter: String
    var song: String?
    var id: String { kind.rawValue + ":" + room + ":" + inviter }

    var url: URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "st.music.163.com"
        url.path = kind == .duet ? "/listen-together/share/" : "/listen-together/multishare/index.html"
        url.queryItems = [
            .init(name: "roomId", value: room),
            .init(name: kind == .duet ? "inviterId" : "inviterUid", value: inviter),
        ]
        if kind == .group { url.queryItems?.append(.init(name: "isFLT", value: "false")) }
        if let song, kind == .duet { url.queryItems?.append(.init(name: "songId", value: song)) }
        return url.url!
    }

    static func parse(_ input: String) -> Self? {
        for token in input.prefix(4096).split(whereSeparator: \.isWhitespace) {
            var candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>【】「」()。，"))
            for _ in 0..<3 {
                if let invite = decode(candidate) { return invite }
                guard let decoded = candidate.removingPercentEncoding, decoded != candidate else { break }
                candidate = decoded
            }
        }
        return nil
    }

    private static func decode(_ input: String) -> Self? {
        guard let url = URLComponents(string: input), url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased() else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let kind: NetEaseRoomKind
        switch (url.scheme?.lowercased(), host, path) {
        case ("https", "st.music.163.com", "listen-together/share"),
             ("https", "st.music.163.com", "listen-together/share/index.html"),
             ("orpheus", "nm", "listentogether/joinroom"): kind = .duet
        case ("https", "st.music.163.com", "listen-together/multishare/index.html"),
             ("orpheus", "nm", "multilistentogether/joinroom"): kind = .group
        default: return nil
        }
        let fields = url.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = fields.filter { $0.name == name }
            return matches.count == 1 ? matches.first?.value : nil
        }
        guard value("isFLT") != "true",
              let room = value("roomId"), validRoom(room),
              let inviter = value(kind == .duet ? "inviterId" : "inviterUid"), numericID(inviter) != nil else { return nil }
        return .init(kind: kind, room: room, inviter: inviter, song: numericID(value("songId")))
    }

    static func validRoom(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func numericID(_ value: Any?) -> String? {
        let id = NetEaseDecoder.id(value)
        guard (1...24).contains(id.count), id.first != "0",
              id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return id
    }
}

struct NetEaseRoomMember: Identifiable, Equatable {
    var id: String
    var name: String

    init?(_ object: [String: Any]) {
        guard let id = NetEaseRoomInvite.numericID(object["uid"] ?? object["userId"]) else { return nil }
        self.id = id
        name = object["nickname"] as? String ?? "听友"
    }
}

struct NetEaseRoomTrack: Equatable {
    var id: String
    var businessID: String?
}

struct NetEaseRoomClock: Equatable {
    var track: NetEaseRoomTrack
    var position: Double
    var playing: Bool
    var version: Int64?
    var sampledAt: TimeInterval
    var forceSync = false

    func target(at now: TimeInterval) -> Double {
        position + (playing ? max(0, now - sampledAt) : 0)
    }
}

struct NetEaseListeningRoom: Identifiable, Equatable {
    var kind: NetEaseRoomKind
    var id: String
    var members: [NetEaseRoomMember]
    var tracks: [NetEaseRoomTrack] = []
    var clock: NetEaseRoomClock?
    var heartbeat: Double = 5
    var chatID: String?
    var isHost = false
}

struct NetEaseRoomMessage: Identifiable, Equatable {
    var id: String
    var sender: String
    var text: String
    var time: Int64
}

enum NetEaseRoomError: LocalizedError {
    case invalidInvite, selectSong, ended, controlsUnavailable, roomChanged, verificationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidInvite: "无法识别此网易云一起听邀请。"
        case .selectSong: "请先选择一首可以完整播放的歌曲。"
        case .ended: "好友已离开或房间已结束。"
        case .controlsUnavailable: "当前房间不支持此操作。"
        case .roomChanged: "房间状态已变化，请刷新后重试。"
        case .verificationUnavailable: "无法取得网易云操作校验，请稍后重试。"
        }
    }
}

// Wire shapes follow the MIT api-enhanced room modules and the public
// music-party interoperability records. Playback and UI use typed snapshots.
@MainActor struct NetEaseRoomAPI {
    let session: NetEaseSession
    private let prefix = "/listen/together"
    private let context: UUID

    init(session: NetEaseSession) {
        self.session = session
        context = session.currentState.contextID
    }

    func current(_ kind: NetEaseRoomKind) async throws -> NetEaseListeningRoom? {
        let data = try await call(kind == .duet ? "/status/get" : "/multi/match/status/get",
                                  mobile: kind == .group)
        return try decode(data, kind: kind)
    }

    func create(_ kind: NetEaseRoomKind, track: String?) async throws -> NetEaseListeningRoom {
        let data: [String: Any]
        if kind == .group {
            guard let track else { throw NetEaseRoomError.selectSong }
            data = try await call("/multi/room/create", [
                "type": 1, "songId": track, "groupIds": "[]", "inviteUids": "[]",
                "checkToken": try await session.roomCheckToken(),
            ])
        } else {
            data = try await call("/room/create", ["refer": "songplay_more"])
        }
        if let room = try decode(data, kind: kind) { return room }
        guard let room = try await current(kind) else { throw NetEaseError.invalidResponse }
        return room
    }

    func join(_ invite: NetEaseRoomInvite) async throws -> NetEaseListeningRoom {
        let data: [String: Any]
        if invite.kind == .group {
            let fields: [String: Any] = ["roomId": invite.room, "inviterUid": invite.inviter]
            _ = try await call("/multi/landing/info/get", fields)
            var request = fields
            request["agree"] = true
            request["checkToken"] = try await session.roomCheckToken()
            data = try await call("/multi/match/ack", request)
        } else {
            data = try await call("/play/invitation/accept", [
                "refer": "inbox_invite", "roomId": invite.room, "inviterId": invite.inviter,
            ])
        }
        let room: NetEaseListeningRoom?
        if let decoded = try decode(data, kind: invite.kind) { room = decoded }
        else { room = try await current(invite.kind) }
        guard let room, room.id == invite.room else { throw NetEaseRoomError.roomChanged }
        return room
    }

    func leave(_ room: NetEaseListeningRoom) async throws {
        _ = try await call(room.kind == .duet ? "/end/v2" : "/multi/match/exit",
                           ["roomId": room.id, "exitType": "NORMAL_END"])
    }

    func update(_ room: NetEaseListeningRoom, position: Double, playing: Bool) async throws -> NetEaseListeningRoom {
        if room.kind == .group {
            let data = try await call("/multi/match/heartbeat", ["roomId": room.id])
            if let next = try decode(data, kind: .group) {
                guard next.id == room.id else { throw NetEaseRoomError.ended }
                return next
            }
            if let next = try await current(.group), next.id == room.id { return next }
            throw NetEaseRoomError.ended
        }
        _ = try await call("/heartbeat", [
            "roomId": room.id, "songId": room.clock?.track.id ?? "0", "playStatus": playing,
            "progress": milliseconds(position),
        ])
        let data = try await call("/sync/playlist/get", ["roomId": room.id])
        let status = try await call("/room/check", ["roomId": room.id])
        var next = try decode(status, kind: .duet) ?? room
        guard next.id == room.id else { throw NetEaseRoomError.ended }
        let playlist = data["playlist"] as? [String: Any]
        let list = playlist?["displayList"] as? [String: Any]
        next.tracks = (list?["result"] as? [Any] ?? []).prefix(300).compactMap {
            NetEaseRoomInvite.numericID($0).map { .init(id: $0, businessID: nil) }
        }
        if let command = data["playCommand"] as? [String: Any],
           let id = NetEaseRoomInvite.numericID(command["targetSongId"]) ?? NetEaseRoomInvite.numericID(command["formerSongId"]),
           let state = command["playStatus"] as? String,
           let progress = Self.number(command["progress"]) {
            let sequence = Self.integer(command["serverSeq"])
            let old = room.clock
            let same = old?.track.id == id && old?.playing == (state == "PLAY") &&
                old?.position == progress / 1000 && old?.version == sequence
            next.clock = .init(track: .init(id: id, businessID: nil), position: progress / 1000,
                               playing: state == "PLAY", version: sequence,
                               sampledAt: same ? old!.sampledAt : ProcessInfo.processInfo.systemUptime)
        } else { next.clock = room.clock }
        return next
    }

    func duetCommand(_ room: NetEaseListeningRoom, _ action: String, song: String, former: String?,
                     position: Double, playing: Bool, sequence: Int64) async throws {
        let command: [String: Any] = [
            "commandType": action, "progress": milliseconds(position), "playStatus": playing ? "PLAY" : "PAUSE",
            "formerSongId": former ?? "-1", "targetSongId": song, "clientSeq": sequence,
        ]
        _ = try await call("/play/command/report", ["roomId": room.id, "commandInfo": try Self.json(command)])
    }

    func replaceDuetQueue(_ room: NetEaseListeningRoom, ids: [String], version: Int64) async throws {
        guard let owner = session.profile?.id else { throw NetEaseError.expired }
        let command: [String: Any] = [
            "commandType": "REPLACE", "version": [["userId": owner, "version": version]],
            "anchorSongId": "", "anchorPosition": -1, "randomList": ids, "displayList": ids,
        ]
        _ = try await call("/sync/list/command/report", ["roomId": room.id, "playlistParam": try Self.json(command)])
    }

    func groupSong(_ room: NetEaseListeningRoom, song: NetEaseRoomTrack, next: Bool) async throws {
        _ = try await call("/multi/match/song/operate", [
            "roomId": room.id, "songId": song.id, "bizId": song.businessID ?? "0",
            "operate": next ? 4 : 1, "checkToken": try await session.roomCheckToken(),
        ])
    }

    func contacts(offset: Int) async throws -> [NetEaseRoomMember] {
        try ensureContext()
        guard let id = session.profile?.id, NetEaseRoomInvite.numericID(id) != nil else { throw NetEaseError.expired }
        let root = try await session.call("/user/getfollows/" + id, ["offset": offset, "limit": 30, "order": true])
        guard let list = root["follow"] as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        return list.compactMap(NetEaseRoomMember.init)
    }

    func inbox(offset: Int) async throws -> [NetEaseRoomMember] {
        try ensureContext()
        let data = try await session.call("/msg/private/users", ["offset": offset, "limit": 30, "total": "true"])
        guard let messages = data["msgs"] as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        return messages.compactMap { NetEaseRoomMember($0["fromUser"] as? [String: Any] ?? $0["user"] as? [String: Any] ?? [:]) }
    }

    func invites(from peer: NetEaseRoomMember, before: Int64 = 0) async throws -> [NetEaseRoomInvite] {
        try ensureContext()
        let data = try await session.call("/msg/private/history", ["userId": peer.id, "time": before, "limit": 30, "total": "true"])
        let nested = data["data"] as? [String: Any]
        guard let messages = (data["msgs"] ?? nested?["msgs"]) as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        var seen = Set<String>()
        return messages.compactMap { row in
            let sender = row["fromUser"] as? [String: Any]
            guard NetEaseRoomInvite.numericID(sender?["userId"] ?? row["fromUserId"]) == peer.id,
                  let message = Self.object(row["msg"]) else { return nil }
            let card = message["generalMsg"] as? [String: Any]
            let textFields = [message["msg"], message["text"], card?["nativeUrl"], card?["webUrl"], card?["url"]]
            for case let text as String in textFields {
                if let invite = NetEaseRoomInvite.parse(text), invite.inviter == peer.id, seen.insert(invite.id).inserted {
                    return invite
                }
            }
            return nil
        }
    }

    func sendInvite(_ invite: NetEaseRoomInvite, to peer: NetEaseRoomMember) async throws {
        guard peer.id != session.profile?.id else { throw NetEaseRoomError.invalidInvite }
        guard try await current(invite.kind)?.id == invite.room else { throw NetEaseRoomError.roomChanged }
        try ensureContext()
        _ = try await session.call("/msg/private/send", [
            "type": "text", "msg": "邀请你一起听歌\n" + invite.url.absoluteString, "userIds": "[\(peer.id)]",
        ], roomTransport: true)
    }

    func messages(_ room: NetEaseListeningRoom) async throws -> [NetEaseRoomMessage] {
        let data = try await call("/multi/match/msg/history", [
            "roomId": room.id, "direction": 0, "page": try Self.json(["size": 50]),
        ])
        guard let records = data["records"] as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        var seen = Set<String>()
        let viewer = session.profile?.id
        return records.compactMap { row in
            if let id = row["roomId"] as? String, id != room.id { return nil }
            if let viewers = row["onlyCanSeeUserIds"] as? [Any], !viewers.isEmpty,
               !viewers.contains(where: { NetEaseRoomInvite.numericID($0) == viewer }) { return nil }
            guard let sender = NetEaseRoomInvite.numericID(row["sendUid"]),
                  let time = Self.integer(row["sendTime"]),
                  let body = Self.object(row["imChatRoomMsgBody"]),
                  let text = (body["text"] ?? body["msg"]) as? String, !text.isEmpty else { return nil }
            let id = "\(sender):\(time)"
            guard seen.insert(id).inserted else { return nil }
            return .init(id: id, sender: row["nickname"] as? String ?? "听友", text: String(text.prefix(1000)), time: time)
        }.sorted { $0.time < $1.time }
    }

    func sendMessage(_ room: NetEaseListeningRoom, text: String) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard room.kind == .group, (1...100).contains(text.utf16.count),
              let latest = try await current(.group), latest.id == room.id, let chat = latest.chatID else {
            throw NetEaseRoomError.controlsUnavailable
        }
        try ensureContext()
        _ = try await session.call("/middle/im/chatroom/send", [
            "chatroomId": chat, "msgType": 0,
            "clientExt": try Self.json(["bizType": "listenTogether", "ltType": "MULTI_MATCH_SONG", "roomId": room.id]),
            "msgBody": try Self.json(["msg": text, "msgType": 0]),
        ], roomTransport: true)
    }

    private func call(_ path: String, _ parameters: [String: Any] = [:],
                      mobile: Bool = true) async throws -> [String: Any] {
        try ensureContext()
        let root = try await session.call(prefix + path, parameters, roomTransport: mobile)
        let data = root["data"] as? [String: Any] ?? root
        if data["success"] as? Bool == false { throw NetEaseRoomError.roomChanged }
        return data
    }

    private func ensureContext() throws {
        try Task.checkCancellation()
        guard context == session.currentState.contextID else { throw CancellationError() }
    }

    func decode(_ data: [String: Any], kind: NetEaseRoomKind) throws -> NetEaseListeningRoom? {
        if data["inRoom"] as? Bool == false { return nil }
        let fields = kind == .group ? data["multiLtRoomSnapshot"] as? [String: Any] :
            data["roomInfo"] as? [String: Any]
        guard let fields = fields ?? (data["roomId"] == nil ? nil : data) else { return nil }
        let id = NetEaseDecoder.id(fields["roomId"])
        guard NetEaseRoomInvite.validRoom(id) else { throw NetEaseError.invalidResponse }
        let info = (fields["multiRoomInfoDTO"] ?? fields["roomInfo"]) as? [String: Any] ?? fields
        let users = (fields["multiLtRoomUserAgg"] ?? fields["roomUserList"]) as? [String: Any]
        let rows = (users?["onlineUserInfos"] ?? info["roomUsers"]) as? [[String: Any]] ?? []
        let host = NetEaseRoomInvite.numericID(info["hostUid"] ?? info["creatorUid"] ?? info["inviterId"])
        var members = Set<String>()
        var room = NetEaseListeningRoom(kind: kind, id: id, members: rows.compactMap(NetEaseRoomMember.init)
            .filter { members.insert($0.id).inserted })
        room.isHost = host != nil && host == session.profile?.id
        room.chatID = NetEaseRoomInvite.numericID(info["chatRoomId"])
        room.heartbeat = min(60, max(1, Self.number(data["heartBeatDuration"] ?? fields["heartBeatDuration"]) ?? 5))
        if let playback = fields["roomPlaySongInfo"] as? [String: Any] {
            let list = (playback["nextSongs"] as? [[String: Any]] ?? []).prefix(300)
            room.tracks = list.compactMap(Self.track)
            if let song = playback["playSong"] as? [String: Any], let track = Self.track(song),
               let progress = Self.number(playback["playedTime"]), let version = Self.integer(playback["version"]) {
                room.clock = .init(track: track, position: progress / 1000, playing: true, version: version,
                                   sampledAt: ProcessInfo.processInfo.systemUptime, forceSync: playback["forceSync"] as? Bool == true)
            }
        }
        return room
    }

    private static func track(_ object: [String: Any]) -> NetEaseRoomTrack? {
        guard let id = NetEaseRoomInvite.numericID(object["songId"]) else { return nil }
        return .init(id: id, businessID: NetEaseRoomInvite.numericID(object["songBizId"]))
    }

    private func milliseconds(_ value: Double) -> Int { Int(min(86_400, max(0, value.isFinite ? value : 0)) * 1000) }

    private static func number(_ value: Any?) -> Double? {
        guard let number = Double(NetEaseDecoder.id(value)), number.isFinite, number >= 0 else { return nil }
        return number
    }
    private static func integer(_ value: Any?) -> Int64? { Int64(NetEaseDecoder.id(value)) }
    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private static func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
