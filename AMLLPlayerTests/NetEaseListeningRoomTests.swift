@testable import AMLLPlayer
import XCTest

@MainActor final class NetEaseListeningRoomTests: XCTestCase {
    func testActivityBaselinesRosterAndQueueAndIgnoresOwnEcho() throws {
        let defaults = try activityDefaults()
        var feedback: [AppHaptics.Event] = []
        let haptics = AppHaptics(defaults: defaults, isActive: { true }, emit: { feedback.append($0) })
        let activity = NetEaseRoomActivity(defaults: defaults, haptics: haptics)
        let viewer = try XCTUnwrap(NetEaseRoomMember(["uid": 1, "nickname": "我"]))
        let friend = try XCTUnwrap(NetEaseRoomMember(["uid": 2, "nickname": "好友"]))
        var room = NetEaseListeningRoom(kind: .group, id: "room", members: [viewer])
        room.tracks = [.init(id: "11", businessID: "101")]
        activity.begin(room, account: "1")
        activity.observeRoster(room, now: 0)
        activity.observeQueue(room, now: 0, names: [:])
        XCTAssertTrue(activity.events.isEmpty)

        var partial = room
        partial.members = []
        partial.tracks = []
        partial.hasRoster = false
        partial.hasQueue = false
        activity.observeRoster(partial, now: 5)
        activity.observeQueue(partial, now: 5, names: [:])
        XCTAssertTrue(activity.events.isEmpty)

        room.members.append(friend)
        let track = NetEaseDecoder.missingTrack("42")
        activity.addedLocally(track, now: 8, alreadyQueued: false)
        room.tracks += [.init(id: "42", businessID: "102", recommenderID: "1"),
                        .init(id: "43", businessID: "103", recommenderID: "2")]
        activity.observeRoster(room, now: 10)
        activity.observeQueue(room, now: 10, names: ["43": "另一首歌"])
        activity.observeRoster(room, now: 12)
        activity.observeQueue(room, now: 12, names: [:])
        XCTAssertEqual(activity.events.map(\.text),
                       ["好友 添加了《另一首歌》", "好友 加入了房间", "你添加了《\(track.name)》"])
        XCTAssertEqual(feedback, [.success])
        activity.advanceBanner()
        XCTAssertEqual(activity.banner?.text, "好友 加入了房间")
        XCTAssertEqual(feedback, [.success, .roomActivity])
        defaults.set(false, forKey: AppHaptics.preferenceKey)
        activity.advanceBanner()
        XCTAssertEqual(activity.banner?.text, "好友 添加了《另一首歌》")
        XCTAssertEqual(feedback, [.success, .roomActivity])
        room.members.removeLast()
        activity.observeRoster(room, now: 15)
        XCTAssertEqual(activity.events.first?.text, "好友 离开了房间")
        activity.setPhase(.background)
        defaults.set(true, forKey: AppHaptics.preferenceKey)
        room.members.append(friend)
        activity.observeRoster(room, now: 20)
        XCTAssertEqual(feedback, [.success, .roomActivity])
    }

    func testDuetDurationPersistsPerAccountAndExcludesUnconfirmedGaps() throws {
        let defaults = try activityDefaults()
        let viewer = try XCTUnwrap(NetEaseRoomMember(["uid": 1]))
        let friend = try XCTUnwrap(NetEaseRoomMember(["uid": 2]))
        let room = NetEaseListeningRoom(kind: .duet, id: "room", members: [viewer, friend], heartbeat: 30)
        let activity = NetEaseRoomActivity(defaults: defaults)
        activity.begin(room, account: "1", now: 0)
        XCTAssertEqual(activity.elapsed(at: 3), 3)
        activity.observeRoster(room, now: 30)
        var partial = room
        partial.hasRoster = false
        activity.observeRoster(partial, now: 35)
        XCTAssertEqual(activity.elapsed(at: 37), 37)
        activity.connectionInterrupted()
        XCTAssertEqual(activity.elapsed(at: 300), 30)
        activity.observeRoster(room, now: 300)
        XCTAssertEqual(activity.seconds, 30)
        XCTAssertEqual(activity.elapsed(at: 304), 34)
        activity.observeRoster(room, now: 330)
        XCTAssertEqual(activity.seconds, 60)
        XCTAssertEqual(activity.elapsed(at: 332), 62)
        let restored = NetEaseRoomActivity(defaults: defaults)
        restored.begin(room, account: "1")
        XCTAssertEqual(restored.seconds, 60)
        restored.begin(room, account: "2")
        XCTAssertEqual(restored.seconds, 0)
    }

