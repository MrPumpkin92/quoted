import OSLog
import QuotedCore
import SwiftUI
import UIKit

// MARK: - Add / Edit sheet (docs/ui-spec.md §7)

/// The Add / Edit quote sheet: a rich-text editor card (bold, italic, underline), Author and Source
/// rows, and the "Include in reminders" toggle. The shell presents `AddEditQuoteView(editing: nil)`
/// for `.addQuote` and `AddEditQuoteView(editing: quote)` for `.editQuote(quote)`.
///
/// Save stays disabled until the body is valid (`QuoteDraft.isValid`). A new quote waits for the
/// server (`LibraryStore.create`) with a spinner on Save, then closes with "Saved to your library"; a
/// failed save keeps the sheet open (the store already showed the toast).
struct AddEditQuoteView: View {
    let editing: Quote?

    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var form: QuoteForm
    /// The new quote's ID, kept for the sheet's lifetime: Save after a lost answer finds the quote
    /// the first Save created instead of adding a copy.
    @State private var newQuoteID = UUID()
    @State private var isSaving = false
    @State private var attemptedSave = false
    @State private var confirmingDiscard = false
    @FocusState private var focusedField: Field?

    @ScaledMetric(relativeTo: .title2) private var editorSize: CGFloat = QuoteStyle.editorBaseSize
    @ScaledMetric(relativeTo: .title2) private var editorMinHeight: CGFloat = 140
    @ScaledMetric(relativeTo: .body) private var labelWidth: CGFloat = 64

    private enum Field: Hashable {
        case author
        case source
    }

    /// - Parameters:
    ///   - editing: The quote to edit, or nil for a new one.
    ///   - pasted: Text the user pasted before the sheet opened (the Search tab's copied-quote card).
    ///     It goes through the same split as the Paste button. New quotes only.
    init(editing: Quote?, pasted: String? = nil) {
        self.editing = editing
        let form = QuoteForm(editing: editing)
        if editing == nil, let pasted {
            form.paste(pasted)
        }
        _form = State(initialValue: form)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        editorCard
                        if let message = visibleError {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.inlineError)
                                .padding(.horizontal, Theme.Spacing.xxs)
                                .accessibilityLabel("Error: \(message)")
                        }
                    }
                    attributionCard
                    remindersCard
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .groundBackground()
            .navigationTitle(editing == nil ? "New quote" : "Edit quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving || form.hasChanges)
        .task {
            // New quotes start typing at once; edits open on the text without the keyboard.
            guard editing == nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            form.editor.focus()
        }
    }

    // MARK: Cards

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            RichTextEditor(form: form, version: form.editor.version, minHeight: editorMinHeight)
                .overlay(alignment: .topLeading) {
                    if form.editor.body.isEmpty {
                        Text("Type or paste a quote")
                            .font(QuoteStyle.editor.font(editorSize: editorSize))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            if form.editor.body.isEmpty {
                QuotePasteButton(form: form)
                    .labelStyle(.titleAndIcon)
            }
        }
        .card(padding: Theme.Spacing.l)
    }

    private var attributionCard: some View {
        CardContainer(padding: 0) {
            fieldRow("Author", prompt: "Name", text: $form.author, field: .author)
                .submitLabel(.next)
                .onSubmit { focusedField = .source }
            HairlineDivider(leadingInset: Theme.Spacing.cardPadding)
            fieldRow("Source", prompt: "Optional", text: $form.source, field: .source)
                .submitLabel(.done)
                .onSubmit { save() }
        }
    }

    private func fieldRow(_ title: LocalizedStringKey, prompt: LocalizedStringKey, text: Binding<String>, field: Field) -> some View {
        LabeledContent {
            TextField(prompt, text: text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(minWidth: labelWidth, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.cardPadding)
        .frame(minHeight: Theme.Metrics.primaryButtonHeight)
    }

    private var remindersCard: some View {
        CardContainer {
            Toggle(isOn: $form.includeInReminders) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include in reminders")
                    Text("Shows up in widgets and reminders")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // Wrap instead of truncating at accessibility text sizes.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if form.hasChanges {
                    confirmingDiscard = true
                } else {
                    dismiss()
                }
            }
            .disabled(isSaving)
            .confirmationDialog(
                editing == nil ? "Discard this quote?" : "Discard your changes?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView()
                        .tint(Color.onAccent)
                        .accessibilityLabel("Saving")
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!form.canSave || isSaving)
        }
    }

    // MARK: Validation and saving

    /// Inline error: limits (too long, too much formatting) while typing; every problem after Save.
    private var visibleError: String? {
        form.validationMessage(includingEmptyBody: attemptedSave)
    }

    private func save() {
        guard !isSaving else { return }
        attemptedSave = true
        guard form.canSave else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            if await commit() {
                dismiss()
            }
        }
    }

    /// Writes the quote. Returns whether the sheet can close.
    private func commit() async -> Bool {
        let draft = form.draft
        guard let editing else {
            let created = await library.create(
                draft: draft, id: newQuoteID, includeInReminders: form.includeInReminders, origin: form.origin
            )
            guard let created else { return false }
            // Say it worked: the sheet closes onto a list that may be filtered or scrolled away from the
            // new quote (Library also switches to All and scrolls to it).
            toasts.show(
                created.isInRotation ? "Saved to your library and reminders" : "Saved to your library",
                style: .success
            )
            return true
        }
        guard let current = library.quote(id: editing.id) else {
            toasts.show("This quote was deleted.")
            return true
        }
        guard let validated = try? draft.validated() else { return false }
        var updated = current
        updated.body = validated.body
        updated.format = validated.format
        updated.author = validated.author
        updated.source = validated.source
        let contentChanged = updated.body != current.body || updated.format != current.format
            || updated.author != current.author || updated.source != current.source
        if contentChanged {
            guard await library.update(updated) else { return false }
        }
        if form.includeInReminders != current.isInRotation {
            guard await library.setInReminders(updated, form.includeInReminders) else { return false }
        }
        return true
    }
}

