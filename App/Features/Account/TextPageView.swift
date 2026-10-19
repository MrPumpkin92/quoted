import Foundation
import SwiftUI

/// A bundled legal page (Terms, Privacy, Community Guidelines) rendered from its Markdown: headings
/// look like headings, lists get bullets, the privacy table becomes a card, and inline bold, italic
/// and links work. Text is selectable. `Route.textPage(page)` maps to `TextPageView(page:)`.
///
/// `{{SUPPORT_EMAIL}}` in a page becomes a `mailto:` link to `AppInfo.supportEmail`. Builds without
/// an address (Debug; Release refuses to build without one) drop each sentence that mentions it.
struct TextPageView: View {
    let page: LegalPage
    private let blocks: [LegalMarkdownBlock]

    init(page: LegalPage) {
        self.page = page
        var blocks = page.loadMarkdown().map {
            LegalMarkdown.resolvingPlaceholders(in: LegalMarkdown.parse($0), supportEmail: AppInfo.supportEmail)
        } ?? []
        // The navigation bar already shows the page title.
        if case .heading(1, _) = blocks.first {
            blocks.removeFirst()
        }
        self.blocks = blocks
    }

    var body: some View {
        ScrollView {
            if blocks.isEmpty {
                EmptyStateView(
                    systemImage: "doc.text",
                    title: "This page isn\u{2019}t available",
                    message: "Update Quoted from the App Store, then try again."
                )
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        LegalBlockView(block: block, isFirst: index == 0)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
        .groundBackground()
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// One Markdown block in the page's type scale.
private struct LegalBlockView: View {
    let block: LegalMarkdownBlock
    let isFirst: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(LegalMarkdown.inline(text))
                .font(Self.headingFont(level))
                .foregroundStyle(.primary)
                .padding(.top, isFirst ? 0 : (level <= 2 ? Theme.Spacing.s : Theme.Spacing.xxs))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(LegalMarkdown.inline(text))
                .font(.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            ListItems(items: items) { _ in "\u{2022}" }
        case .numbered(let items):
            ListItems(items: items) { index in "\(index + 1)." }
        case .table(let header, let rows):
            LegalTable(header: header, rows: rows)
        case .quote(let text):
            Text(LegalMarkdown.inline(text))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.leading, Theme.Spacing.s)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .accessibilityHidden(true)
                }
        case .rule:
            HairlineDivider()
                .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.weight(.bold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }
}

/// A bulleted or numbered list with hanging markers.
private struct ListItems: View {
    let items: [String]
    let marker: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(marker(index))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(LegalMarkdown.inline(item))
                        .font(.body)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A Markdown table as a card: each row's first cell as a label over the other cells.
private struct LegalTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        CardContainer(padding: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if let first = row.first {
                        Text(LegalMarkdown.inline(first))
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(Array(row.dropFirst().enumerated()), id: \.offset) { _, cell in
                        Text(LegalMarkdown.inline(cell))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.cardPadding)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: row))
                if index < rows.count - 1 {
                    HairlineDivider(leadingInset: Theme.Spacing.cardPadding)
                }
            }
        }
    }

    /// "Data: Your email address. Why: To sign you in…"
    private func accessibilityLabel(for row: [String]) -> String {
        row.enumerated().map { index, cell in
            let plain = String(LegalMarkdown.inline(cell).characters)
            guard index < header.count, !header[index].isEmpty else { return plain }
            return "\(header[index]): \(plain)"
        }
        .joined(separator: ". ")
    }
}

#Preview("Terms") {
    NavigationStack { TextPageView(page: .terms) }
        .previewEnvironment()
}

#Preview("Privacy") {
    NavigationStack { TextPageView(page: .privacy) }
        .previewEnvironment()
}

#Preview("Guidelines dark") {
    NavigationStack { TextPageView(page: .communityGuidelines) }
        .previewEnvironment()
        .preferredColorScheme(.dark)
}

// MARK: - Markdown parsing

/// A block of the bundled legal Markdown (`App/Resources/Legal/*.md`), parsed line by line.
///
/// Covers what those pages use: ATX headings, paragraphs, `-`/`*` and numbered lists, pipe tables,
/// block quotes and rules. Inline styling (bold, italic, links, code) stays in the text and is
/// rendered by `LegalMarkdown.inline(_:)`.
enum LegalMarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    /// A pipe table: the header cells and the body rows.
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule
}

