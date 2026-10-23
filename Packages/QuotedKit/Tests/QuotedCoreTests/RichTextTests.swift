import Foundation
import SwiftUI
import Testing
@testable import QuotedCore

@Suite("RichText.normalize")
struct NormalizeTests {
    @Test func dropsEmptyFlaglessAndNegativeRuns() {
        let runs = [
            TextRun(start: 0, length: 0, bold: true),
            TextRun(start: 1, length: 3),
            TextRun(start: 2, length: -2, italic: true),
            TextRun(start: 4, length: 2, underline: true),
        ]
        #expect(RichText.normalize(runs, utf16Count: 10) == [TextRun(start: 4, length: 2, underline: true)])
    }

    @Test func clampsToBounds() {
        let runs = [
            TextRun(start: -5, length: 7, bold: true),
            TextRun(start: 8, length: 50, italic: true),
            TextRun(start: 20, length: 3, underline: true),
        ]
        #expect(RichText.normalize(runs, utf16Count: 10) == [
            TextRun(start: 0, length: 2, bold: true),
            TextRun(start: 8, length: 2, italic: true),
        ])
        #expect(RichText.normalize(runs, utf16Count: 0).isEmpty)
        #expect(RichText.normalize(runs, utf16Count: -3).isEmpty)
    }

    @Test func survivesExtremeValues() {
        let runs = [
            TextRun(start: .max, length: .max, bold: true),
            TextRun(start: .min, length: .max, italic: true),
            TextRun(start: 3, length: .max, underline: true),
        ]
        #expect(RichText.normalize(runs, utf16Count: 5) == [TextRun(start: 3, length: 2, underline: true)])
    }

    @Test func sortsAndSplitsOverlaps() {
        let runs = [
            TextRun(start: 5, length: 10, italic: true),
            TextRun(start: 0, length: 10, bold: true),
        ]
        #expect(RichText.normalize(runs, utf16Count: 20) == [
            TextRun(start: 0, length: 5, bold: true),
            TextRun(start: 5, length: 5, bold: true, italic: true),
            TextRun(start: 10, length: 5, italic: true),
        ])
    }

    @Test func nestedRunsSplitIntoThree() {
        let runs = [TextRun(start: 0, length: 10, underline: true), TextRun(start: 3, length: 2, bold: true)]
        #expect(RichText.normalize(runs, utf16Count: 10) == [
            TextRun(start: 0, length: 3, underline: true),
            TextRun(start: 3, length: 2, bold: true, underline: true),
            TextRun(start: 5, length: 5, underline: true),
        ])
    }

    @Test func mergesAdjacentAndOverlappingIdenticalRuns() {
        let runs = [
            TextRun(start: 0, length: 3, bold: true),
            TextRun(start: 3, length: 3, bold: true),
            TextRun(start: 5, length: 4, bold: true),
            TextRun(start: 12, length: 1, bold: true),
        ]
        #expect(RichText.normalize(runs, utf16Count: 20) == [
            TextRun(start: 0, length: 9, bold: true),
            TextRun(start: 12, length: 1, bold: true),
        ])
    }

    @Test func randomInputsSatisfyTheContract() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<300 {
            let count = generator.nextIndex(below: 40)
            let runs = (0..<generator.nextIndex(below: 12)).map { _ in
                TextRun(
                    start: generator.nextIndex(below: 60) - 10,
                    length: generator.nextIndex(below: 30) - 5,
                    flags: TextFlags(rawValue: UInt8(generator.nextIndex(below: 8)))
                )
            }
            let normalized = RichText.normalize(runs, utf16Count: count)
            assertNormalized(normalized, utf16Count: count)
            #expect(RichText.normalize(normalized, utf16Count: count) == normalized)
            // Coverage is preserved: each code unit keeps the union of the flags covering it.
            for offset in 0..<count {
                #expect(RichText.flags(at: offset, in: normalized) == RichText.flags(at: offset, in: runs))
            }
        }
    }

    @Test func widensBoundariesInsideSurrogatePairs() {
        let text = "😀x😀" // 2 + 1 + 2 code units
        #expect(RichText.normalize([TextRun(start: 1, length: 1, bold: true)], in: text) == [TextRun(start: 0, length: 2, bold: true)])
        #expect(RichText.normalize([TextRun(start: 2, length: 2, italic: true)], in: text) == [TextRun(start: 2, length: 3, italic: true)])
        #expect(RichText.normalize([TextRun(start: 0, length: 99, underline: true)], in: text) == [TextRun(start: 0, length: 5, underline: true)])
    }

    @Test func combiningCharactersKeepScalarOffsets() {
        let text = "e\u{301}te\u{301}" // "été" written with combining accents: 5 code units
        let runs = [TextRun(start: 0, length: 2, bold: true), TextRun(start: 3, length: 1, italic: true)]
        #expect(RichText.normalize(runs, in: text) == runs)
    }
}

