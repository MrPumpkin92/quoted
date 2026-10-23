import Foundation

/// Pure operations on `body_format` runs. All offsets are UTF-16 code units.
///
/// Normalized runs are sorted, non-overlapping, non-empty, clamped to the body, carry at least one
/// flag, and adjacent runs with identical flags are merged. Overlapping input runs combine their flags.
public enum RichText {
    /// The database allows at most this many runs per body.
    public static let maxRuns = 200

    // MARK: Normalization

    /// Normalizes runs against a body of `utf16Count` code units.
    public static func normalize(_ runs: [TextRun], utf16Count: Int) -> [TextRun] {
        let count = max(0, utf16Count)
        // Sweep line: +1/-1 per flag at each run boundary.
        var deltas: [Int: FlagCounts] = [:]
        for run in runs {
            let flags = run.flags
            guard !flags.isEmpty, run.length > 0 else { continue }
            let lower = clamp(run.start, to: count)
            let upper = clamp(run.end, to: count)
            guard upper > lower else { continue }
            deltas[lower, default: FlagCounts()].add(flags, 1)
            deltas[upper, default: FlagCounts()].add(flags, -1)
        }
        guard !deltas.isEmpty else { return [] }

        let points = deltas.keys.sorted()
        var active = FlagCounts()
        var result: [TextRun] = []
        for (index, point) in points.enumerated().dropLast() {
            active.merge(deltas[point]!)
            let flags = active.flags
            guard !flags.isEmpty else { continue }
            let next = points[index + 1]
            if let last = result.last, last.end == point, last.flags == flags {
                result[result.count - 1].length += next - point
            } else {
                result.append(TextRun(start: point, length: next - point, flags: flags))
            }
        }
        return result
    }

    /// Normalizes runs against `text`, also widening any boundary that falls inside a surrogate pair
    /// (for example in the middle of an emoji) to the whole Unicode scalar.
    public static func normalize(_ runs: [TextRun], in text: String) -> [TextRun] {
        let units = Array(text.utf16)
        let count = units.count
        func splitsScalar(_ offset: Int) -> Bool {
            offset > 0 && offset < count
                && UTF16.isTrailSurrogate(units[offset]) && UTF16.isLeadSurrogate(units[offset - 1])
        }
        let snapped = runs.compactMap { run -> TextRun? in
            guard run.length > 0, !run.flags.isEmpty else { return nil }
            var lower = clamp(run.start, to: count)
            var upper = clamp(run.end, to: count)
            if splitsScalar(lower) { lower -= 1 }
            if splitsScalar(upper) { upper += 1 }
            guard upper > lower else { return nil }
            return TextRun(range: lower..<upper, flags: run.flags)
        }
        return normalize(snapped, utf16Count: count)
    }

    // MARK: Queries

    /// The flags that apply to the code unit at `offset`.
    public static func flags(at offset: Int, in runs: [TextRun]) -> TextFlags {
        var flags: TextFlags = []
        for run in runs where run.start <= offset && offset < run.end {
            flags.formUnion(run.flags)
        }
        return flags
    }

    /// The flags that cover the whole range, for highlighting the editor's B/I/U buttons.
    ///
    /// For an empty range (a caret) this returns the flags of the character before the caret, or of
    /// the first character when the caret is at the start, matching how text views pick typing attributes.
    public static func activeFlags(in range: Range<Int>, runs: [TextRun]) -> TextFlags {
        if range.isEmpty {
            return flags(at: max(0, range.lowerBound - 1), in: runs)
        }
        // Only the part up to the range end matters, so clamp there.
        let normalized = normalize(runs, utf16Count: range.upperBound)
        var result: TextFlags = []
        for flag in [TextFlags.bold, .italic, .underline] {
            var covered = 0
            for run in normalized where run.flags.contains(flag) {
                let lower = max(run.start, range.lowerBound)
                let upper = min(run.end, range.upperBound)
                if upper > lower { covered += upper - lower }
            }
            if covered == range.count { result.insert(flag) }
        }
        return result
    }

    // MARK: Editing

    /// Toggles `flag` over a UTF-16 range, as the editor toolbar does: if the whole range already has
    /// the flag it is removed, otherwise it is added to the whole range. An empty range changes nothing.
    /// The result is normalized.
    public static func toggle(_ flag: TextFlags, in range: Range<Int>, runs: [TextRun], utf16Count: Int) -> [TextRun] {
        let normalized = normalize(runs, utf16Count: utf16Count)
        let count = max(0, utf16Count)
        let lower = clamp(range.lowerBound, to: count)
        let upper = clamp(range.upperBound, to: count)
        guard upper > lower, !flag.isEmpty else { return normalized }
        let clampedRange = lower..<upper
        let hasFlag = activeFlags(in: clampedRange, runs: normalized).isSuperset(of: flag)
        return setting(flag, to: !hasFlag, in: clampedRange, runs: normalized, utf16Count: count)
    }

