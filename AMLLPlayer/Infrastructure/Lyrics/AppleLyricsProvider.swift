import Foundation

@MainActor
final class AppleLyricsProvider: LyricsProvider {
    let source = LyricsSource.apple
    let credentials: AppleLyricsCredentials
    private let http: any LyricsHTTPProviding
    private var discovery: Task<AppleBearerInfo, Error>?
    private var discoveryID: UUID?
    private var discoveryWaiters: Set<UUID> = []
    init(http: any LyricsHTTPProviding, credentials: AppleLyricsCredentials) {
        self.http = http; self.credentials = credentials
    }

    func invalidateDiscovery() {
        discovery?.cancel(); discovery = nil; discoveryID = nil; discoveryWaiters = []
    }

    private func releaseDiscoveryWaiter(_ waiter: UUID, discoveryID id: UUID) {
        guard discoveryID == id else { return }
        discoveryWaiters.remove(waiter)
        if discoveryWaiters.isEmpty {
            invalidateDiscovery()
        }
    }

    func bearer(force: Bool = false) async throws -> AppleBearerInfo {
        if let manual = try credentials.manualToken(), !manual.isEmpty {
            return try AppleBearerInfo(manual)
        }
        if !force, let cached = try credentials.cachedBearer(), cached.expiration.timeIntervalSinceNow > 1800 {
            return cached
        }
        let generation = credentials.generation, waiter = UUID()
        let id: UUID, task: Task<AppleBearerInfo, Error>
        if let existing = discovery, let existingID = discoveryID {
            task = existing; id = existingID
        } else {
            id = UUID(); task = Task { try await discover() }
            discovery = task; discoveryID = id
        }
        discoveryWaiters.insert(waiter)
        defer { releaseDiscoveryWaiter(waiter, discoveryID: id) }
        let info = try await withTaskCancellationHandler { try await task.value } onCancel: {
            Task { @MainActor [weak self] in self?.releaseDiscoveryWaiter(waiter, discoveryID: id) }
        }
        try Task.checkCancellation()
        try credentials.saveAutomatic(info, generation: generation)
        return info
    }