/// Checks the invariants of the `body_format` contract.
func assertNormalized(_ runs: [TextRun], utf16Count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    var previousEnd = 0
    var previousFlags: TextFlags?
    for run in runs {
        #expect(run.length > 0, sourceLocation: sourceLocation)
        #expect(!run.flags.isEmpty, sourceLocation: sourceLocation)
        #expect(run.start >= previousEnd, sourceLocation: sourceLocation)
        #expect(run.end <= utf16Count, sourceLocation: sourceLocation)
        if run.start == previousEnd, let previousFlags {
            #expect(previousFlags != run.flags, "adjacent identical runs must merge", sourceLocation: sourceLocation)
        }
        previousEnd = run.end
        previousFlags = run.flags
    }
}

@Suite("RichText editing")
struct EditingTests {
    let text = "hello world" // 11 code units

    @Test func flagsAtOffset() {
        let runs = [TextRun(start: 0, length: 5, bold: true), TextRun(start: 3, length: 4, italic: true)]
        #expect(RichText.flags(at: 0, in: runs) == .bold)
        #expect(RichText.flags(at: 4, in: runs) == [.bold, .italic])
        #expect(RichText.flags(at: 6, in: runs) == .italic)
        #expect(RichText.flags(at: 7, in: runs).isEmpty)
        #expect(RichText.flags(at: -1, in: runs).isEmpty)
    }

    @Test func activeFlagsCoverWholeRange() {
        let runs = [TextRun(start: 0, length: 5, bold: true), TextRun(start: 5, length: 6, bold: true, italic: true)]
        #expect(RichText.activeFlags(in: 0..<11, runs: runs) == .bold)
        #expect(RichText.activeFlags(in: 6..<9, runs: runs) == [.bold, .italic])
        #expect(RichText.activeFlags(in: 3..<12, runs: runs).isEmpty)
        // A caret takes the flags of the character before it, or the first character at the start.
        #expect(RichText.activeFlags(in: 5..<5, runs: runs) == .bold)
        #expect(RichText.activeFlags(in: 6..<6, runs: runs) == [.bold, .italic])
        #expect(RichText.activeFlags(in: 0..<0, runs: runs) == .bold)
    }

    @Test func toggleAddsWhenRangeIsOnlyPartlyStyled() {
        let runs = [TextRun(start: 0, length: 5, bold: true)]
        let result = RichText.toggle(.bold, in: 3..<8, runs: runs, utf16Count: 11)
        #expect(result == [TextRun(start: 0, length: 8, bold: true)])
    }

    @Test func toggleRemovesWhenWholeRangeIsStyled() {
        let runs = [TextRun(start: 0, length: 11, bold: true)]
        let result = RichText.toggle(.bold, in: 3..<5, runs: runs, utf16Count: 11)
        #expect(result == [TextRun(start: 0, length: 3, bold: true), TextRun(start: 5, length: 6, bold: true)])
    }