    /// ``toggle(_:in:runs:utf16Count:)`` for an `NSRange` selection. `NSNotFound` changes nothing.
    public static func toggle(_ flag: TextFlags, in range: NSRange, runs: [TextRun], utf16Count: Int) -> [TextRun] {
        guard let swiftRange = utf16Range(range) else { return normalize(runs, utf16Count: utf16Count) }
        return toggle(flag, in: swiftRange, runs: runs, utf16Count: utf16Count)
    }

    /// Adds (`enabled == true`) or removes `flag` over a UTF-16 range. The result is normalized.
    public static func setting(
        _ flag: TextFlags,
        to enabled: Bool,
        in range: Range<Int>,
        runs: [TextRun],
        utf16Count: Int
    ) -> [TextRun] {
        if enabled {
            return normalize(runs + [TextRun(range: range, flags: flag)], utf16Count: utf16Count)
        }
        var pieces: [TextRun] = []
        for run in normalize(runs, utf16Count: utf16Count) {
            if run.start < range.lowerBound {
                pieces.append(TextRun(range: run.start..<min(run.end, range.lowerBound), flags: run.flags))
            }
            let lower = max(run.start, range.lowerBound)
            let upper = min(run.end, range.upperBound)
            if upper > lower {
                pieces.append(TextRun(range: lower..<upper, flags: run.flags.subtracting(flag)))
            }
            if run.end > range.upperBound {
                pieces.append(TextRun(range: max(run.start, range.upperBound)..<run.end, flags: run.flags))
            }
        }
        return normalize(pieces, utf16Count: utf16Count)
    }

    /// Converts an `NSRange` to a UTF-16 `Range<Int>`, or nil for `NSNotFound` or negative values.
    public static func utf16Range(_ range: NSRange) -> Range<Int>? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        let (upper, overflow) = range.location.addingReportingOverflow(range.length)
        guard !overflow else { return nil }
        return range.location..<upper
    }

    // MARK: Plain text

    /// The UTF-16 length of `text`, the unit every run offset uses.
    public static func utf16Count(of text: String) -> Int { text.utf16.count }

    /// "author, source", whichever parts are present and not blank, or nil.
    public static func attribution(author: String?, source: String?) -> String? {
        let parts = [author, source].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Plain text for the system share sheet and the clipboard: `“body”` then `— author, source`.
    public static func shareText(body: String, author: String?, source: String?) -> String {
        let quoted = "\u{201C}\(body.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
        guard let attribution = attribution(author: author, source: source) else { return quoted }
        return "\(quoted)\n\u{2014} \(attribution)"
    }

    /// A one-line preview: whitespace and newlines collapse to single spaces, and text longer than
    /// `maxCharacters` is cut at a word boundary when possible and ends with an ellipsis.
    public static func preview(_ body: String, maxCharacters: Int = 140) -> String {
        let collapsed = collapseWhitespace(body)
        guard maxCharacters > 0 else { return "" }
        guard collapsed.count > maxCharacters else { return collapsed }
        var cut = String(collapsed.prefix(maxCharacters - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maxCharacters / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Trims the ends and collapses inner runs of whitespace and newlines to one space.
    public static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Like ``collapseWhitespace(_:)``, but keeps line breaks so a poem keeps its shape: each line is
    /// collapsed on its own, runs of blank lines become one, and blank lines at the ends go.
    public static func collapseWhitespaceKeepingLines(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let collapsed = collapseWhitespace(String(line))
            if collapsed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(collapsed)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    static func clamp(_ value: Int, to count: Int) -> Int {
        min(max(value, 0), count)
    }

    private struct FlagCounts {
        var bold = 0
        var italic = 0
        var underline = 0

        mutating func add(_ flags: TextFlags, _ delta: Int) {
            if flags.contains(.bold) { bold += delta }
            if flags.contains(.italic) { italic += delta }
            if flags.contains(.underline) { underline += delta }
        }

        mutating func merge(_ other: FlagCounts) {
            bold += other.bold
            italic += other.italic
            underline += other.underline
        }

        var flags: TextFlags {
            var flags: TextFlags = []
            if bold > 0 { flags.insert(.bold) }
            if italic > 0 { flags.insert(.italic) }
            if underline > 0 { flags.insert(.underline) }
            return flags
        }
    }
}