enum LegalMarkdown {
    /// Splits Markdown source into blocks.
    static func parse(_ source: String) -> [LegalMarkdownBlock] {
        var blocks: [LegalMarkdownBlock] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var table: [[String]] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushList() {
            guard let current = list, !current.items.isEmpty else { list = nil; return }
            blocks.append(current.ordered ? .numbered(current.items) : .bullets(current.items))
            list = nil
        }
        func flushTable() {
            guard let header = table.first else { return }
            let rows = table.dropFirst().filter { !isDelimiterRow($0) }
            blocks.append(.table(header: header, rows: Array(rows)))
            table = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: " ")))
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushTable()
            flushQuote()
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(in: line) {
                flushAll()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if line.hasPrefix("|") {
                flushParagraph()
                flushList()
                flushQuote()
                table.append(cells(in: line))
                continue
            } else if !table.isEmpty {
                flushTable()
            }
            if isRule(line) {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else if !quote.isEmpty {
                flushQuote()
            }
            if let item = bulletItem(in: line) {
                flushParagraph()
                if list?.ordered != false { flushList() }
                if list == nil { list = (false, []) }
                list?.items.append(item)
                continue
            }
            if let item = numberedItem(in: line) {
                flushParagraph()
                if list?.ordered != true { flushList() }
                if list == nil { list = (true, []) }
                list?.items.append(item)
                continue
            }
            if list != nil, rawLine.hasPrefix("  ") {
                // An indented continuation of the last list item.
                if let last = list?.items.popLast() {
                    list?.items.append("\(last) \(line)")
                }
                continue
            }
            flushList()
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }

    // MARK: Placeholders

    /// Where the support address goes in the bundled pages.
    static let supportEmailPlaceholder = "{{SUPPORT_EMAIL}}"

    /// Fills the placeholders in parsed blocks. With an address, `{{SUPPORT_EMAIL}}` becomes a
    /// `mailto:` link showing the address. Without one, every sentence that contains it is dropped,
    /// then any block left empty, then any heading whose section is left empty, so the page reads as
    /// if the sentence was never there.
    static func resolvingPlaceholders(in blocks: [LegalMarkdownBlock], supportEmail: String?) -> [LegalMarkdownBlock] {
        let replacement = supportEmail.flatMap(emailLink(for:))
        var removedText = false

        func resolve(_ text: String) -> String? {
            guard text.contains(supportEmailPlaceholder) else { return text }
            if let replacement {
                return text.replacingOccurrences(of: supportEmailPlaceholder, with: replacement)
            }
            removedText = true
            let kept = sentences(in: text).filter { !$0.contains(supportEmailPlaceholder) }
            let joined = kept.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }

        let resolved: [LegalMarkdownBlock] = blocks.compactMap { block in
            switch block {
            case .heading(let level, let text):
                return resolve(text).map { .heading(level: level, text: $0) }
            case .paragraph(let text):
                return resolve(text).map { .paragraph($0) }
            case .bullets(let items):
                let kept = items.compactMap(resolve)
                return kept.isEmpty ? nil : .bullets(kept)
            case .numbered(let items):
                let kept = items.compactMap(resolve)
                return kept.isEmpty ? nil : .numbered(kept)
            case .table(let header, let rows):
                return .table(header: header, rows: rows.map { $0.map { resolve($0) ?? "" } })
            case .quote(let text):
                return resolve(text).map { .quote($0) }
            case .rule:
                return .rule
            }
        }
        return removedText ? withoutEmptySections(resolved) : resolved
    }

    /// `[address](mailto:address)`, with the visible address escaped for Markdown, or nil when the
    /// address can't form a `mailto:` URL.
    private static func emailLink(for address: String) -> String? {
        guard address.contains("@"), let url = URL(string: "mailto:\(address)") else { return nil }
        var label = ""
        for character in address {
            if "\\[]()*_`<>".contains(character) { label.append("\\") }
            label.append(character)
        }
        return "[\(label)](\(url.absoluteString))"
    }

    /// Splits a paragraph after each `.`, `?` or `!` that is followed by a space.
    private static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == " ", let previous, ".?!".contains(previous) {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        sentences.append(current)
        return sentences
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Drops headings with nothing under them before the next heading of the same or a higher level.
    private static func withoutEmptySections(_ blocks: [LegalMarkdownBlock]) -> [LegalMarkdownBlock] {
        // Walk backwards so a heading sees what is kept after it (an emptied subsection empties its
        // parent too).
        var reversedResult: [LegalMarkdownBlock] = []
        for block in blocks.reversed() {
            if case .heading(let level, _) = block {
                guard let next = reversedResult.last else { continue }
                if case .heading(let nextLevel, _) = next, nextLevel <= level { continue }
            }
            reversedResult.append(block)
        }
        return reversedResult.reversed()
    }

    /// Inline Markdown (bold, italic, links, code) as an `AttributedString`, or the plain text if it
    /// doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: Line kinds

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func bulletItem(in line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(in line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " else { return nil }
        return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func cells(in line: String) -> [String] {
        var text = Substring(line)
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|") { text = text.dropLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDelimiterRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
