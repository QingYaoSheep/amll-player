#if DEBUG
    import Foundation

    /// Same raw millisecond input is consumed by the original browser renderer.
    struct AMLLSharedReference: Decodable {
        struct Word: Decodable { var word: String; var startTime: Double; var endTime: Double; var romanWord: String }
        struct Line: Decodable {
            var startTime: Double
            var endTime: Double
            var words: [Word]
            var isBG: Bool
            var isDuet: Bool
            var translatedLyric: String
            var romanLyric: String
        }

        var id: String
        var fontSize: Double
        var anchor: Double
        var lines: [Line]

        static func load() throws -> Self {
            guard let url = Bundle.main.url(forResource: "amll-shared-lyrics", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }

        var document: LyricsDocument {
            .init(candidate: .init(source: .apple, sourceID: id, title: "Shared AMLL reference", artists: ["Fixture"]),
                  lines: lines.enumerated().map { index, line in
                      .init(id: "shared-\(index)", text: line.words.map(\.word).joined(),
                            start: line.startTime / 1000, end: line.endTime / 1000,
                            words: line.words.map { .init(text: $0.word, start: $0.startTime / 1000, end: $0.endTime / 1000,
                                                          romanWord: $0.romanWord.isEmpty ? nil : $0.romanWord) },
                            translation: line.translatedLyric, romanization: line.romanLyric,
                            isBackground: line.isBG, isDuet: line.isDuet, precision: .word)
                  }, language: "", selectionReason: "Shared pinned core fixture")
        }
    }
#endif