// MARK: - Form state

/// The sheet's editable state. A main-actor class (so the PasteButton callback can reach it safely).
@Observable
@MainActor
final class QuoteForm {
    let editor: RichTextEditorModel
    var author: String
    var source: String
    var includeInReminders: Bool
    /// `.pasted` once the PasteButton supplied text.
    private(set) var origin: QuoteOrigin = .manual

    private let originalDraft: QuoteDraft
    private let originalInReminders: Bool

    init(editing: Quote?) {
        let draft = editing.map(QuoteDraft.init(quote:)) ?? QuoteDraft()
        editor = RichTextEditorModel(body: draft.body, runs: draft.format)
        author = draft.author
        source = draft.source
        let inReminders = editing?.isInRotation ?? true
        includeInReminders = inReminders
        originalDraft = draft
        originalInReminders = inReminders
    }

    var draft: QuoteDraft {
        QuoteDraft(body: editor.body, format: editor.runs, author: author, source: source)
    }

    var canSave: Bool { draft.isValid }

    /// Whether anything differs from what the sheet opened with.
    var hasChanges: Bool {
        draft != originalDraft || includeInReminders != originalInReminders
    }

    /// The friendly validation message, or nil. An empty body only counts once the user tried to save
    /// (until then Save is simply disabled).
    func validationMessage(includingEmptyBody: Bool) -> String? {
        let draft = self.draft
        let result = Result { () throws(QuoteDraftError) -> QuoteDraft.Validated in try draft.validated() }
        guard case .failure(let error) = result else { return nil }
        if error == .emptyBody && !includingEmptyBody { return nil }
        return error.errorDescription
    }

    /// Handles text from a PasteButton. Into an empty editor, `“…” — Name, Work` is split into body,
    /// author and source (filling only empty fields); otherwise the text is inserted at the cursor.
    func paste(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        origin = .pasted
        if editor.isBlank {
            let parts = PastedQuote.parse(trimmed)
            editor.setContent(body: parts.body, runs: [])
            if author.trimmingCharacters(in: .whitespaces).isEmpty, let parsedAuthor = parts.author {
                author = parsedAuthor
            }
            if source.trimmingCharacters(in: .whitespaces).isEmpty, let parsedSource = parts.source {
                source = parsedSource
            }
        } else {
            editor.insert(trimmed)
        }
        Logger.ui.debug("Pasted \(trimmed.count, privacy: .public) characters into the editor")
    }
}

