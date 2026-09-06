import Foundation

@MainActor
final class QQLyricsProvider: LyricsProvider {
    let source = LyricsSource.qq
    private let http: any LyricsHTTPProviding
    private let headers = ["Origin": "https://y.qq.com", "Referer": "https://y.qq.com/"]
    init(http: any LyricsHTTPProviding) {
        self.http = http
    }

    private func request(_ url: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await http.data(for: LyricsRequest.make(url, query: query, headers: headers, body: body))
        return try LyricsRequest.object(data)
    }

    /// QQ has returned the same lyric payload under `lrc`, `lyric`, and a
    /// nested `{ lyric: ... }` object over time. Keep the provider tolerant of
    /// those wire variants while still rejecting encrypted/non-LRC data below.
    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let value = value as? [String: Any] {
            for key in ["lrc", "lyric", "text", "content"] {
                if let nested = value[key] {
                    let result = stringValue(nested)
                    if !result.isEmpty {
                        return result
                    }
                }
            }
        }
        return ""
    }

    private static func decoded(_ value: Any?) -> String {
        let raw = stringValue(value)
        guard !raw.isEmpty else { return "" }
        return (try? LRCLyricsParser.decodeField(raw)) ?? ""
    }

    private static func decryptedOrDecoded(_ value: Any?) -> String {
        let raw = stringValue(value)
        guard !raw.isEmpty else { return "" }
        if let decrypted = QQRCDecoder.decrypt(raw) {
            return decrypted
        }
        return (try? LRCLyricsParser.decodeField(raw)) ?? ""
    }

    private static func isEnabled(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        if let value = value as? Int {
            return value != 0
        }
        if let value = value as? String {
            return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
        }
        return false
    }

    func search(track: TrackIdentity, query: String, settings _: LyricsSettings) async throws -> [LyricCandidate] {
        let query = query.isEmpty ? track.query : query
        var songs: [[String: Any]] = []
        do {
            let result = try await request("https://u.y.qq.com/cgi-bin/musicu.fcg", body: ["req_1": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService", "param": ["num_per_page": 20, "page_num": 1, "query": query, "search_type": 0]]])
            let data = (result["req_1"] as? [String: Any])?["data"] as? [String: Any]
            let body = data?["body"] as? [String: Any]
            songs = ((body?["song"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        } catch is CancellationError { throw CancellationError() }
        catch { /* One bounded fallback to the legacy search endpoint. */ }
        if songs.isEmpty {
            let result = try await request("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", query: ["w": query, "format": "json", "p": "1", "n": "20", "t": "0"])
            let data = result["data"] as? [String: Any]
            songs = ((data?["song"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
            if let code = result["code"] as? Int, code != 0 {
                throw LyricsError.malformed
            }
        }
        var seen = Set<String>()
        return songs.compactMap { song -> LyricCandidate? in
            let mid = LyricsRequest.id(song["mid"] ?? song["songmid"]), numeric = LyricsRequest.id(song["id"] ?? song["songid"])
            let id = mid.isEmpty ? numeric : mid
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let singers = (song["singer"] as? [[String: Any]]) ?? (song["singers"] as? [[String: Any]]) ?? []
            let album = song["album"] as? [String: Any]
            let candidate = LyricCandidate(source: .qq, sourceID: id, numericID: numeric, title: (song["title"] as? String) ?? (song["songname"] as? String) ?? (song["name"] as? String) ?? "",
                                           artists: singers.compactMap { $0["name"] as? String }, album: (album?["name"] as? String) ?? (song["albumname"] as? String) ?? "", duration: (song["interval"] as? NSNumber).map(\.doubleValue) ?? (song["interval"] as? Double) ?? 0)
            return LyricsMatcher.scored(candidate, against: track)
        }.sorted { $0.score > $1.score }
    }

    func lyrics(candidate: LyricCandidate, settings _: LyricsSettings) async throws -> LyricsPayload {
        var original = "", translation = "", roman = ""
        do {
            let result = try await request("https://u.y.qq.com/cgi-bin/musicu.fcg", body: ["comm": ["ct": 19, "cv": 0, "tmeAppID": "qqmusiclight"], "req_0": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo", "param": ["songMID": candidate.sourceID, "songID": Int(candidate.numericID ?? "") ?? 0, "platform": 0, "needNew": 1, "crypt": 1, "qrc": 1, "trans": 1, "roma": 1]]])
            let data = (result["req_0"] as? [String: Any])?["data"] as? [String: Any]
            if Self.isEnabled(data?["qrc"]),
               let decrypted = QQRCDecoder.decrypt(Self.stringValue(data?["lyric"])),
               let qrcLines = try? QQRCDecoder.parse(decrypted, duration: candidate.duration),
               !qrcLines.isEmpty
            {
                let translation = Self.decryptedOrDecoded(data?["trans"])
                let roman = Self.decryptedOrDecoded(data?["roma"])
                return LyricsPayload(format: .qrc, original: decrypted, translation: translation, romanization: roman,
                                     selectionReason: "QQ synchronized word timings")
            }
            original = Self.decoded(data?["lrc"] ?? data?["lyric"])
            translation = Self.decoded(data?["trans"])
            roman = Self.decoded(data?["roma"])
            if (try? LRCLyricsParser.rows(original).isEmpty) != false {
                original = ""
            }
        } catch is CancellationError { throw CancellationError() }
        catch { original = "" }
        if original.isEmpty {
            let result = try await request("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", query: ["songmid": candidate.sourceID, "format": "json", "nobase64": "1", "g_tk": "5381", "loginUin": "0", "hostUin": "0", "inCharset": "utf8", "outCharset": "utf-8", "notice": "0", "platform": "yqq", "needNewCode": "0"])
            if let code = result["code"] as? Int, code != 0 {
                throw LyricsError.malformed
            }
            original = Self.decoded(result["lyric"] ?? result["lrc"])
            translation = Self.decoded(result["trans"])
            roman = Self.decoded(result["roma"])
        }
        guard !original.isEmpty else { throw LyricsError.notFound }
        return LyricsPayload(format: .lrc, original: original, translation: translation, romanization: roman, selectionReason: "QQ synchronized lines")
    }
}

@MainActor
final class NetEaseLyricsProvider: LyricsProvider {
    let source = LyricsSource.netease
    private let http: any LyricsHTTPProviding
    init(http: any LyricsHTTPProviding) {
        self.http = http
    }

    private func request(_ path: String, query: [String: String]) async throws -> [String: Any] {
        let data = try await http.data(for: LyricsRequest.make("https://music.163.com/api" + path, query: query, headers: ["Referer": "https://music.163.com/", "Origin": "https://music.163.com"]))
        let result = try LyricsRequest.object(data)
        if let code = result["code"] as? Int, code != 200 {
            throw LyricsError.http(code)
        }
        return result
    }

    func search(track: TrackIdentity, query: String, settings _: LyricsSettings) async throws -> [LyricCandidate] {
        let result = try await request("/search/get/web", query: ["s": query.isEmpty ? track.query : query, "type": "1", "offset": "0", "total": "true", "limit": "20"])
        let songs = ((result["result"] as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return songs.compactMap { song -> LyricCandidate? in
            let id = LyricsRequest.id(song["id"])
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let artists = (song["artists"] as? [[String: Any]]) ?? (song["ar"] as? [[String: Any]]) ?? []
            let album = (song["album"] as? [String: Any]) ?? (song["al"] as? [String: Any]) ?? [:]
            return LyricsMatcher.scored(LyricCandidate(source: .netease, sourceID: id, title: (song["name"] as? String) ?? "",
                                                       artists: artists.compactMap { $0["name"] as? String }, album: (album["name"] as? String) ?? "",
                                                       duration: ((song["duration"] as? Double) ?? (song["dt"] as? Double) ?? 0) / 1000), against: track)
        }.sorted { $0.score > $1.score }
    }

    func lyrics(candidate: LyricCandidate, settings _: LyricsSettings) async throws -> LyricsPayload {
        let result = try await request("/song/lyric", query: ["id": candidate.sourceID, "lv": "-1", "kv": "-1", "tv": "-1", "rv": "-1", "yv": "-1"])
        let inner = (result["data"] as? [String: Any]) ?? result
        func lyric(_ key: String) -> String {
            ((inner[key] as? [String: Any])?["lyric"] as? String) ?? ""
        }
        let original = lyric("lrc")
        let instrumental = inner["nolyric"] as? Bool == true
        guard instrumental || !original.isEmpty else { throw LyricsError.notFound }
        return LyricsPayload(format: .lrc, original: original, translation: lyric("tlyric"), romanization: lyric("romalrc"), selectionReason: "NetEase synchronized lines", isInstrumental: instrumental)
    }
}