    private func discover() async throws -> AppleBearerInfo {
        let pages = ["https://music.apple.com/us/browse", "https://music.apple.com/us/new", "https://music.apple.com/", "https://beta.music.apple.com/"]
        let headers = ["User-Agent": "Mozilla/5.0 AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", "Accept": "text/html,*/*"]
        var requests = 0
        for page in pages {
            try Task.checkCancellation()
            guard requests < 12 else { break }
            let data: Data
            do { requests += 1; data = try await http.data(for: LyricsRequest.make(page, headers: headers)) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            let html = String(decoding: data, as: UTF8.self)
            if let token = Self.extractBearer(html) {
                return token
            }
            let regex = try NSRegularExpression(pattern: #"(?:src\s*=\s*["']([^"']+\.js(?:\?[^"']*)?)["']|(/assets/index[^\s"'<>]*\.js))"#)
            let ns = html as NSString
            let scripts = regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(8)
            for match in scripts {
                guard requests < 12 else { break }
                let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard let url = URL(string: ns.substring(with: range), relativeTo: URL(string: page))?.absoluteURL,
                      url.scheme == "https", ["music.apple.com", "beta.music.apple.com"].contains(url.host ?? "") else { continue }
                do {
                    requests += 1
                    let script = try await http.data(for: LyricsRequest.make(url.absoluteString, headers: headers))
                    if let token = Self.extractBearer(String(decoding: script, as: UTF8.self)) {
                        return token
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
        }
        throw LyricsError.bearer
    }

    static func extractBearer(_ text: String, now: Date = Date()) -> AppleBearerInfo? {
        let decoded = text.removingPercentEncoding ?? text
        guard let regex = try? NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#) else { return nil }
        let ns = decoded as NSString
        return regex.matches(in: decoded, range: NSRange(location: 0, length: ns.length)).prefix(128)
            .compactMap { try? AppleBearerInfo(ns.substring(with: $0.range), now: now) }
            .filter(\.isWebPlay).max { $0.expiration < $1.expiration }
    }

    private enum Access { case catalog, account, lyrics }
    private func api(_ path: String, query: [String: String] = [:], access: Access = .catalog, retry: Bool = true) async throws -> [String: Any] {
        let media: String? = if access == .catalog {
            nil
        } else {
            try credentials.mediaToken()
        }
        let info = try await bearer()
        var headers = ["Authorization": "Bearer " + info.token, "Origin": info.origin, "Referer": info.origin + "/", "Accept": "application/json"]
        if access == .account {
            headers["Media-User-Token"] = media
        }
        if access == .lyrics, let media {
            headers["Cookie"] = "media-user-token=" + media
        }
        do {
            let data = try await http.data(for: LyricsRequest.make("https://amp-api.music.apple.com/v1" + path, query: query, headers: headers))
            return try LyricsRequest.object(data)
        } catch LyricsError.http(401) {
            if access == .catalog {
                if retry, try credentials.manualToken() == nil {
                    _ = try await bearer(force: true)
                    return try await api(path, query: query, access: access, retry: false)
                }
                throw LyricsError.bearer
            }
            if access == .account {
                throw LyricsError.account
            }
            do {
                _ = try await api("/catalog/us/search", query: ["types": "songs", "limit": "1", "term": "test"], retry: false)
            } catch LyricsError.bearer {
                guard retry, try credentials.manualToken() == nil else { throw LyricsError.bearer }
                _ = try await bearer(force: true)
                return try await api(path, query: query, access: .lyrics, retry: false)
            }
            _ = try await api("/me/storefront", access: .account)
            throw LyricsError.permission
        } catch LyricsError.http(403) {
            throw access == .catalog ? LyricsError.bearer : access == .account ? LyricsError.account : LyricsError.permission
        } catch LyricsError.http(404) {
            // Apple returns 404 when the catalog item has no time-synced lyric
            // resource (and for catalog/storefront misses). Treat it as a
            // candidate miss so the coordinator can try the next language or
            // lyric provider instead of surfacing a raw HTTP status.
            if access == .lyrics {
                throw LyricsError.notFound
            }
            throw LyricsError.http(404)
        }
    }

    func probeCatalog() async throws {
        _ = try await api("/catalog/us/search", query: ["types": "songs", "limit": "1", "term": "test"])
    }

    func probeAccount() async throws {
        _ = try await api("/me/storefront", access: .account)
    }

    func search(track: TrackIdentity, query: String, settings: LyricsSettings) async throws -> [LyricCandidate] {
        var songs: [[String: Any]] = []
        if query.isEmpty, let isrc = track.isrc, !isrc.isEmpty {
            let result = try await api("/catalog/\(settings.storefront)/songs", query: ["filter[isrc]": isrc])
            songs = result["data"] as? [[String: Any]] ?? []
        }
        if songs.isEmpty || !query.isEmpty {
            let result = try await api("/catalog/\(settings.storefront)/search", query: ["types": "songs", "limit": "20", "term": query.isEmpty ? track.query : query, "l": settings.language])
            let results = result["results"] as? [String: Any]
            songs += ((results?["songs"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        }
        var seen = Set<String>()
        return songs.compactMap { song -> LyricCandidate? in
            let id = LyricsRequest.id(song["id"])
            guard !id.isEmpty, seen.insert(id).inserted, let a = song["attributes"] as? [String: Any], let title = a["name"] as? String else { return nil }
            return LyricsMatcher.scored(LyricCandidate(source: .apple, sourceID: id, title: title,
                                                       artists: [(a["artistName"] as? String) ?? ""], album: (a["albumName"] as? String) ?? "",
                                                       duration: ((a["durationInMillis"] as? Double) ?? 0) / 1000, isrc: a["isrc"] as? String), against: track)
        }.sorted { $0.score > $1.score }
    }

    static func ttmlCandidates(_ value: Any, label: String = "", depth: Int = 0) -> [(String, String)] {
        guard depth < 16 else { return [] }
        if let text = value as? String {
            if text.contains("<tt") {
                return [(label, text)]
            }
            if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                return ttmlCandidates(object, label: label, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.prefix(24).enumerated().flatMap { ttmlCandidates($0.element, label: label + "[\($0.offset)]", depth: depth + 1) }.prefix(24).map(\.self)
        }
        if let object = value as? [String: Any] {
            return object.keys.sorted().prefix(24).flatMap { ttmlCandidates(object[$0]!, label: label + "." + $0, depth: depth + 1) }.prefix(24).map(\.self)
        }
        return []
    }

    func lyrics(candidate: LyricCandidate, settings: LyricsSettings) async throws -> LyricsPayload {
        guard candidate.sourceID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { throw LyricsError.malformed }
        var languages = [settings.language]
        if settings.language.lowercased().hasPrefix("zh") {
            for lang in ["zh-Hans-CN", "zh-Hans", "zh-CN", "zh-Hant-TW", "zh-Hant"] where !languages.contains(lang) {
                languages.append(lang)
            }
        }
        var best: (LyricsPayload, Int)?, lastError: Error = LyricsError.notFound
        for language in languages {
            try Task.checkCancellation()
            do {
                let result = try await api("/catalog/\(settings.storefront)/songs/\(candidate.sourceID)/syllable-lyrics", query: ["l": language, "extend": "ttmlLocalizations"], access: .lyrics)
                let item = (result["data"] as? [[String: Any]])?.first
                guard let attributes = item?["attributes"] as? [String: Any] else { throw LyricsError.notFound }
                var seen = Set<String>()
                let variants = ["ttml", "ttmlLocalizations"].flatMap { key in attributes[key].map { Self.ttmlCandidates($0, label: key) } ?? [] }
                for (label, xml) in variants where seen.insert(xml).inserted {
                    var payload = LyricsPayload(format: .ttml, original: xml, language: language, selectionReason: label)
                    do {
                        let parsePayload = payload
                        let parsing = Task.detached { try parsePayload.parse(candidate: candidate, duration: candidate.duration) }
                        let document = try await withTaskCancellationHandler { try await parsing.value } onCancel: { parsing.cancel() }
                        let translations = document.lines.filter { !$0.translation.isEmpty }.count
                        let roman = document.lines.filter { !$0.romanization.isEmpty || $0.words.contains { $0.romanWord != nil } }.count
                        let score = translations * 100_000 + roman * 1000 + document.lines.reduce(0) { $0 + $1.words.count } * 10 + document.lines.count
                        payload.selectionReason = "\(label); language=\(language); translations=\(translations); roman=\(roman); quality=\(score)"
                        if best == nil || score > best!.1 {
                            best = (payload, score)
                        }
                    } catch { lastError = error }
                }
                if let best, best.1 >= 100_000 {
                    break
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error; if error as? LyricsError == .credentials || error as? LyricsError == .permission || error as? LyricsError == .account || error as? LyricsError == .bearer {
                    break
                }
            }
        }
        guard let best else { throw lastError }
        return best.0
    }
}
