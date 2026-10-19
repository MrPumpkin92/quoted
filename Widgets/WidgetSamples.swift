import Foundation
import QuotedCore

/// Built-in quotes for the widget gallery, the placeholder and previews.
enum WidgetSamples {
    /// The gallery and placeholder quote.
    static let shakespeare = SnapshotQuote(
        id: id(1),
        body: "This above all: to thine own self be true.",
        author: "William Shakespeare",
        source: "Hamlet"
    )

    /// "Trust thyself" in bold, as in the Margin render.
    static let emerson = SnapshotQuote(
        id: id(2),
        body: "Trust thyself: every heart vibrates to that iron string.",
        format: [TextRun(start: 0, length: 13, bold: true)],
        author: "Ralph Waldo Emerson",
        source: "Self-Reliance"
    )

    /// "fearless" in italic.
    static let shelley = SnapshotQuote(
        id: id(3),
        body: "Beware; for I am fearless, and therefore powerful.",
        format: [TextRun(start: 17, length: 8, italic: true)],
        author: "Mary Shelley",
        source: "Frankenstein"
    )

    /// A long quote, for truncation and scaling.
    static let austen = SnapshotQuote(
        id: id(4),
        body: "There is a stubbornness about me that never can bear to be frightened at the will of others. My courage always rises at every attempt to intimidate me.",
        author: "Jane Austen",
        source: "Pride and Prejudice"
    )

    /// No author or source.
    static let anonymous = SnapshotQuote(
        id: id(5),
        body: "Begin anywhere."
    )

    private static func id(_ last: UInt8) -> UUID {
        UUID(uuid: (0x51, 0x55, 0x4F, 0x54, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, last))
    }
}
