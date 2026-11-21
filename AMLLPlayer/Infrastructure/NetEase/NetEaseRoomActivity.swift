import Foundation
import Observation
import UserNotifications

struct NetEaseRoomDestination: Equatable, Sendable {
    let account: String
    let roomID: String
    let kind: NetEaseRoomKind
    var chat = false
    var peer: String?

    var userInfo: [String: String] {
        ["neteaseRoom": roomID, "kind": kind.rawValue, "account": account,
         "chat": chat ? "1" : "0", "peer": peer ?? ""]
    }

    init(account: String, room: NetEaseListeningRoom, chat: Bool = false, peer: String? = nil) {
        self.account = account
        roomID = room.id
        kind = room.kind
        self.chat = chat
        self.peer = peer
    }

    init?(_ userInfo: [AnyHashable: Any]) {
        guard let room = userInfo["neteaseRoom"] as? String, NetEaseRoomInvite.validRoom(room),
              let rawKind = userInfo["kind"] as? String, let kind = NetEaseRoomKind(rawValue: rawKind),
              let account = NetEaseRoomInvite.numericID(userInfo["account"]) else { return nil }
        self.account = account
        roomID = room
        self.kind = kind
        chat = userInfo["chat"] as? String == "1"
        peer = NetEaseRoomInvite.numericID(userInfo["peer"])
    }
}

struct NetEaseRoomEvent: Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
    let destination: NetEaseRoomDestination?
    var preview: String?
}

@MainActor @Observable
final class NetEaseRoomActivity {
    private(set) var events: [NetEaseRoomEvent] = []
    private(set) var banner: NetEaseRoomEvent?
    private(set) var seconds = 0
    private(set) var systemStatus: UNAuthorizationStatus = .notDetermined
    private var wantsSystemAlerts: Bool
    var systemAlertsEnabled: Bool { wantsSystemAlerts && Self.allowsAlerts(systemStatus) }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var room: NetEaseRoomDestination?
    @ObservationIgnored private var previous: NetEaseListeningRoom?
    @ObservationIgnored private var timeSample: (value: TimeInterval, peer: String?)?
    @ObservationIgnored private var sessionSeconds = 0.0
    @ObservationIgnored private var chatBaseline: (peer: String?, time: Int64, ids: Set<String>)?
    @ObservationIgnored private var visibleChats: [UUID: NetEaseRoomDestination] = [:]
    @ObservationIgnored private var localAdds: [String: [TimeInterval]] = [:]
    @ObservationIgnored private var pendingBanners: [NetEaseRoomEvent] = []
    @ObservationIgnored private var phase: DeliveryPhase = .foreground
    @ObservationIgnored private var messageSilenceUntil = Date.distantPast
    private static let settingsKey = "netease.room.systemAlerts"

