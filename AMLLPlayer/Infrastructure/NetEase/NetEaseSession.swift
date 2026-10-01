import Foundation
import Observation

struct NetEaseProfile: Equatable {
    var id: String
    var name: String
    var avatar: URL?
    var vipType: Int?
}
@MainActor @Observable final class NetEaseSession: MusicSessionProviding {
    private(set) var currentState = MusicConnectionState()
    private(set) var profile: NetEaseProfile?
    private(set) var qrURL: URL?
    private(set) var qrStatus = "未登录"
    private(set) var qrExpires: Date?
    @ObservationIgnored let connectionStates: AsyncStream<MusicConnectionState>
    @ObservationIgnored private let continuation: AsyncStream<MusicConnectionState>.Continuation
    @ObservationIgnored let api: any NetEaseRequesting
    @ObservationIgnored private let store: any SpotifySessionDataStoring
    @ObservationIgnored private var cookie: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var polling: Task<Void, Never>?
    init(api: any NetEaseRequesting = NetEaseAPI(),
         store: any SpotifySessionDataStoring = KeychainSpotifySessionStore(service: "net.stevexmh.amllplayer.netease")) {
        self.api = api; self.store = store
        let stream = AsyncStream<MusicConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connectionStates = stream.stream; continuation = stream.continuation
        cookie = (try? store.load()).flatMap { String(data: $0, encoding: .utf8) }
    }
    deinit { polling?.cancel(); continuation.finish() }
    func connect() async { await beginQR() }
    func refresh() async {
        guard let cookie, !currentState.requesting else { return }
        let epoch = generation
        do {
            let response = try await api.send("/w/nuser/account/get", [:], cookie: cookie)
            guard epoch == generation, !Task.isCancelled else { return }
            install(profile: try Self.decodeProfile(response.object))
        } catch {
            guard epoch == generation, !Task.isCancelled else { return }
            let expired = error as? NetEaseError == .expired || error as? NetEaseError == .invalidCookie
            if expired { disconnect() }
            currentState.error = .musicFailure(expired ? NetEaseError.expired.localizedDescription : error.localizedDescription); publish()
        }
    }
    func importCookie(_ raw: String) async throws {
        let candidate = try NetEaseCookie.normalized(raw)
        cancelQR(); generation = UUID(); let epoch = generation
        let response = try await api.send("/w/nuser/account/get", [:], cookie: candidate)
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        let p = try Self.decodeProfile(response.object)
        try store.save(Data(candidate.utf8))
        cookie = candidate; currentState.contextID = UUID(); install(profile: p)
    }
    func disconnect() {
        generation = UUID(); cancelQR(); cookie = nil; profile = nil
        try? store.remove(); currentState = .init(); publish()
    }
    func call(_ path: String, _ parameters: [String: Any] = [:], authenticated: Bool = true) async throws -> [String: Any] {
        if authenticated, !currentState.connected { throw NetEaseError.expired }
        let epoch = generation
        do {
            let r = try await api.send(path, parameters, cookie: cookie)
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            return r.object
        } catch {
            guard epoch == generation else { throw CancellationError() }
            if error as? NetEaseError == .expired, authenticated { disconnect() }
            throw error
        }
    }
    func beginQR() async {
        cancelQR(); generation = UUID(); let epoch = generation
        currentState.requesting = true; currentState.error = nil; qrStatus = "正在生成二维码"; publish()
        do {
            let r = try await api.send("/login/qrcode/unikey", ["type": 1], cookie: nil)
            guard epoch == generation, !Task.isCancelled else { return }
            guard let key = r.object["unikey"] as? String, !key.isEmpty else { throw NetEaseError.invalidResponse }
            var url = URLComponents(string: "https://music.163.com/login")!
            url.queryItems = [URLQueryItem(name: "codekey", value: key)]
            qrURL = url.url; qrExpires = Date().addingTimeInterval(180); qrStatus = "等待扫码"
            polling = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled, epoch == generation, Date() < (qrExpires ?? .distantPast) {
                        let check = try await api.send("/login/qrcode/client/login", ["key": key, "type": 1], cookie: nil)
                        guard epoch == generation, !Task.isCancelled else { return }
                        switch check.object["code"] as? Int {
                        case 800: qrStatus = "二维码已过期，请刷新"; finishQR(); return
                        case 802: qrStatus = "已扫码，等待确认"
                        case 803:
                            guard let raw = check.cookie else { throw NetEaseError.invalidCookie }
                            let value = try NetEaseCookie.normalized(raw)
                            let account = try await api.send("/w/nuser/account/get", [:], cookie: value)
                            guard epoch == generation, !Task.isCancelled else { return }
                            let p = try Self.decodeProfile(account.object)
                            try store.save(Data(value.utf8)); cookie = value; currentState.contextID = UUID()
                            qrStatus = "登录成功"; install(profile: p); finishQR(); return
                        default: qrStatus = "等待扫码"
                        }
                        try await Task.sleep(for: .seconds(2))
                    }
                    guard epoch == generation, !Task.isCancelled else { return }
                    qrStatus = "二维码已过期，请刷新"; finishQR()
                } catch is CancellationError {} catch {
                    guard epoch == generation else { return }
                    currentState.error = .musicFailure(error.localizedDescription); finishQR()
                }
            }
        } catch {
            guard epoch == generation else { return }
            currentState.error = .musicFailure(error.localizedDescription); finishQR()
        }
    }
    func cancelQR() {
        generation = UUID(); polling?.cancel(); polling = nil; qrURL = nil; qrExpires = nil
        currentState.requesting = false; publish()
    }
    private func finishQR() { qrURL = nil; qrExpires = nil; currentState.requesting = false; publish() }
    private func install(profile p: NetEaseProfile) {
        if profile?.id != p.id { currentState.contextID = UUID() }
        profile = p; currentState.connected = true; currentState.authorization = .authorized
        currentState.error = nil
        currentState.capabilities = .init(canBrowse: true, canPlayCatalog: true, canModifyLibrary: true,
                                         canFavorite: true, canEditPlaylists: true, canEditQueue: true, canSelectQuality: true, usesSystemRoutes: true)
        publish()
    }
    private func publish() { continuation.yield(currentState) }
    static func decodeProfile(_ root: [String: Any]) throws -> NetEaseProfile {
        guard let p = root["profile"] as? [String: Any],
              let id = p["userId"] as? NSNumber, let name = p["nickname"] as? String else { throw NetEaseError.invalidCookie }
        return .init(id: id.stringValue, name: name, avatar: NetEaseDecoder.image(p["avatarUrl"]), vipType: p["vipType"] as? Int)
    }
}
