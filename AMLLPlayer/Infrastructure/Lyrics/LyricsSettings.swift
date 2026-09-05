import Foundation

struct LyricsSettings: Codable, Equatable, Sendable {
    var version = 1
    var enabled = true
    var priority: [LyricsSource] = [.apple, .qq, .netease]
    var storefront = "us"
    var language = "zh-Hans-CN"
    var cacheEnabled = true
    var refreshDays = 30

    func validated() -> LyricsSettings {
        var value = self
        value.version = 1
        value.priority = priority.reduce(into: []) {
            if !$0.contains($1) {
                $0.append($1)
            }
        }
        for source in LyricsSource.allCases where !value.priority.contains(source) {
            value.priority.append(source)
        }
        value.storefront = storefront.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.storefront.range(of: #"^[a-z]{2}$"#, options: .regularExpression) == nil {
            value.storefront = "us"
        }
        value.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.language.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) == nil {
            value.language = "zh-Hans-CN"
        }
        value.refreshDays = max(0, min(3650, refreshDays))
        return value
    }
}

@MainActor
final class LyricsSettingsStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LyricsSettings {
        guard let data = defaults.data(forKey: "lyrics.settings.v1"),
              let value = try? JSONDecoder().decode(LyricsSettings.self, from: data) else { return LyricsSettings() }
        return value.validated()
    }

    func save(_ value: LyricsSettings) throws {
        try defaults.set(JSONEncoder().encode(value.validated()), forKey: "lyrics.settings.v1")
    }
}

struct AppleBearerInfo: Sendable {
    let token: String
    let expiration: Date
    let origin: String
    let isWebPlay: Bool
    /// This inspects claims, not a cryptographic signature verification.
    init(_ value: String, now: Date = Date()) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"(?i)^Bearer\s+"#, with: "", options: .regularExpression)
        let parts = token.split(separator: ".")
        guard parts.count == 3, token.utf8.count < 20000,
              token.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw LyricsError.bearer }
        func object(_ part: Substring) throws -> [String: Any] {
            var base = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base += String(repeating: "=", count: (4 - base.count % 4) % 4)
            guard let data = Data(base64Encoded: base), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsError.bearer }
            return object
        }
        let header = try object(parts[0]), claims = try object(parts[1])
        guard let expiry = claims["exp"] as? Double, expiry.isFinite, expiry > now.timeIntervalSince1970 + 60 else { throw LyricsError.bearer }
        self.token = token; expiration = Date(timeIntervalSince1970: expiry)
        let claimOrigin = (claims["root_https_origin"] as? String) ?? ""
        origin = ["https://music.apple.com", "https://beta.music.apple.com"].contains(claimOrigin) ? claimOrigin : "https://music.apple.com"
        isWebPlay = (claims["iss"] as? String)?.lowercased() == "ampwebplay" || (header["kid"] as? String)?.lowercased() == "webplaykid"
    }
}

@MainActor
final class AppleLyricsCredentials {
    private let manual: any SpotifySessionDataStoring
    private let media: any SpotifySessionDataStoring
    private let automatic: any SpotifySessionDataStoring
    private(set) var generation = UUID()
    init(manual: any SpotifySessionDataStoring = KeychainSpotifySessionStore(service: "net.stevexmh.amllplayer.lyrics", account: "manual-bearer"),
         media: any SpotifySessionDataStoring = KeychainSpotifySessionStore(service: "net.stevexmh.amllplayer.lyrics", account: "media-user-token"),
         automatic: any SpotifySessionDataStoring = KeychainSpotifySessionStore(service: "net.stevexmh.amllplayer.lyrics", account: "automatic-bearer"))
    {
        self.manual = manual; self.media = media; self.automatic = automatic
    }

    func manualToken() throws -> String? {
        try manual.load().flatMap { String(data: $0, encoding: .utf8) }
    }

    func mediaToken() throws -> String {
        guard let data = try media.load(), let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw LyricsError.credentials }
        return value
    }

    func cachedBearer() throws -> AppleBearerInfo? {
        guard let value = try automatic.load().flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return try? AppleBearerInfo(value)
    }

    func saveManual(_ value: String) throws {
        generation = UUID()
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try manual.remove()
        } else {
            try manual.save(Data(AppleBearerInfo(value).token.utf8))
        }
    }

    func saveMedia(_ value: String) throws {
        generation = UUID()
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count < 20000, !token.contains(";"), !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw LyricsError.credentials }
        if token.isEmpty {
            try media.remove()
        } else {
            try media.save(Data(token.utf8))
        }
    }

    func saveAutomatic(_ info: AppleBearerInfo, generation expected: UUID) throws {
        guard generation == expected else { throw CancellationError() }
        try automatic.save(Data(info.token.utf8))
    }

    func clearAutomatic() throws {
        generation = UUID(); try automatic.remove()
    }

    func clearAll() throws {
        generation = UUID()
        // Attempt every deletion even if an individual Keychain item fails.
        var failed = false
        for store in [manual, media, automatic] {
            do { try store.remove() } catch { failed = true }
        }
        if failed {
            throw LyricsError.credentials
        }
    }
}
