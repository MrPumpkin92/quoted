import Foundation

/// The inline styles a quote body can carry.
public struct TextFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = TextFlags(rawValue: 1 << 0)
    public static let italic = TextFlags(rawValue: 1 << 1)
    public static let underline = TextFlags(rawValue: 1 << 2)

    /// Bold, italic and underline.
    public static let all: TextFlags = [.bold, .italic, .underline]
}

/// One styled range of a quote body, as stored in the `body_format` jsonb column.
///
/// `start` and `length` are UTF-16 code units (the same as `NSRange` and JavaScript). JSON keys are
/// `start`, `length`, `bold`, `italic` and `underline`; false flags are omitted when encoding and a
/// missing flag decodes as false. Use ``RichText/normalize(_:in:)`` before storing or rendering runs.
public struct TextRun: Hashable, Sendable {
    /// First UTF-16 offset covered by the run.
    public var start: Int
    /// Number of UTF-16 code units covered by the run.
    public var length: Int
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public init(start: Int, length: Int, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.start = start
        self.length = length
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    public init(start: Int, length: Int, flags: TextFlags) {
        self.init(
            start: start,
            length: length,
            bold: flags.contains(.bold),
            italic: flags.contains(.italic),
            underline: flags.contains(.underline)
        )
    }

    /// Creates a run covering a UTF-16 range.
    public init(range: Range<Int>, flags: TextFlags) {
        self.init(start: range.lowerBound, length: range.count, flags: flags)
    }

    /// One past the last UTF-16 offset covered. Saturates instead of overflowing on bad data.
    public var end: Int {
        let (sum, overflow) = start.addingReportingOverflow(length)
        if overflow { return length > 0 ? Int.max : Int.min }
        return sum
    }

    /// The covered UTF-16 range (empty when `length` is not positive).
    public var range: Range<Int> { start..<max(start, end) }

    /// The run's styles as an option set.
    public var flags: TextFlags {
        get {
            var flags: TextFlags = []
            if bold { flags.insert(.bold) }
            if italic { flags.insert(.italic) }
            if underline { flags.insert(.underline) }
            return flags
        }
        set {
            bold = newValue.contains(.bold)
            italic = newValue.contains(.italic)
            underline = newValue.contains(.underline)
        }
    }
}

extension TextRun: Codable {
    private enum CodingKeys: String, CodingKey {
        case start, length, bold, italic, underline
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        length = try container.decode(Int.self, forKey: .length)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(length, forKey: .length)
        if bold { try container.encode(true, forKey: .bold) }
        if italic { try container.encode(true, forKey: .italic) }
        if underline { try container.encode(true, forKey: .underline) }
    }
}

/// Anything with a plain `body` and its `body_format` runs.
public protocol RichTextContent {
    /// Plain text, used by notifications, search, plain sharing and accessibility.
    var body: String { get }
    /// Normalized UTF-16 style runs over `body`.
    var format: [TextRun] { get }
}

/// Decodes a `body_format` array without failing the whole row: malformed runs are skipped and a
/// missing, null or non-array value becomes `[]`. The caller still clamps the result to the body.
struct LossyRuns: Decodable {
    var runs: [TextRun] = []

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let run = try? container.decode(TextRun.self) {
                runs.append(run)
            } else if (try? container.decode(Skip.self)) == nil {
                break
            }
        }
    }

    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        body: String
    ) -> [TextRun] {
        let decoded: LossyRuns? = try? container.decodeIfPresent(LossyRuns.self, forKey: key)
        return RichText.normalize(decoded?.runs ?? [], in: body)
    }
}