    func testOnlyNewIncomingMessagesSurfaceAndChatDestinationRoundTrips() throws {
        let activity = NetEaseRoomActivity(defaults: try activityDefaults())
        let room = NetEaseListeningRoom(kind: .duet, id: "room", members: [])
        activity.begin(room, account: "1")
        let now = Date()
        let time = Int64(now.timeIntervalSince1970 * 1_000)
        let older = NetEaseRoomMessage(id: "a", sender: "好友", text: "旧", time: time - 2)
        let incoming = NetEaseRoomMessage(id: "b", sender: "好友", text: "新", time: time - 1)
        let own = NetEaseRoomMessage(id: "c", sender: "我", text: "自己", time: time, outgoing: true)
        activity.observeMessages([older], peer: "2", receivedAt: now)
        XCTAssertNil(activity.banner)
        activity.observeMessages([older, incoming, own], peer: "2", receivedAt: now)
        activity.observeMessages([older, incoming, own], peer: "2", receivedAt: now)
        let destination = try XCTUnwrap(activity.banner?.destination)
        XCTAssertTrue(destination.chat)
        XCTAssertEqual(destination.peer, "2")
        XCTAssertEqual(NetEaseRoomDestination(destination.userInfo), destination)
        XCTAssertEqual(activity.events.count, 1)
        XCTAssertNil(activity.events.first?.preview)
        activity.setChatVisible(destination, token: UUID())
        XCTAssertNil(activity.banner)
        let newer = NetEaseRoomMessage(id: "d", sender: "好友", text: "再一条", time: time + 1)
        activity.observeMessages([incoming, own, newer], peer: "2", receivedAt: now)
        XCTAssertNil(activity.banner)
        XCTAssertEqual(activity.events.count, 2)
    }

