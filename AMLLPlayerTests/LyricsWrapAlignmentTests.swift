@testable import AMLLPlayer
import CoreText
import UIKit
import XCTest

@MainActor final class LyricsWrapAlignmentTests: XCTestCase {
    private enum Spacing: String, CaseIterable { case separate, leading, trailing, phrase }

    private func words(_ text: String, spacing: Spacing) -> [LyricWord] {
        let tokens = text.split(separator: " ").map(String.init)
        if spacing == .phrase { return [.init(text: text, start: 0, end: Double(tokens.count))] }
        var result: [LyricWord] = []
        for (index, token) in tokens.enumerated() {
            let start = Double(index), end = start + 0.8
            switch spacing {
            case .separate:
                if index > 0 { result.append(.init(text: " ", start: start, end: start)) }
                result.append(.init(text: token, start: start, end: end))
            case .leading:
                result.append(.init(text: (index > 0 ? " " : "") + token, start: start, end: end))
            case .trailing:
                result.append(.init(text: token + (index < tokens.count - 1 ? " " : ""), start: start, end: end))
            case .phrase: break
            }
        }
        return result
    }

    func testScreenshotSentencesDoNotIndentTheirSoftContinuation() {
        let sentences = ["I wake up, the world is my buffet", "I might call you, might call my ex"]
        var configuration = LyricsRenderConfiguration()
        configuration.translation = false; configuration.romanization = false
        configuration.emphasizeWords = false
        let font = AMLLLyricsFont.make(pointSize: 32, weight: .bold)
        for text in sentences {
            for spacing in Spacing.allCases {
                let line = LyricLine(id: "alignment", text: text, start: 0, end: 10,
                    words: words(text, spacing: spacing), precision: .word)
                let layout = AMLLCoreTextLayout(line: line, width: 338, font: font, configuration: configuration)
                let rows = Dictionary(grouping: layout.characterFragments, by: { $0.rect.minY })
                    .sorted { $0.key < $1.key }
                XCTAssertGreaterThan(rows.count, 1, "The screenshot fixture must actually wrap")
                let starts = rows.map { $0.value.map(\.rect.minX).min() ?? .nan }
                print("[WRAP-ALIGNMENT] \(spacing.rawValue) \(text); breaks=\(layout.breakOffsets); starts=\(starts)")
                for start in starts {
                    // Caret geometry deliberately preserves the font's ink bearing.
                    XCTAssertEqual(start, 0, accuracy: 0.01,
                        "Soft-wrapped text must share its layout origin: \(spacing.rawValue), \(text)")
                }
            }
        }
    }
}
