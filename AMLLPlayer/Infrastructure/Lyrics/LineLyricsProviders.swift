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

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let value = value as? [String: Any] {
            for key in ["lrc", "lyric", "text", "content"] {
                let nested = stringValue(value[key])
                if !nested.isEmpty {
                    return nested
                }
            }
        }
        return ""
    }

    private static func decoded(_ value: Any?) -> String {
        let raw = stringValue(value)
        guard !raw.isEmpty else { return "" }
        if let decrypted = QQRCDecoder.decrypt(raw) {
            return decrypted
        }
        return (try? LRCLyricsParser.decodeField(raw)) ?? ""
    }

    private static func asset(_ value: Any?, hint: LyricsAsset.Format, origin: String) -> LyricsAsset? {
        let text = decoded(value)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LyricsAsset(format: LyricsFormatDetector.detect(text, hint: hint), text: text, origin: origin)
    }

    private static func bundle(primary: LyricsAsset?, translation: LyricsAsset?, romanization: LyricsAsset?, reason: String) -> LyricsAssetBundle? {
        guard let primary else { return nil }
        return LyricsAssetBundle(primary: primary,
                                 translationAssets: translation.map { [$0] } ?? [],
                                 romanizationAssets: romanization.map { [$0] } ?? [],
                                 selectionReason: reason,
                                 degradationReason: primary.format == .lrc ? "QQ word-timed lyrics unavailable; using line lyrics" : nil)
    }

    private static func isValid(_ bundle: LyricsAssetBundle, candidate: LyricCandidate) -> Bool {
        (try? bundle.parse(candidate: candidate, duration: candidate.duration).lines.isEmpty) == false
    }

    func search(track: TrackIdentity, query: String, settings _: LyricsSettings) async throws -> [LyricCandidate] {
        let query = query.isEmpty ? track.query : query
        var songs: [[String: Any]] = []
        do {
            let result = try await request("https://u.y.qq.com/cgi-bin/musicu.fcg", body: [
                "req_1": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
                          "param": ["num_per_page": 20, "page_num": 1, "query": query, "search_type": 0]],
            ])
            let data = (result["req_1"] as? [String: Any])?["data"] as? [String: Any]
            let body = data?["body"] as? [String: Any]
            songs = ((body?["song"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        if songs.isEmpty {
            let result = try await request("https://c.y.qq.com/soso/fcgi-bin/client_search_cp",
                                           query: ["w": query, "format": "json", "p": "1", "n": "20", "t": "0"])
            let data = result["data"] as? [String: Any]
            songs = ((data?["song"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
            if let code = result["code"] as? Int, code != 0 {
                throw LyricsError.malformed
            }
        }
        var seen = Set<String>()
        return songs.compactMap { song -> LyricCandidate? in
            let mid = LyricsRequest.id(song["mid"] ?? song["songmid"])
            let numeric = LyricsRequest.id(song["id"] ?? song["songid"])
            let id = mid.isEmpty ? numeric : mid
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let singers = (song["singer"] as? [[String: Any]]) ?? (song["singers"] as? [[String: Any]]) ?? []
            let album = song["album"] as? [String: Any]
            let candidate = LyricCandidate(source: .qq, sourceID: id, numericID: numeric,
                                           title: (song["title"] as? String) ?? (song["songname"] as? String) ?? (song["name"] as? String) ?? "",
                                           artists: singers.compactMap { $0["name"] as? String },
                                           album: (album?["name"] as? String) ?? (song["albumname"] as? String) ?? "",
                                           duration: (song["interval"] as? NSNumber)?.doubleValue ?? 0)
            return LyricsMatcher.scored(candidate, against: track)
        }.sorted { $0.score > $1.score }
    }

    func lyrics(candidate: LyricCandidate, settings _: LyricsSettings) async throws -> LyricsAssetBundle {
        if let numericID = candidate.numericID, numericID.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            do {
                let request = try LyricsRequest.form("https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg", fields: [
                    "version": "15", "miniversion": "82", "lrctype": "4", "musicid": numericID,
                ], headers: headers)
                let data = try await http.data(for: request)
                let fields = try QQLyricDownloadXML.parse(data)
                if let bundle = Self.bundle(
                    primary: Self.asset(fields["content"], hint: .qrc, origin: "lyric_download.content"),
                    translation: Self.asset(fields["contentts"], hint: .lrc, origin: "lyric_download.contentts"),
                    romanization: Self.asset(fields["contentroma"], hint: .lrc, origin: "lyric_download.contentroma"),
                    reason: "QQ lyric_download"
                ), Self.isValid(bundle, candidate: candidate) {
                    return bundle
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }

        do {
            let response = try await request("https://u.y.qq.com/cgi-bin/musicu.fcg", body: [
                "comm": ["ct": 19, "cv": 0, "tmeAppID": "qqmusiclight"],
                "req_0": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo",
                          "param": ["songMID": candidate.sourceID, "songID": Int(candidate.numericID ?? "") ?? 0,
                                    "platform": 0, "needNew": 1, "crypt": 1, "qrc": 1, "trans": 1, "roma": 1]],
            ])
            let data = (response["req_0"] as? [String: Any])?["data"] as? [String: Any]
            if let bundle = Self.bundle(
                primary: Self.asset(data?["lyric"] ?? data?["lrc"], hint: .qrc, origin: "PlayLyricInfo.lyric"),
                translation: Self.asset(data?["trans"], hint: .lrc, origin: "PlayLyricInfo.trans"),
                romanization: Self.asset(data?["roma"], hint: .lrc, origin: "PlayLyricInfo.roma"),
                reason: "QQ PlayLyricInfo"
            ), Self.isValid(bundle, candidate: candidate) {
                return bundle
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}

        let response = try await request("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", query: [
            "songmid": candidate.sourceID, "format": "json", "nobase64": "1", "g_tk": "5381", "loginUin": "0",
            "hostUin": "0", "inCharset": "utf8", "outCharset": "utf-8", "notice": "0", "platform": "yqq", "needNewCode": "0",
        ])
        if let code = response["code"] as? Int, code != 0 {
            throw LyricsError.malformed
        }
        guard let bundle = Self.bundle(
            primary: Self.asset(response["lyric"] ?? response["lrc"], hint: .lrc, origin: "legacy.lyric"),
            translation: Self.asset(response["trans"], hint: .lrc, origin: "legacy.trans"),
            romanization: Self.asset(response["roma"], hint: .lrc, origin: "legacy.roma"),
            reason: "QQ legacy lyric"
        ) else { throw LyricsError.notFound }
        return bundle
    }
}

private final class QQLyricDownloadXML: NSObject, XMLParserDelegate {
    private var fields: [String: String] = [:]
    private var current: String?

    static func parse(_ data: Data) throws -> [String: String] {
        let delegate = QQLyricDownloadXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw LyricsError.malformed }
        return delegate.fields
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
        let name = elementName.lowercased()
        current = ["content", "contentts", "contentroma"].contains(name) ? name : nil
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard let current else { return }
        fields[current, default: ""] += string
    }

    func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
        guard let current, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        fields[current, default: ""] += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if current == elementName.lowercased() {
            current = nil
        }
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
        let data = try await http.data(for: LyricsRequest.make("https://music.163.com/api" + path, query: query,
                                                               headers: ["Referer": "https://music.163.com/", "Origin": "https://music.163.com"]))
        let result = try LyricsRequest.object(data)
        if let code = result["code"] as? Int, code != 200 {
            throw LyricsError.http(code)
        }
        return result
    }

    func search(track: TrackIdentity, query: String, settings _: LyricsSettings) async throws -> [LyricCandidate] {
        let result = try await request("/search/get/web", query: [
            "s": query.isEmpty ? track.query : query, "type": "1", "offset": "0", "total": "true", "limit": "20",
        ])
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

    func lyrics(candidate: LyricCandidate, settings _: LyricsSettings) async throws -> LyricsAssetBundle {
        do {
            let data = try await http.data(for: NeteaseEAPI.request(songID: candidate.sourceID))
            let response = try LyricsRequest.object(data)
            if let code = response["code"] as? Int, code != 200 {
                throw LyricsError.http(code)
            }
            if let bundle = try Self.bundle(response, origin: "NetEase EAPI") {
                return bundle
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}

        let response = try await request("/song/lyric", query: [
            "id": candidate.sourceID, "lv": "-1", "kv": "-1", "tv": "-1", "rv": "-1", "yv": "-1",
        ])
        guard var bundle = try Self.bundle(response, origin: "NetEase legacy API") else { throw LyricsError.notFound }
        if !bundle.isInstrumental {
            bundle.degradationReason = "NetEase word-timed EAPI unavailable; using line lyrics"
        }
        return bundle
    }

    private static func bundle(_ response: [String: Any], origin: String) throws -> LyricsAssetBundle? {
        let value = (response["data"] as? [String: Any]) ?? response
        if value["nolyric"] as? Bool == true {
            return LyricsAssetBundle(primary: LyricsAsset(format: .lrc, text: "", origin: origin),
                                     selectionReason: origin, isInstrumental: true)
        }
        if value["uncollected"] as? Bool == true {
            throw LyricsError.notFound
        }
        func lyric(_ key: String) -> String {
            ((value[key] as? [String: Any])?["lyric"] as? String) ?? ""
        }
        let yrc = lyric("yrc"), lrc = lyric("lrc")
        let primaryText = yrc.isEmpty ? lrc : yrc
        guard !primaryText.isEmpty else { return nil }
        let primary = LyricsAsset(format: LyricsFormatDetector.detect(primaryText, hint: yrc.isEmpty ? .lrc : .yrc),
                                  text: primaryText, origin: yrc.isEmpty ? origin + ".lrc" : origin + ".yrc")
        let translation = [lyric("ytlrc"), lyric("tlyric")].first { !$0.isEmpty }
        let romanization = [lyric("yromalrc"), lyric("romalrc")].first { !$0.isEmpty }
        return LyricsAssetBundle(
            primary: primary,
            translationAssets: translation.map { [LyricsAsset(format: LyricsFormatDetector.detect($0, hint: .lrc), text: $0, origin: origin + ".translation")] } ?? [],
            romanizationAssets: romanization.map { [LyricsAsset(format: LyricsFormatDetector.detect($0, hint: .lrc), text: $0, origin: origin + ".romanization")] } ?? [],
            selectionReason: origin,
            degradationReason: primary.format == .lrc ? "NetEase word-timed lyrics unavailable; using line lyrics" : nil
        )
    }
}