    enum DeliveryPhase { case foreground, inactive, background }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        wantsSystemAlerts = defaults.bool(forKey: Self.settingsKey)
    }

    var savedSystemAlertsPreference: Bool { wantsSystemAlerts }

    func setPhase(_ phase: DeliveryPhase) {
        guard phase != self.phase else { return }
        if phase == .foreground {
            // A resumed request can return a backlog from the suspended interval.
            messageSilenceUntil = Date().addingTimeInterval(2)
        } else {
            banner = nil
            pendingBanners.removeAll()
        }
        self.phase = phase
    }

    func refreshAuthorization() async {
        systemStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func setSystemAlerts(_ enabled: Bool) async {
        if enabled, systemStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        }
        await refreshAuthorization()
        wantsSystemAlerts = enabled
        defaults.set(wantsSystemAlerts, forKey: Self.settingsKey)
    }

    private static func allowsAlerts(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    func begin(_ snapshot: NetEaseListeningRoom, account: String) {
        reset()
        room = .init(account: account, room: snapshot)
        seconds = Int(storedSeconds(peer: snapshot.chattingPeer(viewer: account)?.id) / 60) * 60
    }

    func reset() {
        if room != nil {
            let center = UNUserNotificationCenter.current()
            let ids = events.map { $0.id.uuidString }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
        room = nil
        previous = nil
        seconds = 0
        sessionSeconds = 0
        timeSample = nil
        chatBaseline = nil
        localAdds.removeAll()
        events.removeAll()
        banner = nil
        pendingBanners.removeAll()
    }

    func connectionInterrupted() { timeSample = nil }

    // Two adjacent confirmed rosters bound each counted interval.
    func observe(_ snapshot: NetEaseListeningRoom, now: TimeInterval, names: [String: String] = [:]) {
        guard let room, snapshot.id == room.roomID, snapshot.kind == room.kind else { return }
        if snapshot.hasRoster { updateDuration(snapshot, account: room.account, now: now) }
        else { connectionInterrupted() }
        let old = previous
        var baseline = snapshot
        if !snapshot.hasRoster, let old {
            baseline.members = old.members
            baseline.hasRoster = old.hasRoster
        }
        if !snapshot.hasQueue, let old {
            baseline.tracks = old.tracks
            baseline.hasQueue = old.hasQueue
        }
        previous = baseline
        guard let old else { return }

        if old.hasRoster, snapshot.hasRoster {
            let oldMembers = Set(old.members.map(\.id))
            let members = Set(snapshot.members.map(\.id))
            for member in snapshot.members where member.id != room.account && !oldMembers.contains(member.id) {
                publish(.init(text: "\(member.name) 加入了房间", symbol: "person.badge.plus", destination: room))
            }
            for member in old.members where member.id != room.account && !members.contains(member.id) {
                publish(.init(text: "\(member.name) 离开了房间", symbol: "person.badge.minus", destination: room))
            }
        }

        guard old.hasQueue, snapshot.hasQueue else { return }
        let additions = addedTracks(from: old, to: snapshot, now: now)
        for group in Dictionary(grouping: additions, by: { $0.recommenderID ?? "" }).values
            .sorted(by: { ($0.first?.recommenderID ?? "") < ($1.first?.recommenderID ?? "") }) {
            let titles = group.compactMap { names[$0.id] }
            let subject = baseline.members.first { $0.id == group.first?.recommenderID }
                .map { $0.id == room.account ? "你添加了" : "\($0.name) 添加了" } ?? "队列新增"
            let song = group.count == 1 && titles.count == 1 ? "《\(titles[0])》" : "\(group.count) 首歌曲"
            publish(.init(text: "\(subject)\(song)", symbol: "music.note.list", destination: room))
        }
    }

    private func addedTracks(from old: NetEaseListeningRoom, to next: NetEaseListeningRoom, now: TimeInterval) -> [NetEaseRoomTrack] {
        localAdds = localAdds.mapValues { $0.filter { $0 > now } }.filter { !$0.value.isEmpty }
        var counts: [String: Int] = [:]
        for track in old.tracks { counts[track.queueIdentity, default: 0] += 1 }
        return next.tracks.filter { track in
            if counts[track.queueIdentity, default: 0] > 0 {
                counts[track.queueIdentity, default: 0] -= 1
                return false
            }
            // A recommendation can carry the same song ID as a different queue entry.
            if (track.recommenderID == nil || track.recommenderID == room?.account),
               var receipts = localAdds[track.id], !receipts.isEmpty {
                receipts.removeFirst()
                localAdds[track.id] = receipts
                return false
            }
            return true
        }
    }

    func addedLocally(_ item: MusicCatalogItem, now: TimeInterval, alreadyQueued: Bool) {
        guard let room else { return }
        if !alreadyQueued { localAdds[item.spotifyID, default: []].append(now + 120) }
        let text = alreadyQueued ? "《\(item.name)》已在房间队列中" : "你添加了《\(item.name)》"
        publish(.init(text: text, symbol: "checkmark.circle", destination: room),
                system: false)
    }

    func end(text: String) {
        reset()
        publish(.init(text: text, symbol: "headphones", destination: nil))
    }

    func status(_ text: String, symbol: String) {
        guard let room else { return }
        publish(.init(text: text, symbol: symbol, destination: room), system: false)
    }

    func setChatVisible(_ destination: NetEaseRoomDestination?, token: UUID) {
        visibleChats[token] = destination
        if let destination { pendingBanners.removeAll { $0.destination == destination } }
        if let destination, banner?.destination == destination { advanceBanner() }
    }

    func observeMessages(_ messages: [NetEaseRoomMessage], peer: String?, receivedAt: Date) {
        guard var destination = room else { return }
        destination.chat = true
        destination.peer = peer
        let ids = Set(messages.map(\.id))
        guard let baseline = chatBaseline, baseline.peer == peer else {
            chatBaseline = (peer, messages.map(\.time).max() ?? 0, ids)
            return
        }
        let incoming = messages.filter { !$0.outgoing && $0.time >= baseline.time && !baseline.ids.contains($0.id) }
        let latest = messages.map(\.time).max() ?? 0
        // Keep IDs tied at the watermark, including partial results on retry.
        chatBaseline = (peer, max(latest, baseline.time), latest > baseline.time ? ids : baseline.ids.union(ids))
        guard let last = incoming.last else { return }
        let text = incoming.count == 1 ? "\(last.sender) 发来消息" : "收到 \(incoming.count) 条新消息"
        let age = receivedAt.timeIntervalSince1970 - Double(last.time) / 1_000
        let reading = visibleChats.values.contains(destination)
        let present = phase == .background || (!reading && age < 30 && receivedAt >= messageSilenceUntil)
        publish(.init(text: text, symbol: "bubble.left.and.bubble.right", destination: destination,
                      preview: last.text), present: present)
    }

    private func updateDuration(_ snapshot: NetEaseListeningRoom, account: String, now: TimeInterval) {
        let peer = snapshot.chattingPeer(viewer: account)?.id
        let together = snapshot.members.contains { $0.id != account } && (snapshot.kind == .group || peer != nil)
        guard together else { timeSample = nil; return }
        let previous = timeSample
        timeSample = (now, peer)
        var total = peer == nil ? sessionSeconds : storedSeconds(peer: peer)
        if let previous, previous.peer == peer, now >= previous.value,
           now - previous.value <= snapshot.heartbeat * 2 + 5 {
            total += now - previous.value
            if let key = durationKey(peer: peer) { defaults.set(total, forKey: key) }
            else { sessionSeconds = total }
        }
        let wholeMinutes = Int(total / 60) * 60
        if seconds != wholeMinutes { seconds = wholeMinutes }
    }

    private func durationKey(peer: String?) -> String? {
        guard let room, let peer else { return nil }
        return "netease.room.seconds.\(room.account).\(peer)"
    }

    private func storedSeconds(peer: String?) -> Double {
        guard let key = durationKey(peer: peer) else { return 0 }
        let value = defaults.double(forKey: key)
        return value.isFinite && value >= 0 && value < Double(Int32.max) ? value : 0
    }

    func advanceBanner() {
        banner = pendingBanners.isEmpty ? nil : pendingBanners.removeFirst()
    }

    private func publish(_ event: NetEaseRoomEvent, system: Bool = true, present: Bool = true) {
        // Keep private message text out of the persistent room log.
        var record = event
        record.preview = nil
        events.insert(record, at: 0)
        if events.count > 30 { events.removeLast() }
        guard present else { return }
        if phase == .foreground {
            if banner == nil { banner = event }
            else {
                pendingBanners.append(event)
                if pendingBanners.count > 4 { pendingBanners.removeFirst() }
            }
        } else if phase == .background, system, systemAlertsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "与好友一起听"
            content.body = event.text
            content.userInfo = event.destination?.userInfo ?? [:]
            let request = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}
