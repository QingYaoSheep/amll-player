import Compression
import Foundation

/// Reads the pinned IPADIC buffers exported from Mineradio's kuromoji 0.1.2.
/// The search order and transition costs follow ViterbiBuilder/ViterbiSearcher.
final class MineradioKuromoji {
    struct Token {
        var surface: String
        var start: Int
        var end: Int
        var reading: String?
        var pronunciation: String?
        var known: Bool
    }

    private struct Bytes {
        let data: Data
        var count: Int { data.count }
        subscript(_ index: Int) -> UInt8 { index >= 0 && index < data.count ? data[index] : 0 }
        func short(_ offset: Int) -> Int {
            let value = Int(self[offset]) | (Int(self[offset + 1]) << 8)
            return value >= 0x8000 ? value - 0x10000 : value
        }
        func integer(_ offset: Int) -> Int {
            let value = UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) |
                (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
            return Int(Int32(bitPattern: value))
        }
        func string(_ offset: Int) -> String {
            guard offset >= 0 && offset < count else { return "" }
            var end = offset
            while end < count && self[end] != 0 { end += 1 }
            return String(decoding: data[offset ..< end], as: UTF8.self)
        }
    }

    private struct CharacterClass {
        var name: String
        var alwaysInvoke: Bool
        var groups: Bool
    }

    private struct Node {
        var surface: String
        var start: Int
        var length: Int
        var left: Int
        var right: Int
        var cost: Int
        var wordID: Int
        var known: Bool
        var shortest: Int = Int.max / 4
        var previous: Int = -1
    }

    private let base: Bytes
    private let check: Bytes
    private let knownInfo: Bytes
    private let knownPositions: Bytes
    private let unknownInfo: Bytes
    private let costs: Bytes
    private let categories: Bytes
    private let classes: [CharacterClass]
    private let knownMap: [Int: [Int]]
    private let unknownMap: [Int: [Int]]
    private let backwardDimension: Int

