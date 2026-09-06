import Foundation
import NaturalLanguage

/// Apple syllable-lyrics uses song-absolute timestamps, including nested spans.
/// `.relative` is available for standards-based TTML offset-time documents.
enum TTMLTimingMode { case appleAbsolute, relative }

enum TTMLLyricsParser {
    private final class Node {
        enum Content { case text(String), node(Node) }
        let name: String
        let attributes: [String: String]
        weak var parent: Node?
        var content: [Content] = []
        init(_ name: String, _ attributes: [String: String], parent: Node?) {
            self.name = name; self.attributes = attributes; self.parent = parent
        }

        func attr(_ name: String) -> String? {
            attributes[name] ?? attributes.first { $0.key.split(separator: ":").last.map(String.init) == name }?.value
        }

        func inherited(_ name: String) -> String? {
            attr(name) ?? parent?.inherited(name)
        }

        var children: [Node] {
            content.compactMap {
                if case let .node(node) = $0 {
                    node
                } else {
                    nil
                }
            }
        }

        var role: String {
            (attr("role") ?? "").lowercased()
        }

        var ancestorsContainBackground: Bool {
            parent.map { $0.role.contains("bg") || $0.ancestorsContainBackground } ?? false
        }

        func descendants(_ name: String) -> [Node] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var count = 0
        var rejected = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String]) {
            count += 1
            guard stack.count < 64, count <= 40000, !Task.isCancelled else { rejected = true; parser.abortParsing(); return }
            let node = Node((elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased(), attributeDict, parent: stack.last)
            if let parent = stack.last {
                parent.content.append(.node(node))
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            guard let node = stack.last else { return }
            if case let .text(previous)? = node.content.last {
                node.content[node.content.count - 1] = .text(previous + string)
            } else {
                node.content.append(.text(string))
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) {
                self.parser(parser, foundCharacters: text)
            }
        }

        func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
            if !stack.isEmpty {
                stack.removeLast()
            }
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName _: String, systemID _: String?) -> Data? {
            rejected = true; parser.abortParsing(); return nil
        }
    }

    static func time(_ value: String?) -> Double? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for (suffix, scale) in [("ms", 0.001), ("h", 3600.0), ("m", 60.0), ("s", 1.0)] where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count)), number.isFinite, number >= 0 else { return nil }
            return number * scale
        }
        let components = text.split(separator: ":")
        guard (1 ... 3).contains(components.count) else { return nil }
        var result = 0.0
        for component in components {
            guard let number = Double(component), number.isFinite, number >= 0 else { return nil }
            result = result * 60 + number
        }
        return result.isFinite ? result : nil
    }

    private static func range(_ node: Node, duration: Double, mode: TTMLTimingMode) -> (Double, Double) {
        let parent = node.parent.map { range($0, duration: duration, mode: mode) } ?? (0, max(0, duration))
        let base = mode == .relative ? parent.0 : 0
        let start = time(node.attr("begin")).map { base + $0 } ?? parent.0
        var end = time(node.attr("end")).map { base + $0 } ?? parent.1
        if let dur = time(node.attr("dur")) {
            end = end > start ? min(end, start + dur) : start + dur
        }
        return (start, max(start, end))
    }

    private static func blocked(_ node: Node, background: Bool) -> Bool {
        node.role.contains("translation") || node.role.contains("roman") || node.role.contains("transliteration") || (!background && node.role.contains("bg"))
    }

    private static func text(_ node: Node, excluding: (Node) -> Bool = { _ in false }) -> String {
        node.content.map { part in
            switch part {
            case let .text(value): whitespace(value, preserve: node.inherited("space") == "preserve")
            case let .node(child): excluding(child) ? "" : child.name == "br" ? "\n" : text(child, excluding: excluding)
            }
        }.joined()
    }

    /// TTML often places timing spans around punctuation or whitespace that
    /// is also present in the paragraph text. Align the timed tokens back to
    /// that full text before Core Text lays out glyph fragments; otherwise a
    /// missing space or a composed character makes the mask cursor drift and
    /// the final words disappear.
    private static func alignWords(_ words: [LyricWord], to fullText: String) -> [LyricWord] {
        func normalized(_ value: String, trim: Bool = true) -> String {
            var value = value.replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if trim {
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value
        }

        let full = normalized(fullText)
        guard !full.isEmpty, !words.isEmpty else { return words }
        let fullCharacters = Array(full)
        var result = words.compactMap { word -> LyricWord? in
            let value = normalized(word.text)
            guard !value.isEmpty else { return nil }
            var copy = word; copy.text = value; return copy
        }
        guard !result.isEmpty else { return [] }

        /// Use Character offsets rather than String.Index values from a
        /// separately lowercased string. Lowercasing can change the number of
        /// Unicode scalars (for example, Turkish İ), which would otherwise
        /// make a successful fallback point into the wrong glyph cluster.
        func match(_ token: String, from cursor: Int, insensitive: Bool) -> Range<Int>? {
            let tokenCharacters = Array(token)
            guard !tokenCharacters.isEmpty, cursor <= fullCharacters.count - tokenCharacters.count else { return nil }
            let lastStart = fullCharacters.count - tokenCharacters.count
            for start in max(0, cursor) ... lastStart {
                let candidate = String(fullCharacters[start ..< start + tokenCharacters.count])
                if insensitive {
                    if candidate.caseInsensitiveCompare(token) == .orderedSame {
                        return start ..< start + tokenCharacters.count
                    }
                } else if candidate == token {
                    return start ..< start + tokenCharacters.count
                }
            }
            return nil
        }

        var cursor = 0
        var lastMatched = -1
        for index in result.indices {
            let token = result[index].text
            let location = match(token, from: cursor, insensitive: false)
                ?? match(token, from: cursor, insensitive: true)
            guard let location else { continue }
            let start = location.lowerBound
            let end = location.upperBound
            if index == result.startIndex, start > cursor {
                result[index].text = String(fullCharacters[cursor ..< start]) + result[index].text
            } else if lastMatched >= 0, start > cursor {
                result[lastMatched].text += String(fullCharacters[cursor ..< start])
            }
            cursor = end; lastMatched = index
        }
        if lastMatched >= 0, cursor < full.count {
            result[lastMatched].text += String(fullCharacters[cursor...])
        }
        return result
    }

    private static func normalizedKey(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        while value.first == "#" {
            value.removeFirst()
        }
        return value.isEmpty ? nil : value
    }

    private static func cleanEmptyMarkers(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?:\(\s*\)|（\s*）|﹙\s*﹚|\[\s*\]|［\s*］|〔\s*〕|【\s*】|\{\s*\}|｛\s*｝)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func whitespace(_ text: String, preserve: Bool) -> String {
        if preserve {
            return text
        }
        // Pretty-printing between spans isn't a sung space; ordinary spaces are retained.
        if text.contains("\n"), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        return text.replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
    }

    private static func backgroundRoots(_ node: Node) -> [Node] {
        node.children.flatMap { child in
            child.role.contains("bg") ? [child] : (blocked(child, background: true) ? [] : backgroundRoots(child))
        }
    }

    private static func words(_ root: Node, duration: Double, mode: TTMLTimingMode, includeBackground: Bool = false) -> [LyricWord] {
        var result: [LyricWord] = []
        var prefix = ""
        func hasTiming(_ node: Node) -> Bool {
            node.attr("begin") != nil || node.attr("end") != nil || node.attr("dur") != nil
        }
        func timedDescendant(_ node: Node) -> Bool {
            node.children.contains { child in
                !blocked(child, background: includeBackground) && ((child.name == "span" && hasTiming(child)) || timedDescendant(child))
            }
        }
        func walk(_ node: Node) {
            let bounds = range(node, duration: duration, mode: mode)
            if node.name == "span", hasTiming(node), !timedDescendant(node) {
                let value = text(node, excluding: { blocked($0, background: includeBackground) })
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(LyricWord(text: prefix + value, start: bounds.0, end: bounds.1)); prefix = ""
                }
                return
            }
            for part in node.content {
                switch part {
                case let .text(raw):
                    let value = whitespace(raw, preserve: node.inherited("space") == "preserve")
                    guard !value.isEmpty else { continue }
                    if !result.isEmpty {
                        result[result.count - 1].text += value
                    } else {
                        prefix += value
                    }
                case let .node(child):
                    if !blocked(child, background: includeBackground) {
                        walk(child)
                    }
                }
            }
        }
        walk(root)
        return result
    }

    private static let bracketPairs: [(Character, Character)] = [("(", ")"), ("（", "）"), ("[", "]"), ("［", "］"), ("〔", "〕"), ("【", "】"), ("{", "}"), ("｛", "｝")]
    private static func stripBrackets(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0 ..< 4 {
            guard bracketPairs.contains(where: { value.first == $0.0 && value.last == $0.1 }), value.count >= 2 else { break }
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func cleanBackground(_ words: [LyricWord]) -> [LyricWord] {
        var result = words
        for _ in 0 ..< 4 {
            guard !result.isEmpty else { break }
            result[0].text = result[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            result[result.count - 1].text = result[result.count - 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard bracketPairs.contains(where: { result.first?.text.first == $0.0 && result.last?.text.last == $0.1 }) else { break }
            result[0].text = String(result[0].text.dropFirst())
            result[result.count - 1].text = String(result[result.count - 1].text.dropLast())
            if result.first?.text.isEmpty == true, result.count > 1 {
                let removed = result.removeFirst(); result[0].start = min(removed.start, result[0].start)
            }
            if result.last?.text.isEmpty == true, result.count > 1 {
                let removed = result.removeLast(); result[result.count - 1].end = max(removed.end, result[result.count - 1].end)
            }
        }
        return result.filter { !$0.text.isEmpty }
    }

    static func parse(_ xml: String, preferredLanguage: String = "zh-Hans-CN", duration: Double = 0, timingMode: TTMLTimingMode = .appleAbsolute) throws -> [LyricLine] {
        guard xml.utf8.count <= 2_000_000 else { throw LyricsError.tooLarge }
        guard !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw LyricsError.malformed }
        let reader = Reader(), parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never; parser.delegate = reader
        guard parser.parse(), !reader.rejected, let root = reader.root, root.name == "tt" else { throw LyricsError.malformed }
        // Frame/tick and sequential containers need a separate timing implementation, never silently mis-time them.
        let nodes = [root] + root.descendants("body") + root.descendants("div") + root.descendants("p") + root.descendants("span")
        guard !nodes.contains(where: { node in node.attr("timeContainer") == "seq" || ["begin", "end", "dur"].contains { key in
            if let value = node.attr(key) {
                return time(value) == nil
            }; return false
        } }) else { throw LyricsError.malformed }
        var agents: [String: String] = [:]
        for agent in root.descendants("agent") {
            if let id = agent.attr("id") {
                agents[id] = agent.attr("type") ?? ""
            }
        }
        var sidecars: [String: [String: [Node]]] = [:]
        for kind in ["translation", "transliteration"] {
            for node in root.descendants(kind).flatMap({ $0.descendants("text") }) {
                if let key = normalizedKey(node.attr("for")) {
                    sidecars[kind, default: [:]][key, default: []].append(node)
                }
            }
        }
        func auxiliary(_ p: Node, kind: String, bg: Int?) -> Node? {
            guard let key = normalizedKey(p.attr("key") ?? p.attr("id")) else { return nil }
            let choices = sidecars[kind]?[key] ?? []
            let ranked = choices.sorted { a, b in
                func score(_ n: Node) -> Int {
                    let lang = (n.inherited("lang") ?? "").lowercased()
                    let preferred = preferredLanguage.lowercased()
                    if !preferred.isEmpty, lang == preferred {
                        return 50
                    }
                    if !preferred.isEmpty,
                       lang.split(separator: "-").first == preferred.split(separator: "-").first
                    {
                        return 40
                    }
                    // When the caller did not specify a supported language,
                    // retain AMLL's Chinese-first behavior before falling
                    // back to the first available localization.
                    if lang == "zh-hans-cn" {
                        return 30
                    }
                    if ["zh-hans", "zh-cn", "zh-hant-tw", "zh-hant", "zh-tw", "zh-hk"].contains(lang) {
                        return 25
                    }
                    return lang.isEmpty ? 10 : 0
                }
                return score(a) > score(b)
            }
            guard let selected = ranked.first else { return nil }
            if let bg {
                let roots = backgroundRoots(selected); return roots.indices.contains(bg) ? roots[bg] : nil
            }
            return selected
        }
        var output: [LyricLine] = [], lastAgent: String?, lastDuet = false
        let paragraphs = root.descendants("body").flatMap { $0.descendants("p") }.sorted {
            range($0, duration: duration, mode: timingMode).0 < range($1, duration: duration, mode: timingMode).0
        }
        for (index, p) in paragraphs.enumerated() {
            try Task.checkCancellation()
            let agent = p.inherited("agent") ?? "v1"
            var duet = false
            if agents[agent] != "group" {
                duet = lastAgent == nil ? agents[agent] == "other" : lastAgent == agent ? lastDuet : !lastDuet
                lastAgent = agent; lastDuet = duet
            }
            let roots = [p] + backgroundRoots(p)
            for (voice, node) in roots.enumerated() {
                let bg = voice > 0
                var lineText = text(node, excluding: { blocked($0, background: false) })
                    .replacingOccurrences(of: #"[（(\[［]\s*[）)\]］]"#, with: "", options: .regularExpression)
                if bg {
                    lineText = stripBrackets(lineText)
                }
                guard !lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var timedWords = words(node, duration: duration, mode: timingMode)
                if bg {
                    timedWords = cleanBackground(timedWords)
                }
                timedWords = alignWords(timedWords, to: lineText)
                func inline(_ roles: [String]) -> Node? {
                    node.descendants("span").first { span in
                        roles.contains(where: { role in !role.isEmpty && span.role.contains(role) })
                            && (bg || !span.ancestorsContainBackground)
                    }
                }
                let translation = auxiliary(p, kind: "translation", bg: bg ? voice - 1 : nil) ?? inline(["translation"])
                let roman = auxiliary(p, kind: "transliteration", bg: bg ? voice - 1 : nil) ?? inline(["roman", "transliteration"])
                let trText = translation.map { cleanEmptyMarkers(text($0, excluding: { $0.role.contains("bg") })) } ?? ""
                let roText = roman.map { cleanEmptyMarkers(text($0, excluding: { $0.role.contains("bg") })) } ?? ""
                if let roman {
                    let romanWords = words(roman, duration: duration, mode: timingMode)
                    var cursor = 0
                    for i in timedWords.indices {
                        var best: Int?, bestScore = 0.0
                        for j in romanWords.indices.dropFirst(cursor) {
                            if abs(romanWords[j].start - timedWords[i].start) <= 0.003 {
                                best = j; bestScore = 1; break
                            }
                            let overlap = max(0, min(romanWords[j].end, timedWords[i].end) - max(romanWords[j].start, timedWords[i].start))
                            let union = max(0.001, max(romanWords[j].end, timedWords[i].end) - min(romanWords[j].start, timedWords[i].start))
                            if overlap / union > bestScore {
                                best = j; bestScore = overlap / union
                            }
                            if romanWords[j].start >= timedWords[i].end {
                                break
                            }
                        }
                        if let best, bestScore >= 0.1 {
                            timedWords[i].romanWord = romanWords[best].text.trimmingCharacters(in: .whitespacesAndNewlines); cursor = best + 1
                        }
                    }
                }
                var bounds = range(node, duration: duration, mode: timingMode)
                if node.attr("begin") == nil, let first = timedWords.first {
                    bounds.0 = first.start
                }
                if bounds.1 <= bounds.0, let end = timedWords.last?.end {
                    bounds.1 = end
                }
                let lang = node.inherited("lang") ?? NLLanguageRecognizer.dominantLanguage(for: lineText)?.rawValue ?? ""
                output.append(LyricLine(id: "ttml-\(index)-\(voice)", text: lineText, start: bounds.0, end: bounds.1,
                                        words: timedWords, translation: bg ? stripBrackets(trText) : trText,
                                        romanization: bg ? stripBrackets(roText) : roText, isBackground: bg, isDuet: duet, agent: agent,
                                        isRTL: Locale.Language(identifier: lang).characterDirection == .rightToLeft,
                                        precision: timedWords.isEmpty ? .line : .word))
            }
        }
        return output.sorted { $0.start == $1.start ? (!$0.isBackground && $1.isBackground) : $0.start < $1.start }
    }
}