/// The system PasteButton (no paste permission prompt), feeding `QuoteForm.paste`.
private struct QuotePasteButton: View {
    let form: QuoteForm

    var body: some View {
        PasteButton(payloadType: String.self) { @Sendable [form] strings in
            guard let text = strings.first else { return }
            Task { @MainActor in form.paste(text) }
        }
        .buttonBorderShape(.capsule)
    }
}

/// The bar above the keyboard while the editor is focused: B / I / U reflecting the selection, then
/// Paste. `ToolbarItemGroup(placement: .keyboard)` only serves SwiftUI text inputs, so the editor's
/// `UITextView` hosts this as its `inputAccessoryView`.
private struct EditorKeyboardBar: View {
    let form: QuoteForm

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            FormatToggleButton(flag: .bold, systemImage: "bold", title: "Bold", editor: form.editor)
            FormatToggleButton(flag: .italic, systemImage: "italic", title: "Italic", editor: form.editor)
            FormatToggleButton(flag: .underline, systemImage: "underline", title: "Underline", editor: form.editor)
            Spacer(minLength: Theme.Spacing.s)
            QuotePasteButton(form: form)
                .labelStyle(.titleAndIcon)
        }
        .padding(.leading, Theme.Spacing.xxs)
        .padding(.trailing, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .tint(Color.accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
    }
}

/// A B / I / U toolbar toggle. Selected state uses `AccentSoft` behind an accent glyph.
private struct FormatToggleButton: View {
    let flag: TextFlags
    let systemImage: String
    let title: LocalizedStringKey
    let editor: RichTextEditorModel

