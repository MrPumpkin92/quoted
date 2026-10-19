import Foundation
// SwiftUI is imported only for its AttributedString scope (`underlineStyle`). Nothing else in
// QuotedCore depends on SwiftUI.
import SwiftUI

extension RichText {
    /// Builds an `AttributedString` for SwiftUI `Text` and widgets.
    ///
    /// Bold maps to `inlinePresentationIntent.stronglyEmphasized`, italic to `.emphasized` (Foundation),
    /// and underline to the SwiftUI `underlineStyle` `.single`. Runs are normalized against `body`
    /// first, so out-of-range or overlapping data can never crash rendering.
    public static func attributedString(_ body: String, runs: [TextRun]) -> AttributedString {
        var attributed = AttributedString(body)
        let normalized = normalize(runs, in: body)
        guard !normalized.isEmpty else { return attributed }
        let utf16 = attributed.utf16
        for run in normalized {
            let lower = utf16.index(utf16.startIndex, offsetBy: run.start)
            let upper = utf16.index(lower, offsetBy: run.length)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if !intent.isEmpty {
                attributed[lower..<upper].inlinePresentationIntent = intent
            }
            if run.underline {
                attributed[lower..<upper].underlineStyle = .single
            }
        }
        return attributed
    }

    /// Reads normalized runs back from an `AttributedString`.
    ///
    /// `stronglyEmphasized` is bold, `emphasized` is italic, and any SwiftUI `underlineStyle` is
    /// underline. Other attributes are ignored. The matching body is `String(attributed.characters)`.
    public static func runs(from attributed: AttributedString) -> [TextRun] {
        var runs: [TextRun] = []
        let utf16 = attributed.utf16
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var flags: TextFlags = []
            if intent.contains(.stronglyEmphasized) { flags.insert(.bold) }
            if intent.contains(.emphasized) { flags.insert(.italic) }
            if run.underlineStyle != nil { flags.insert(.underline) }
            guard !flags.isEmpty else { continue }
            let start = utf16.distance(from: utf16.startIndex, to: run.range.lowerBound)
            let length = utf16.distance(from: run.range.lowerBound, to: run.range.upperBound)
            runs.append(TextRun(start: start, length: length, flags: flags))
        }
        return normalize(runs, utf16Count: utf16.count)
    }

    /// The plain body of an `AttributedString`, matching the offsets of ``runs(from:)``.
    public static func body(of attributed: AttributedString) -> String {
        String(attributed.characters)
    }
}

extension RichTextContent {
    /// The styled body for SwiftUI `Text`.
    public var attributedBody: AttributedString {
        RichText.attributedString(body, runs: format)
    }
}