    private func activityDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "RoomActivity-" + UUID().uuidString))
    }

    func testDuetHeartbeatUsesCurrentRoomWhenCheckOmitsMembers() async throws {
        let api = RoomFixtureAPI()
        api.duetJoined = true
        api.duetCheckOmitsMembers = true
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let service = NetEaseRoomAPI(session: session)
        let updated = try await service.update(.init(kind: .duet, id: "duet-example", members: []),
                                               position: 0, playing: false)
        XCTAssertTrue(updated.hasRoster)
        XCTAssertEqual(updated.members.map(\.id), ["1", "2"])
        XCTAssertEqual(updated.tracks.map(\.id), ["42", "43"])
    }

    func testOnlyOfficialInvitesRoundTripAndKeepTheirRoomKind() throws {
        for kind in NetEaseRoomKind.allCases {
            let invite = NetEaseRoomInvite(kind: kind, room: "example-123", inviter: "9007199254740993",
                                           song: kind == .duet ? "42" : nil)
            XCTAssertEqual(NetEaseRoomInvite.parse("邀请你一起听\n" + invite.url.absoluteString), invite)
        }
        XCTAssertNil(NetEaseRoomInvite.parse("https://st.music.163.com.example/listen-together/share/?roomId=a&inviterId=1"))
        XCTAssertNil(NetEaseRoomInvite.parse("https://st.music.163.com/listen-together/share/?roomId=a&roomId=b&inviterId=1"))
        XCTAssertNil(NetEaseRoomInvite.parse("https://st.music.163.com/listen-together/multishare/index.html?roomId=a&inviterUid=1&isFLT=true"))
        let native = "orpheus://nm/multiListenTogether/joinRoom?roomId=test&inviterId=9"
        var wrapper = URLComponents(string: "orpheus://nm/commonMessage")!
        wrapper.queryItems = [.init(name: "url1", value: native)]
        XCTAssertEqual(NetEaseRoomInvite.parse(wrapper.url!.absoluteString)?.inviter, "9")
    }

    func testEAPIRequestUsesReferenceCipherAndTrustedHost() throws {
        let path = "/listen/together/multi/match/heartbeat"
        let request = try NetEaseAPI.roomRequest(path, ["roomId": "example"], cookie: "MUSIC_U=fixture")
        XCTAssertEqual(request.url?.absoluteString, "https://interfacepc.music.163.com/eapi" + path)
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("fixture"))
        XCTAssertThrowsError(try NetEaseAPI.roomRequest("//evil.example", [:], cookie: "MUSIC_U=fixture"))
        let encrypted = try NetEaseCrypto.encryptRoom("/api" + path, ["roomId": "example"])
        XCTAssertEqual(encrypted, "6E4330E883BF6CFF05B9097AD729A456ED676A57F6D767911D1EC01E335F9F0F0B79EDF87BC81116FA8F50620F7C4AB2B6D1893708873BD6BE1E1E933F31D9920785EF571F7B585DB936FBF9513B35C61443E1D748C9D4573764F9FFBE352B0B30CF88DB8A65FE1118EB94BCB2D59DD11245BE008390D95CDBDCC6818D583330")
    }

    func testDuetCommandClockDoesNotRestartWhenRepeatedByPolling() async throws {
        let api = RoomFixtureAPI()
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let service = NetEaseRoomAPI(session: session)
        let room = NetEaseListeningRoom(kind: .duet, id: "duet-example", members: [])
        let first = try await service.update(room, position: 0, playing: false)
        let second = try await service.update(first, position: 1, playing: true)
        let clock = try XCTUnwrap(first.clock)
        XCTAssertEqual(clock.position, 5)
        XCTAssertEqual(clock.target(at: clock.sampledAt + 0.25), 5.25, accuracy: 0.001)
        XCTAssertEqual(first.clock, second.clock)
        XCTAssertEqual(second.tracks.map(\.id), ["42", "43"])
    }

    func testGroupJoinThenLeaveRestoresPersonalQueuePaused() async throws {
        let api = RoomFixtureAPI()
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ListeningRoom-" + UUID().uuidString))
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: defaults)
        playback.start()
        defer { playback.stop() }
        try await playback.enqueue(NetEaseDecoder.missingTrack("19"), next: false)
        try await playback.setRepeat(.all)
        let original = playback.queue.currentID
        try await playback.joinRoom(.init(kind: .group, room: "group-example", inviter: "2", song: nil), replacing: false)
        XCTAssertEqual(playback.listeningRoom?.id, "group-example")
        XCTAssertFalse(playback.latestSnapshot?.restrictions.canSeek ?? true)
        XCTAssertEqual(api.joinParameters?["inviterUid"] as? String, "2")
        XCTAssertEqual(api.joinParameters?["checkToken"] as? String, "fixture-check")
        try await playback.leaveRoom()
        XCTAssertNil(playback.listeningRoom)
        XCTAssertEqual(playback.queue.currentID, original)
        XCTAssertEqual(playback.queue.repeatMode, .all)
        XCTAssertEqual(playback.queue.entries.map(\.item.spotifyID), ["19"])
        XCTAssertFalse(playback.latestSnapshot?.isPlaying ?? true)
        XCTAssertNil(defaults.string(forKey: "netease.room.v1.1"))
    }

    func testDuetChatReadsBothDirectionsAndSendsOnlyToTheRoomFriend() async throws {
        let api = RoomFixtureAPI()
        api.duetJoined = true
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let service = NetEaseRoomAPI(session: session)
        let current = try await service.current(.duet)
        let room = try XCTUnwrap(current)
        let peer = try XCTUnwrap(room.chattingPeer(viewer: "1"))
        let messages = try await service.duetMessages(room, peer: peer)
        XCTAssertEqual(messages.map(\.sender), ["好友", "我"])
        XCTAssertEqual(messages.map(\.text), ["一起听吧", "好"])
        try await service.sendDuetMessage(room, peer: peer, text: "下一首")
        XCTAssertEqual(api.sentPrivateText as? [String: String],
                       ["msg": "下一首", "userIds": "[2]", "type": "text"])

        api.duetJoined = false
        do {
            try await service.sendDuetMessage(room, peer: peer, text: "迟到消息")
            XCTFail("Messages require the original room to be active")
        } catch { XCTAssertTrue(error is NetEaseRoomError) }
        XCTAssertEqual(api.sentPrivateText?["msg"] as? String, "下一首")
    }

    func testPrivateMessagesAndMusicSharesWorkWithoutARoom() async throws {
        let api = RoomFixtureAPI()
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let messaging = NetEaseMessaging(session: session)
        let page = try await messaging.conversations(offset: 0)
        let conversation = try XCTUnwrap(page.items.first)
        XCTAssertEqual(conversation.peer.id, "2")
        XCTAssertEqual(conversation.peer.avatar?.scheme, "https")
        XCTAssertEqual(conversation.preview, "分享了歌曲")
        XCTAssertEqual(conversation.unread, 2)
        XCTAssertEqual(page.next, 1)
        let peer = conversation.peer
        let history = try await messaging.history(with: peer)
        XCTAssertEqual(history.items.map(\.content), [.text("一起听吧"), .text("好")])
        XCTAssertEqual(history.next, 100)
        let older = try await messaging.history(with: peer, before: 100)
        XCTAssertEqual(older.items.map(\.content), [.song("42"), .song("43")])
        XCTAssertNil(older.next)

        try await messaging.sendSong("42", to: peer)
        XCTAssertEqual(api.privateWrites.last?["type"] as? String, "song")
        XCTAssertEqual(api.privateWrites.last?["id"] as? String, "42")

        api.sendSongError = NetEaseError.request(415)
        try await messaging.sendSong("43", to: peer)
        XCTAssertEqual(api.privateWrites.suffix(2).compactMap { $0["type"] as? String }, ["song", "text"])
        XCTAssertEqual(api.privateWrites.last?["msg"] as? String, "https://music.163.com/song?id=43")

        api.sendSongError = URLError(.timedOut)
        let count = api.privateWrites.count
        do {
            try await messaging.sendSong("44", to: peer)
            XCTFail("An ambiguous write must not fall back")
        } catch {
            XCTAssertTrue(NetEaseMessageError.mayHaveDelivered(error))
            XCTAssertEqual(api.privateWrites.count, count + 1)
        }
        XCTAssertNil(NetEaseMessaging.songLink("https://music.163.com.evil/song?id=42"))

        session.disconnect()
        do {
            try await messaging.sendText("过期会话", to: peer)
            XCTFail("A retired account context cannot send messages")
        } catch is CancellationError {
            XCTAssertEqual(api.privateWrites.count, count + 1)
        }
    }

    func testFriendInviteWaitsForRoomSwitchConsentAndReusesAnEmptyDuetAfterFailure() async throws {
        let api = RoomFixtureAPI()
        let session = NetEaseSession(api: api, store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FriendRoom-" + UUID().uuidString))
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: defaults)
        playback.start()
        defer { playback.stop() }

        let peer = try XCTUnwrap(NetEaseRoomMember(["userId": 2, "nickname": "好友"]))
        try await playback.joinRoom(.init(kind: .group, room: "group-example", inviter: "2", song: nil), replacing: false)
        guard case let .needsConfirmation(previous) = try await playback.listenWithFriend(peer) else {
            return XCTFail("Other rooms require explicit confirmation")
        }
        XCTAssertEqual(previous.kind, .group)
        XCTAssertEqual(playback.listeningRoom?.id, previous.id)
        XCTAssertTrue(api.privateWrites.isEmpty)

        api.sendInviteError = NetEaseError.rateLimited
        do {
            _ = try await playback.listenWithFriend(peer, replacing: previous)
            XCTFail("An invitation failure preserves the room and surfaces an error")
        } catch {
            XCTAssertEqual(error as? NetEaseError, .rateLimited)
        }
        XCTAssertEqual(playback.listeningRoom?.kind, .duet)
        XCTAssertEqual(api.duetCreations, 1)
        api.sendInviteError = nil
        guard case .sent(let invite) = try await playback.listenWithFriend(peer) else {
            return XCTFail("An empty duet can be reused")
        }
        XCTAssertEqual(api.duetCreations, 1)
        XCTAssertEqual(invite.room, playback.listeningRoom?.id)
        XCTAssertEqual(api.privateWrites.last?["userIds"] as? String, "[2]")
    }
}