    @Test func toggleKeepsOtherFlags() {
        let runs = [TextRun(start: 0, length: 5, bold: true, italic: true)]
        #expect(RichText.toggle(.bold, in: 0..<5, runs: runs, utf16Count: 11) == [TextRun(start: 0, length: 5, italic: true)])
        #expect(RichText.toggle(.underline, in: 2..<7, runs: runs, utf16Count: 11) == [
            TextRun(start: 0, length: 2, bold: true, italic: true),
            TextRun(start: 2, length: 3, bold: true, italic: true, underline: true),
            TextRun(start: 5, length: 2, underline: true),
        ])
    }

    @Test func toggleTwiceRestoresUnstyledRange() {
        let runs = [TextRun(start: 0, length: 2, italic: true), TextRun(start: 8, length: 3, underline: true)]
        let once = RichText.toggle(.bold, in: 3..<7, runs: runs, utf16Count: 11)
        #expect(once != runs)
        #expect(RichText.toggle(.bold, in: 3..<7, runs: once, utf16Count: 11) == runs)
    }

    @Test func toggleIgnoresEmptyAndClampsOutOfBounds() {
        let runs = [TextRun(start: 0, length: 3, bold: true)]
        #expect(RichText.toggle(.italic, in: 4..<4, runs: runs, utf16Count: 11) == runs)
        #expect(RichText.toggle(.italic, in: 20..<30, runs: runs, utf16Count: 11) == runs)
        #expect(RichText.toggle(.italic, in: 9..<30, runs: runs, utf16Count: 11) == [
            TextRun(start: 0, length: 3, bold: true),
            TextRun(start: 9, length: 2, italic: true),
        ])
        #expect(RichText.toggle([], in: 0..<5, runs: runs, utf16Count: 11) == runs)
    }

    @Test func toggleWithNSRange() {
        let runs: [TextRun] = []
        #expect(RichText.toggle(.underline, in: NSRange(location: 6, length: 5), runs: runs, utf16Count: 11)
            == [TextRun(start: 6, length: 5, underline: true)])
        #expect(RichText.toggle(.underline, in: NSRange(location: NSNotFound, length: 0), runs: runs, utf16Count: 11).isEmpty)
        #expect(RichText.utf16Range(NSRange(location: 2, length: 3)) == 2..<5)
        #expect(RichText.utf16Range(NSRange(location: NSNotFound, length: 0)) == nil)
    }

    @Test func toggleOverEmojiUsesUTF16Offsets() throws {
        let body = "I ❤️ 🐶 so much"
        let dog = try #require(body.range(of: "🐶"))
        let selection = NSRange(dog, in: body)
        #expect(selection.length == 2)
        let runs = RichText.toggle(.bold, in: selection, runs: [], utf16Count: body.utf16.count)
        #expect(runs == [TextRun(start: selection.location, length: 2, bold: true)])
        let attributed = RichText.attributedString(body, runs: runs)
        let boldText = attributed.runs.compactMap { run -> String? in
            run.inlinePresentationIntent == .stronglyEmphasized ? String(attributed[run.range].characters) : nil
        }
        #expect(boldText == ["🐶"])
    }

    @Test func settingExplicitly() {
        let runs = [TextRun(start: 0, length: 6, italic: true)]
        #expect(RichText.setting(.italic, to: false, in: 2..<4, runs: runs, utf16Count: 11) == [
            TextRun(start: 0, length: 2, italic: true), TextRun(start: 4, length: 2, italic: true),
        ])
        #expect(RichText.setting(.italic, to: true, in: 4..<9, runs: runs, utf16Count: 11) == [TextRun(start: 0, length: 9, italic: true)])
    }
}

@Suite("RichText <-> AttributedString")
struct AttributedStringTests {
    @Test("Round trips runs", arguments: [
        ("Plain text only", [TextRun]()),
        ("Be yourself; everyone else is already taken.", [
            TextRun(start: 0, length: 11, bold: true),
            TextRun(start: 13, length: 8, italic: true, underline: true),
            TextRun(start: 37, length: 7, bold: true, italic: true, underline: true),
        ]),
        ("👍🏽 thumbs 🇺🇸 flag", [
            TextRun(start: 0, length: 4, bold: true),
            TextRun(start: 4, length: 7, italic: true),
            TextRun(start: 12, length: 4, underline: true),
        ]),
        ("e\u{301}te\u{301} cafe\u{301}", [
            TextRun(start: 0, length: 1, bold: true),
            TextRun(start: 1, length: 2, italic: true),
            TextRun(start: 10, length: 1, underline: true),
        ]),
        ("multi\nline\n\ntext", [TextRun(start: 3, length: 6, bold: true)]),
    ])
    func roundTrips(body: String, runs: [TextRun]) {
        let attributed = RichText.attributedString(body, runs: runs)
        #expect(RichText.body(of: attributed) == body)
        #expect(RichText.runs(from: attributed) == runs)
    }

