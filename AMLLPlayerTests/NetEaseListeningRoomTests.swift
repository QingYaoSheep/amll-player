@testable import AMLLPlayer
import XCTest

@MainActor final class NetEaseListeningRoomTests: XCTestCase {
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
}

@MainActor private final class RoomFixtureAPI: NetEaseRequesting {
    var joinParameters: [String: Any]?
    var sentPrivateText: [String: Any]?
    var duetJoined = false
    private let duet: [String: Any] = [
        "roomId": "duet-example", "roomUsers": [
            ["userId": 1, "nickname": "我"], ["userId": 2, "nickname": "好友"],
        ],
    ]
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
        case "/listen/together/heartbeat": data = [:]
        case "/listen/together/room/check": data = ["roomInfo": duet]
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
            data = ["msgs": [
                ["id": 1, "fromUser": ["userId": 2], "toUser": ["userId": 1], "time": 100, "msg": #"{"msg":"一起听吧"}"#],
                ["id": 2, "fromUser": ["userId": 1], "toUser": ["userId": 2], "time": 200, "msg": #"{"msg":"好"}"#],
                ["id": 3, "fromUser": ["userId": 2], "toUser": ["userId": 3], "time": 300, "msg": "他人的消息"],
            ]]
        case "/msg/private/send":
            sentPrivateText = parameters
            data = [:]
        default: throw NetEaseError.invalidResponse
        }
        return .init(object: ["code": 200, "data": data], cookie: nil)
    }
}