    var body: some View {
        let isOn = editor.isActive(flag)
        Button {
            editor.toggle(flag)
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                .background(isOn ? Color.accentSoft : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

// MARK: - Rich-text editor model

/// The editor's state: the plain body, its UTF-16 runs, and the B/I/U state of the selection.
///
/// The `UITextView` holds the text. Styles live on it as a custom attribute (`quotedFlags`) and are
/// drawn with fonts and underline derived from it, so font substitution (emoji, other scripts) can never
/// lose a style. Typing inherits the active flags through `typingAttributes`.
@Observable
@MainActor
final class RichTextEditorModel {
    /// The plain text.
    private(set) var body: String
    /// Normalized runs over `body` (UTF-16 offsets).
    private(set) var runs: [TextRun]
    /// The flags of the selection, or the typing flags at a caret.
    private(set) var activeFlags: TextFlags = []
    /// Whether the text view is first responder.
    private(set) var isFocused = false
    /// Bumped on every content change (drives the editor's height).
    private(set) var version = 0

    @ObservationIgnored fileprivate weak var textView: RichTextView?
    @ObservationIgnored private var focusRequested = false

    init(body: String = "", runs: [TextRun] = []) {
        self.body = body
        self.runs = RichText.normalize(runs, in: body)
    }

    /// Whether the body is empty or only whitespace.
    var isBlank: Bool { body.allSatisfy { $0.isWhitespace || $0.isNewline } }

    /// Whether `flag` is on for the selection (or for typing at the caret).
    func isActive(_ flag: TextFlags) -> Bool { activeFlags.isSuperset(of: flag) }

    /// The toolbar's B / I / U: toggles the flag over the selection with `RichText.toggle`, or flips
    /// the typing flags at a caret.
    func toggle(_ flag: TextFlags) {
        guard let view = textView else { return }
        let selection = view.selectedRange
        if selection.length == 0 {
            let flags = view.typingFlags.symmetricDifference(flag)
            view.setTypingFlags(flags)
            activeFlags = flags
        } else {
            let toggled = RichText.toggle(flag, in: selection, runs: view.readRuns(), utf16Count: view.textStorage.length)
            view.restyle(runs: toggled)
            runs = view.readRuns()
            version &+= 1
            if let range = RichText.utf16Range(selection) {
                activeFlags = RichText.activeFlags(in: range, runs: runs)
            }
        }
    }

    /// Replaces the whole text (paste into an empty editor).
    func setContent(body: String, runs: [TextRun]) {
        let normalized = RichText.normalize(runs, in: body)
        self.body = body
        self.runs = normalized
        version &+= 1
        if let view = textView {
            view.load(body: body, runs: normalized)
            activeFlags = view.typingFlags
        }
    }

    /// Inserts plain text at the selection, with the typing flags.
    func insert(_ text: String) {
        guard let view = textView else {
            setContent(body: body + text, runs: runs)
            return
        }
        view.insertText(text)
        textDidChange(in: view)
    }

    /// Makes the editor first responder (now, or once it is on screen).
    func focus() {
        if let view = textView, view.window != nil {
            view.becomeFirstResponder()
        } else {
            focusRequested = true
            textView?.focusWhenInWindow = true
        }
    }

    // MARK: Text view callbacks

    fileprivate func attach(_ view: RichTextView) {
        textView = view
        view.load(body: body, runs: runs)
        if focusRequested {
            focusRequested = false
            view.focusWhenInWindow = true
        }
    }

    fileprivate func textDidChange(in view: RichTextView) {
        let newRuns = view.readRuns()
        if view.markedTextRange == nil {
            view.restyle(runs: newRuns)
        }
        body = view.textStorage.string
        runs = newRuns
        version &+= 1
        updateActiveFlags(in: view, resettingTypingFlags: false)
    }

    fileprivate func selectionDidChange(in view: RichTextView) {
        updateActiveFlags(in: view, resettingTypingFlags: true)
    }

    fileprivate func setFocused(_ focused: Bool) {
        isFocused = focused
    }

    private func updateActiveFlags(in view: RichTextView, resettingTypingFlags: Bool) {
        let selection = view.selectedRange
        guard selection.location != NSNotFound else { return }
        if selection.length > 0, let range = RichText.utf16Range(selection) {
            activeFlags = RichText.activeFlags(in: range, runs: view.readRuns())
            return
        }
        guard resettingTypingFlags, view.markedTextRange == nil else {
            activeFlags = view.typingFlags
            return
        }
        // A caret takes the style of the character before it (the first one at the start).
        let flags = view.flagsBeforeCaret
        if flags != view.typingFlags {
            view.setTypingFlags(flags)
        }
        activeFlags = flags
    }
}

// MARK: - UITextView

private extension NSAttributedString.Key {
    /// The run flags (`TextFlags.rawValue` as an `NSNumber`) of a range of the editor's text.
    static let quotedFlags = NSAttributedString.Key("com.hwei.quoted.textFlags")
}

/// The editor's text view: serif, about 26 pt scaled with `.title2`, no scrolling of its own (it grows
/// inside the sheet's ScrollView), plain-text paste.
final class RichTextView: UITextView {
    /// Becomes first responder as soon as the view is in a window.
    var focusWhenInWindow = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        isScrollEnabled = false
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        allowsEditingTextAttributes = false
        autocapitalizationType = .sentences
        accessibilityLabel = String(localized: "Quote")
        accessibilityHint = String(localized: "Type or paste a quote")
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        typingAttributes = Self.attributes(for: [], traits: traitCollection)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: RichTextView, _: UITraitCollection) in
            view.restyle(runs: view.readRuns())
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard focusWhenInWindow, window != nil else { return }
        focusWhenInWindow = false
        Task { @MainActor [weak self] in
            self?.becomeFirstResponder()
        }
    }

    // MARK: Styles

    /// The flags new text gets.
    var typingFlags: TextFlags { Self.flags(from: typingAttributes[.quotedFlags]) }

    func setTypingFlags(_ flags: TextFlags) {
        typingAttributes = Self.attributes(for: flags, traits: traitCollection)
    }

    /// The flags of the character before the caret (of the first character at the start). Keeps the
    /// typing flags in an empty editor.
    var flagsBeforeCaret: TextFlags {
        let length = textStorage.length
        guard length > 0 else { return typingFlags }
        let index = min(max(selectedRange.location - 1, 0), length - 1)
        return Self.flags(from: textStorage.attribute(.quotedFlags, at: index, effectiveRange: nil))
    }

    /// Replaces the text (the caret moves to the end).
    func load(body: String, runs: [TextRun]) {
        let attributed = NSMutableAttributedString(string: body, attributes: Self.attributes(for: [], traits: traitCollection))
        let length = attributed.length
        for run in RichText.normalize(runs, in: body) where run.end <= length {
            attributed.setAttributes(Self.attributes(for: run.flags, traits: traitCollection), range: NSRange(location: run.start, length: run.length))
        }
        attributedText = attributed
        setTypingFlags(length > 0 ? RichText.flags(at: length - 1, in: runs) : [])
    }

    /// The runs stored on the text.
    func readRuns() -> [TextRun] {
        var runs: [TextRun] = []
        let storage = textStorage
        storage.enumerateAttribute(.quotedFlags, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let flags = Self.flags(from: value)
            guard !flags.isEmpty, range.location != NSNotFound else { return }
            runs.append(TextRun(start: range.location, length: range.length, flags: flags))
        }
        return RichText.normalize(runs, in: storage.string)
    }

    /// Re-applies fonts, underline and flags for `runs` without touching the text or the selection.
    func restyle(runs: [TextRun]) {
        let typing = typingFlags
        let storage = textStorage
        let length = storage.length
        storage.beginEditing()
        storage.setAttributes(Self.attributes(for: [], traits: traitCollection), range: NSRange(location: 0, length: length))
        for run in runs where run.end <= length {
            storage.setAttributes(Self.attributes(for: run.flags, traits: traitCollection), range: NSRange(location: run.start, length: run.length))
        }
        storage.endEditing()
        setTypingFlags(typing)
    }

    static func attributes(for flags: TextFlags, traits: UITraitCollection) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = QuoteStyle.editor.lineSpacing
        var attributes: [NSAttributedString.Key: Any] = [
            .font: QuoteStyle.editorUIFont(bold: flags.contains(.bold), italic: flags.contains(.italic), compatibleWith: traits),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
        if flags.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let stored = flags.intersection(.all)
        if !stored.isEmpty {
            attributes[.quotedFlags] = NSNumber(value: stored.rawValue)
        }
        return attributes
    }

    private static func flags(from value: Any?) -> TextFlags {
        guard let number = value as? NSNumber else { return [] }
        return TextFlags(rawValue: number.uint8Value).intersection(.all)
    }
}

/// SwiftUI wrapper for `RichTextView`. Grows with its text (at least `minHeight`), with the
/// `EditorKeyboardBar` above the keyboard.
private struct RichTextEditor: UIViewRepresentable {
    let form: QuoteForm
    /// The editor's content version, so SwiftUI re-measures the height as the text changes.
    let version: Int
    let minHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(model: form.editor)
    }

    func makeUIView(context: Context) -> RichTextView {
        let view = RichTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator

        let bar = UIHostingController(rootView: EditorKeyboardBar(form: form))
        bar.sizingOptions = .intrinsicContentSize
        bar.view.backgroundColor = .clear
        bar.view.frame = CGRect(x: 0, y: 0, width: 320, height: 64)
        bar.view.autoresizingMask = .flexibleHeight
        context.coordinator.keyboardBar = bar
        view.inputAccessoryView = bar.view

        form.editor.attach(view)
        return view
    }

    func updateUIView(_ uiView: RichTextView, context: Context) {
        uiView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(ceil(fitting.height), minHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let model: RichTextEditorModel
        /// Keeps the keyboard bar's hosting controller alive (its view is the input accessory).
        var keyboardBar: UIHostingController<EditorKeyboardBar>?

        init(model: RichTextEditorModel) {
            self.model = model
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? RichTextView else { return }
            model.textDidChange(in: view)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let view = textView as? RichTextView else { return }
            model.selectionDidChange(in: view)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            model.setFocused(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            model.setFocused(false)
        }
    }
}

// MARK: - Previews

#Preview("New quote") {
    Color.ground
        .sheet(isPresented: .constant(true)) {
            AddEditQuoteView(editing: nil)
                .toastHost()
        }
        .previewEnvironment()
}

#Preview("Edit quote") {
    Color.ground
        .sheet(isPresented: .constant(true)) {
            AddEditQuoteView(editing: Samples.emerson)
                .toastHost()
        }
        .previewEnvironment()
}

#Preview("Edit quote, dark") {
    Color.ground
        .sheet(isPresented: .constant(true)) {
            AddEditQuoteView(editing: Samples.shelley)
                .toastHost()
        }
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