    @Test func mapsFlagsToTheExpectedAttributes() {
        let body = "bold italic under"
        let attributed = RichText.attributedString(body, runs: [
            TextRun(start: 0, length: 4, bold: true),
            TextRun(start: 5, length: 6, italic: true),
            TextRun(start: 12, length: 5, underline: true),
        ])
        let runs = Array(attributed.runs)
        #expect(runs.count == 5)
        #expect(runs[0].inlinePresentationIntent == .stronglyEmphasized)
        #expect(runs[2].inlinePresentationIntent == .emphasized)
        #expect(runs[4].underlineStyle == .single)
        #expect(runs[4].inlinePresentationIntent == nil)
        #expect(runs[1].inlinePresentationIntent == nil && runs[1].underlineStyle == nil)
    }

    @Test func badRunsNeverCrashRendering() {
        let body = "😀 hi"
        let attributed = RichText.attributedString(body, runs: [
            TextRun(start: 1, length: 1, bold: true),
            TextRun(start: -1, length: 3, italic: true),
            TextRun(start: 3, length: .max, underline: true),
            TextRun(start: .max, length: 1, bold: true),
        ])
        #expect(RichText.body(of: attributed) == body)
        #expect(RichText.runs(from: attributed) == [
            TextRun(start: 0, length: 2, bold: true, italic: true),
            TextRun(start: 3, length: 2, underline: true),
        ])
    }

    @Test func readsMarkdownIntents() throws {
        let attributed = try AttributedString(markdown: "**bold** and *it* and ***both***")
        #expect(RichText.body(of: attributed) == "bold and it and both")
        #expect(RichText.runs(from: attributed) == [
            TextRun(start: 0, length: 4, bold: true),
            TextRun(start: 9, length: 2, italic: true),
            TextRun(start: 16, length: 4, bold: true, italic: true),
        ])
    }

    @Test func contentTypesExposeAttributedBody() {
        let quote = Quote(body: "Hi there", format: [TextRun(start: 0, length: 2, bold: true)])
        #expect(RichText.runs(from: quote.attributedBody) == quote.format)
        let snapshot = SnapshotQuote(quote)
        #expect(snapshot.attributedBody == quote.attributedBody)
    }
}

@Suite("RichText plain text")
struct PlainTextTests {
    @Test func attributionAndShareText() {
        #expect(RichText.attribution(author: "Oscar Wilde", source: nil) == "Oscar Wilde")
        #expect(RichText.attribution(author: "  ", source: "Letters") == "Letters")
        #expect(RichText.attribution(author: nil, source: nil) == nil)
        #expect(RichText.attribution(author: "Seneca", source: "Letters") == "Seneca, Letters")
        #expect(RichText.shareText(body: " Know thyself. ", author: "Socrates", source: nil) == "\u{201C}Know thyself.\u{201D}\n\u{2014} Socrates")
        #expect(RichText.shareText(body: "Anon", author: nil, source: "") == "\u{201C}Anon\u{201D}")
        let quote = Quote(body: "Hi", author: "Me")
        #expect(quote.shareText == "\u{201C}Hi\u{201D}\n\u{2014} Me")
    }

    @Test func previewCollapsesAndTruncates() {
        #expect(RichText.preview("  one\n\n two\tthree  ") == "one two three")
        let long = String(repeating: "word ", count: 50)
        let preview = RichText.preview(long, maxCharacters: 24)
        #expect(preview.count <= 24)
        #expect(preview.hasSuffix("\u{2026}"))
        #expect(!preview.contains("  "))
        #expect(RichText.preview("abc", maxCharacters: 0) == "")
        #expect(RichText.preview("👍🏽👍🏽👍🏽👍🏽", maxCharacters: 3) == "👍🏽👍🏽\u{2026}")
        #expect(RichText.utf16Count(of: "👍🏽") == 4)
    }

    @Test func collapsingKeepsLinesForPoems() {
        let poem = "\n  Hope is the thing   with feathers\r\nThat perches\tin the soul,\n\n\n\nAnd sings  \n \n"
        #expect(RichText.collapseWhitespaceKeepingLines(poem) == "Hope is the thing with feathers\nThat perches in the soul,\n\nAnd sings")
        #expect(RichText.collapseWhitespaceKeepingLines("One line") == "One line")
        #expect(RichText.collapseWhitespaceKeepingLines(" \n\t\n ") == "")
        #expect(RichText.collapseWhitespace(poem) == "Hope is the thing with feathers That perches in the soul, And sings")
    }
}
