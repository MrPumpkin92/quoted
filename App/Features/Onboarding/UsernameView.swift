// "Choose a username" (docs/ui-spec.md §2).
//
// RootView shows `UsernameView()` while `SessionStore.phase == .needsUsername`. `createProfile` moves
// the phase on by itself (to the starter pack, or the library if the user already has quotes).

import Accessibility
import OSLog
import QuotedCore
import QuotedKit
import SwiftUI

struct UsernameView: View {
    @Environment(SessionStore.self) private var session

    @State private var username = ""
    @State private var displayName = ""
    @State private var availability: Availability = .unknown
    /// A server or submit error, shown in red under the card.
    @State private var submitError: String?
    /// Set after a Continue attempt, so "too short" turns into an error instead of a hint.
    @State private var didAttemptSubmit = false
    @State private var isSubmitting = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case username
        case displayName
    }

    /// The server's answer for one normalized username.
    private enum Availability: Equatable {
        case unknown
        case checking(String)
        case available(String)
        case taken(String)
    }

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        card
                        messages
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaBar(edge: .bottom) {
                PrimaryButton("Continue", isLoading: isSubmitting) {
                    submit()
                }
                .disabled(!canSubmit)
                // The disabled button is translucent; keep scrolled content from showing through it.
                .background(Color.ground, in: Capsule())
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.m)
            }
            .groundBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") {
                        Task { await session.signOut() }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
        .task(id: validUsername) {
            await checkAvailability(of: validUsername)
        }
        .onAppear { focus = .username }
        .onChange(of: username) { _, new in
            // Usernames are lowercase; an "@" is already drawn in front of the field.
            var cleaned = new.lowercased()
            if cleaned.hasPrefix("@") { cleaned.removeFirst() }
            if cleaned != new { username = cleaned }
            submitError = nil
        }
        .onChange(of: displayName) { submitError = nil }
        .onChange(of: availability) { _, new in
            switch new {
            case .available(let name): AccessibilityNotification.Announcement("@\(name) is available").post()
            case .taken(let name): AccessibilityNotification.Announcement("@\(name) is taken").post()
            case .unknown, .checking: break
            }
        }
        .sensoryFeedback(.error, trigger: submitError) { _, new in new != nil }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Choose a username")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Text("Friends add you by your username. Your display name is optional.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var card: some View {
        CardContainer(padding: 0) {
            AuthFieldRow(label: "Username", onTap: { focus = .username }) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text(verbatim: "@")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Username", text: $username, prompt: Text("yourname"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .displayName }
                    availabilityBadge
                }
            }
            HairlineDivider(leadingInset: Theme.Spacing.cardPadding)
            AuthFieldRow(label: "Display name", onTap: { focus = .displayName }) {
                TextField("Display name", text: $displayName, prompt: Text("Optional"))
                    .textContentType(.name)
                    .submitLabel(.continue)
                    .focused($focus, equals: .displayName)
                    .onSubmit { submit() }
            }
        }
        .disabled(isSubmitting)
    }

    /// Trailing status in the username field: a spinner while checking, a check when free, "Taken".
    @ViewBuilder
    private var availabilityBadge: some View {
        switch currentAvailability {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking availability")
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Available")
        case .taken:
            Text("Taken")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.inlineError)
        case .unknown:
            EmptyView()
        }
    }

    /// The error (`.inlineError`) or the rules hint (secondary) under the card.
    @ViewBuilder
    private var messages: some View {
        if let error = errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.inlineError)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("3–20 characters: letters, numbers, underscores and periods.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Validation

    /// The normalized username when it passes `Username.validate`, else nil.
    private var validUsername: String? {
        try? Username.validate(username)
    }

    /// The availability for what is typed now (an answer for an older value doesn't count).
    private var currentAvailability: Availability {
        guard let name = validUsername else { return .unknown }
        switch availability {
        case .checking(name), .available(name), .taken(name): return availability
        default: return .unknown
        }
    }

    /// The first problem to show, or nil to show the hint.
    private var errorMessage: String? {
        if let submitError { return submitError }
        if case .taken = currentAvailability { return QuotedError.usernameTaken.userMessage }
        if !username.isEmpty {
            do throws(UsernameError) {
                _ = try Username.validate(username)
            } catch {
                // "Too short" is just the hint while typing; it becomes an error after Continue.
                switch error {
                case .tooShort, .empty:
                    if didAttemptSubmit { return error.errorDescription }
                case .invalidCharacters, .tooLong:
                    return error.errorDescription
                }
            }
        } else if didAttemptSubmit {
            return UsernameError.empty.errorDescription
        }
        if let displayNameError { return displayNameError }
        return nil
    }

    private var displayNameError: String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do throws(DisplayNameError) {
            _ = try DisplayName.validate(trimmed)
            return nil
        } catch {
            return error.errorDescription
        }
    }

    private var canSubmit: Bool {
        guard validUsername != nil, displayNameError == nil else { return false }
        if case .taken = currentAvailability { return false }
        return true
    }

    // MARK: Actions

    /// Debounced availability check; `.task(id:)` cancels it whenever the username changes.
    private func checkAvailability(of name: String?) async {
        guard let name else { return }
        do {
            try await Task.sleep(for: .milliseconds(450))
        } catch {
            return
        }
        availability = .checking(name)
        do {
            let isFree = try await session.isUsernameAvailable(name)
            guard !Task.isCancelled else { return }
            availability = isFree ? .available(name) : .taken(name)
        } catch {
            guard !Task.isCancelled else { return }
            // Not fatal: Continue still works, and createProfile reports a taken name.
            Logger.session.error("Username availability check failed: \(String(describing: error), privacy: .public)")
            availability = .unknown
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        didAttemptSubmit = true
        submitError = nil
        let name: String
        do {
            name = try Username.validate(username)
        } catch {
            focus = .username
            return
        }
        guard displayNameError == nil else {
            focus = .displayName
            return
        }
        if case .taken = currentAvailability {
            focus = .username
            return
        }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        focus = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await session.createProfile(
                    username: name,
                    displayName: trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
                )
            } catch {
                if QuotedError(error) == .usernameTaken {
                    availability = .taken(name)
                    focus = .username
                } else {
                    let message = error.friendlyMessage
                    submitError = message.isEmpty ? nil : message
                }
            }
        }
    }
}

#Preview("Username") {
    UsernameView()
        .previewEnvironment(.preview(phase: .needsUsername))
}

#Preview("Username, dark, large type") {
    UsernameView()
        .previewEnvironment(.preview(phase: .needsUsername))
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