@MainActor private final class RoomFixtureAPI: NetEaseRequesting {
    var joinParameters: [String: Any]?
    var sentPrivateText: [String: Any]?
    var privateWrites: [[String: Any]] = []
    var sendSongError: Error?
    var sendInviteError: NetEaseError?
    var duetJoined = false
    var duetCheckOmitsMembers = false
    var duetCreations = 0
    private var duet: [String: Any] {
        let viewer = ["userId": 1, "nickname": "我"] as [String: Any]
        let peer = ["userId": 2, "nickname": "好友"] as [String: Any]
        return ["roomId": "duet-example", "hostUid": 1, "roomUsers": duetCreations == 0 ? [viewer, peer] : [viewer]]
    }
    private var groupJoined = false
    private var group: [String: Any] {
        ["multiLtRoomSnapshot": ["roomId": "group-example",
            "roomPlaySongInfo": ["playSong": NSNull(), "playedTime": 0, "version": 1]],
         "heartBeatDuration": 60]
    }

    func roomCheckToken() async throws -> String { "fixture-check" }

    func send(_ path: String, _ parameters: [String: Any], cookie: String?) async throws -> NetEaseResponse {
        let data: [String: Any]
        switch path {
        case "/w/nuser/account/get":
            return .init(object: ["profile": ["userId": 1, "nickname": "Fixture"]], cookie: nil)
        case "/listen/together/status/get": data = duetJoined ? ["inRoom": true, "roomInfo": duet] : ["inRoom": false]
        case "/listen/together/room/create":
            duetCreations += 1
            duetJoined = true
            data = ["roomInfo": duet]
        case "/listen/together/heartbeat": data = [:]
        case "/listen/together/room/check":
            data = duetCheckOmitsMembers ? ["inRoom": true] : ["roomInfo": duet]
        case "/listen/together/sync/playlist/get":
            data = ["playlist": ["displayList": ["result": ["42", "43"]]],
                    "playCommand": ["targetSongId": "42", "playStatus": "PLAY", "progress": 5000, "serverSeq": 3]]
        case "/listen/together/multi/landing/info/get": data = [:]
        case "/listen/together/multi/match/status/get": data = groupJoined ? group : [:]
        case "/listen/together/multi/match/ack":
            joinParameters = parameters
            groupJoined = true
            data = group
        case "/listen/together/multi/match/heartbeat": data = group
        case "/listen/together/multi/match/exit":
            groupJoined = false
            data = [:]
        case "/msg/private/history":
            if parameters["time"] as? Int64 == 100 {
                data = ["more": false, "msgs": [
                    ["id": 4, "fromUserId": 1, "toUserId": 2, "time": 35, "msg": #"{"song":{"id":42}}"#],
                    ["id": 5, "fromUserId": 2, "toUserId": 1, "time": 50, "msg": "https://music.163.com/#/song?id=43"],
                ]]
            } else {
                data = ["more": true, "msgs": [
                    ["id": 1, "fromUser": ["userId": 2], "toUser": ["userId": 1], "time": 100, "msg": #"{"msg":"一起听吧"}"#],
                    ["id": 2, "fromUser": ["userId": 1], "toUser": ["userId": 2], "time": 200, "msg": #"{"msg":"好"}"#],
                    ["id": 3, "fromUser": ["userId": 2], "toUser": ["userId": 3], "time": 300, "msg": "他人的消息"],
                ]]
            }
        case "/msg/private/users":
            data = ["more": true, "msgs": [
                ["fromUser": ["userId": 2, "nickname": "好友", "avatarUrl": "http://p1.music.126.net/image"],
                 "toUser": ["userId": 1], "lastMsg": #"{"song":{"id":42}}"#, "lastMsgTime": 200, "newMsgCount": 2],
            ]]
        case "/msg/private/send":
            privateWrites.append(parameters)
            if parameters["type"] as? String == "song", let sendSongError { throw sendSongError }
            if (parameters["msg"] as? String)?.hasPrefix("邀请你一起听歌") == true, let sendInviteError {
                throw sendInviteError
            }
            sentPrivateText = parameters
            data = [:]
        default: throw NetEaseError.invalidResponse
        }
        return .init(object: ["code": 200, "data": data], cookie: nil)
    }
}