    init(bundle: Bundle = .main) throws {
        func load(_ name: String) throws -> Bytes {
            let file = "roman-\(name)"
            guard let url = bundle.url(forResource: file, withExtension: "deflate", subdirectory: "Romanization")
                    ?? bundle.url(forResource: file, withExtension: "deflate") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let compressed = try Data(contentsOf: url, options: .mappedIfSafe)
            guard compressed.count > 4 else { throw CocoaError(.fileReadCorruptFile) }
            let expected = Int(compressed[0]) | Int(compressed[1]) << 8 |
                Int(compressed[2]) << 16 | Int(compressed[3]) << 24
            guard expected > 0 && expected <= 50_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            var raw = Data(count: expected)
            let decoded = raw.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expected,
                                              source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 4),
                                              compressed.count - 4, nil, COMPRESSION_ZLIB)
                }
            }
            guard decoded == expected else { throw CocoaError(.fileReadCorruptFile) }
            return Bytes(data: raw)
        }
        base = try load("base")
        check = try load("check")
        knownInfo = try load("tid")
        knownPositions = try load("tid_pos")
        unknownInfo = try load("unk")
        let costBuffer = try load("cc")
        costs = costBuffer
        categories = try load("unk_char")
        knownMap = Self.parseMap(try load("tid_map"))
        unknownMap = Self.parseMap(try load("unk_map"))
        let definitions = try load("unk_invoke")
        var parsed: [CharacterClass] = []
        var cursor = 0
        while cursor + 6 < definitions.count && definitions[cursor] <= 1 && definitions[cursor + 1] <= 1 {
            let name = definitions.string(cursor + 6)
            guard !name.isEmpty else { break }
            parsed.append(.init(name: name, alwaysInvoke: definitions[cursor] == 1,
                                groups: definitions[cursor + 1] == 1))
            cursor += 7 + name.utf8.count
        }
        classes = parsed
        backwardDimension = costBuffer.short(2)
    }

    private static func parseMap(_ bytes: Bytes) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        let count = max(0, bytes.integer(0))
        var cursor = 4
        for _ in 0 ..< count where cursor + 8 <= bytes.count {
            let key = bytes.integer(cursor), size = bytes.integer(cursor + 4)
            cursor += 8
            guard size >= 0, size < 100_000, cursor + size * 4 <= bytes.count else { break }
            result[key] = (0 ..< size).map { bytes.integer(cursor + $0 * 4) }
            cursor += size * 4
        }
        return result
    }

    private func connection(_ right: Int, _ left: Int) -> Int {
        costs.short((right * backwardDimension + left + 2) * 2)
    }

    private func traverse(_ parent: Int, _ byte: UInt8) -> Int? {
        let child = base.integer(parent * 4) + Int(byte)
        return child >= 0 && child * 4 + 4 <= check.count && check.integer(child * 4) == parent ? child : nil
    }

    private func knownCandidates(_ characters: [String], at start: Int) -> [Node] {
        var parent = 0
        var result: [Node] = []
        var surface = ""
        for index in start ..< characters.count {
            let character = characters[index]
            var nextParent = parent
            for byte in character.utf8 {
                guard let child = traverse(nextParent, byte) else { return result }
                nextParent = child
            }
            parent = nextParent
            surface += character
            guard let terminal = traverse(parent, 0) else { continue }
            let trieID = -base.integer(terminal * 4) - 1
            guard let tokenIDs = knownMap[trieID] else { continue }
            for id in tokenIDs {
                result.append(.init(surface: surface, start: start, length: index - start + 1,
                                    left: knownInfo.short(id), right: knownInfo.short(id + 2),
                                    cost: knownInfo.short(id + 4), wordID: id, known: true))
            }
        }
        return result
    }

    private func category(_ character: String) -> Int {
        guard let first = character.utf16.first, character.utf16.count == 1 else {
            return classes.firstIndex(where: { $0.name == "DEFAULT" }) ?? 0
        }
        return Int(categories[Int(first)])
    }

    private func unknownCandidates(_ characters: [String], at start: Int, known: Bool) -> [Node] {
        let id = category(characters[start])
        guard id >= 0 && id < classes.count && (!known || classes[id].alwaysInvoke) else { return [] }
        var end = start + 1
        if classes[id].groups {
            while end < characters.count && category(characters[end]) == id { end += 1 }
        }
        let surface = characters[start ..< end].joined()
        return (unknownMap[id] ?? []).map { tokenID in
            Node(surface: surface, start: start, length: end - start,
                 left: unknownInfo.short(tokenID), right: unknownInfo.short(tokenID + 2),
                 cost: unknownInfo.short(tokenID + 4), wordID: tokenID, known: false)
        }
    }

    private func tokenizeSentence(_ sentence: String, offset: Int) -> [Token] {
        let characters = sentence.unicodeScalars.map { String($0) }
        guard !characters.isEmpty else { return [] }
        var nodes = [Node(surface: "", start: 0, length: 0, left: 0, right: 0,
                          cost: 0, wordID: -1, known: false, shortest: 0)]
        var ends = [[Int]](repeating: [], count: characters.count + 1)
        ends[0] = [0]
        for position in characters.indices {
            guard !ends[position].isEmpty else { continue }
            let known = knownCandidates(characters, at: position)
            let candidates = known + unknownCandidates(characters, at: position, known: !known.isEmpty)
            for var node in candidates {
                for previous in ends[position] {
                    let prior = nodes[previous]
                    let score = prior.shortest + connection(prior.right, node.left) + node.cost
                    if score < node.shortest { node.shortest = score; node.previous = previous }
                }
                guard node.previous >= 0 else { continue }
                let index = nodes.count
                nodes.append(node)
                ends[position + node.length].append(index)
            }
        }
        guard let final = ends[characters.count].min(by: {
            nodes[$0].shortest + connection(nodes[$0].right, 0) <
                nodes[$1].shortest + connection(nodes[$1].right, 0)
        }) else { return [] }
        var path: [Node] = []
        var cursor = final
        while cursor > 0 {
            path.append(nodes[cursor])
            cursor = nodes[cursor].previous
            if cursor < 0 { return [] }
        }
        var location = offset
        return path.reversed().map { node in
            let fields = node.known
                ? knownPositions.string(knownInfo.integer(node.wordID + 6)).split(separator: ",", omittingEmptySubsequences: false)
                : []
            let start = location
            location += node.surface.utf16.count
            return Token(surface: node.surface, start: start, end: location,
                         reading: node.known && fields.count > 8 ? String(fields[8]) : nil,
                         pronunciation: node.known && fields.count > 9 ? String(fields[9]) : nil,
                         known: node.known)
        }
    }

    func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var segment = ""
        var offset = 0
        for character in text.unicodeScalars.map({ String($0) }) {
            segment += character
            if character == "、" || character == "。" {
                result += tokenizeSentence(segment, offset: offset)
                offset += segment.utf16.count
                segment = ""
            }
        }
        if !segment.isEmpty { result += tokenizeSentence(segment, offset: offset) }
        return result
    }
}
