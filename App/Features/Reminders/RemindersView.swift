import QuotedCore
import SwiftUI

/// The Reminders screen (docs/ui-spec.md §8), pushed from the Library status card and `quoted://rotation`.
///
/// A settings card ("Send reminders" with its schedule line, how often, the time window and the days),
/// a banner when notifications are off for Quoted, then the reminder quotes in order: a segmented In
/// order / Shuffle control, the rows and an "Add quotes" picker. The toggle reads on only while
/// reminders actually go out (`ReminderStore.isDelivering`): without notification permission it
/// shows off and says why, and turning it on asks for permission (or opens Settings when denied).
///
/// A row is removed from reminders (not deleted) with the trailing "Remove" swipe in accent or the
/// context menu's "Remove from reminders", each with Undo, which puts the quote back in its place.
/// Edit (In order only) shows drag handles to reorder; there are no delete controls. VoiceOver gets
/// Remove, Move up and Move down actions. In Shuffle the rows have no numbers, can't be reordered
/// (no handles, no Move actions) and the footer says "Shown in random order".
/// Every change goes straight to `ReminderStore.settings` or `LibraryStore`, which save and replan
/// notifications and the widget. The stepper and the time pickers are debounced by half a second,
/// so scrubbing them replans once.
struct RemindersView: View {
    @Environment(ReminderStore.self) private var reminders
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Unsaved stepper and time-picker values, committed after `debounce`.
    @State private var draft: ScheduleDraft?
    /// Whether this screen has read the notification permission (so "Allow" never flashes before).
    @State private var permissionChecked = false
    /// Edit shows the drag handles (reorder only; nothing here deletes a quote).
    @State private var editMode: EditMode = .inactive
    @State private var isRetrying = false

    /// How long the stepper and the time pickers wait before saving.
    static let debounce: Duration = .milliseconds(500)

    init() {}

    var body: some View {
        let quotes = library.reminderQuotes
        List {
            if permissionChecked,
               let banner = PermissionBanner.Kind(permission: reminders.permission, enabled: reminders.settings.enabled) {
                Section {
                    PermissionBanner(kind: banner)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                .listSectionMargins(.horizontal, Theme.Spacing.gutter)
            }

            Section {
                // A 16-pt inset on every iPhone (the system's is 16 on 375-pt screens and 20 on wider
                // ones), so the Days label below can line up with these labels everywhere.
                Group {
                    remindersToggle
                    frequencyRow
                    windowRow
                }
                .listRowInsets(.horizontal, Theme.Spacing.cardPadding)
                daysRow
            }
            .listRowBackground(Color.surface)
            .listRowSeparatorTint(Color.hairline)
            .listSectionMargins(.horizontal, Theme.Spacing.gutter)

            quotesSection(quotes)

            if library.hasLoaded, !quotes.isEmpty {
                addQuotesSection
            }
        }
        .listStyle(.insetGrouped)
        .groundBackground()
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if canReorder(quotes) {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .accessibilityHint("Shows handles to reorder your reminders")
                }
            }
        }
        .onChange(of: canReorder(quotes)) { _, canReorder in
            if !canReorder { editMode = .inactive }
        }
        // Outside `.toolbar`, so the Edit button and the list share this edit mode.
        .environment(\.editMode, $editMode)
        .task {
            await reminders.refreshPermission()
            permissionChecked = true
        }
        .task(id: draft) {
            guard draft != nil else { return }
            do {
                try await Task.sleep(for: Self.debounce)
            } catch {
                return
            }
            commitDraft()
        }
        .onDisappear(perform: commitDraft)
    }

    // MARK: Settings card

    private var remindersToggle: some View {
        Toggle(isOn: enabledBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send reminders")
                Text(toggleSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: Theme.Metrics.minTouchTarget)
    }

    /// The line under the toggle: the schedule while reminders go out ("Every day · Next at 8:00 PM"),
    /// otherwise why they don't ("Off", or waiting for / denied notification permission).
    private var toggleSubtitle: String {
        reminders.isDelivering ? reminders.scheduleSummary : reminders.statusLine
    }

    private var frequencyRow: some View {
        let times = draft?.timesPerDay ?? reminders.settings.timesPerDay
        return Stepper(value: timesPerDayBinding, in: ReminderSettings.timesPerDayRange) {
            adaptiveRow {
                Text("How often")
            } trailing: {
                Text("\(times)\u{00D7} a day")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: Theme.Metrics.minTouchTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("How often")
        .accessibilityValue(times == 1 ? "Once a day" : "\(times) times a day")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: timesPerDayBinding.wrappedValue = min(times + 1, ReminderSettings.timesPerDayRange.upperBound)
            case .decrement: timesPerDayBinding.wrappedValue = max(times - 1, ReminderSettings.timesPerDayRange.lowerBound)
            @unknown default: break
            }
        }
    }

    private var windowRow: some View {
        let start = draft?.windowStart ?? reminders.settings.windowStartTime
        let end = draft?.windowEnd ?? reminders.settings.windowEndTime
        let dayStart = Calendar.current.startOfDay(for: start)
        let lastMinute = dayStart.addingTimeInterval(23 * 3600 + 59 * 60)
        // Start stays at least a minute before end: each picker's range stops at the other's value.
        let startPicker = DatePicker(
            "Start time",
            selection: windowStartBinding,
            in: dayStart...max(dayStart, end.addingTimeInterval(-60)),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        let endPicker = DatePicker(
            "End time",
            selection: windowEndBinding,
            in: min(start.addingTimeInterval(60), lastMinute)...lastMinute,
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Between")
                    startPicker
                    endPicker
                }
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Between")
                    Spacer(minLength: Theme.Spacing.xs)
                    startPicker
                    Text("\u{2013}")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    endPicker
                }
            }
        }
        .datePickerStyle(.compact)
        .frame(minHeight: Theme.Metrics.minTouchTarget)
    }

    private var daysRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Days")
                Spacer(minLength: Theme.Spacing.xs)
                Text(reminders.daysDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            // This row's insets are narrower than the other rows' 16 pt so seven 44 pt chips fit on
            // an iPhone SE; the padding lines the label up with "How often" and "Between".
            .padding(.horizontal, Theme.Spacing.cardPadding - Theme.Spacing.s)
            DayChips(settings: reminders.settings, onToggle: toggle(weekday:))
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .listRowInsets(EdgeInsets(top: Theme.Spacing.s, leading: Theme.Spacing.s, bottom: Theme.Spacing.s, trailing: Theme.Spacing.s))
    }

    /// Label left and value right; stacked at accessibility text sizes.
    @ViewBuilder
    private func adaptiveRow<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                leading()
                trailing()
            }
        } else {
            HStack(spacing: Theme.Spacing.xs) {
                leading()
                Spacer(minLength: Theme.Spacing.xs)
                trailing()
            }
        }
    }

    // MARK: Quotes

    @ViewBuilder
    private func quotesSection(_ quotes: [Quote]) -> some View {
        if !library.hasLoaded, let error = library.lastError {
            Section {
                loadFailed(error)
                    .listRowBackground(Color.surface)
            }
            .listSectionMargins(.horizontal, Theme.Spacing.gutter)
        } else if !library.hasLoaded {
            Section {
                DelayedProgressView()
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget * 2)
                    .listRowBackground(Color.clear)
            }
        } else if quotes.isEmpty {
            Section {
                emptyState
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        } else {
            // In Shuffle the planner picks a random order each cycle, so the list shows no numbers and
            // can't be reordered (a drag would only restart the shuffle).
            let isInOrder = reminders.settings.order == .inOrder
            Section {
                ForEach(Array(quotes.enumerated()), id: \.element.id) { offset, quote in
                    ReminderQuoteRow(
                        number: isInOrder ? offset + 1 : nil,
                        quote: quote,
                        onOpen: { router.showQuote(quote.id, in: quotes.map(\.id)) },
                        onRemove: { remove(quote) },
                        onMove: isInOrder ? { delta in move(quote, by: delta) } : nil
                    )
                    .listRowBackground(Color.surface)
                    .listRowSeparatorTint(Color.hairline)
                    // Accent, not red: this takes the quote out of reminders; red means delete.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Remove", systemImage: "bell.slash") {
                            remove(quote)
                        }
                        .tint(Color.accentColor)
                    }
                    .contextMenu {
                        Button("Remove from reminders", systemImage: "bell.slash") {
                            remove(quote)
                        }
                    }
                    .deleteDisabled(true)
                }
                .onMove(perform: isInOrder ? { source, destination in
                    library.moveReminders(fromOffsets: source, toOffset: destination)
                } : nil)
            } header: {
                quotesHeader(count: quotes.count)
            } footer: {
                if !isInOrder {
                    Text("Shown in random order. Choose In order to arrange them.")
                }
            }
            .listSectionMargins(.horizontal, Theme.Spacing.gutter)
        }
    }

    private func canReorder(_ quotes: [Quote]) -> Bool {
        library.hasLoaded && reminders.settings.order == .inOrder && quotes.count > 1
    }

    /// The first load failed (offline with no cache): say so, with Try again, instead of a spinner
    /// that never stops.
    private func loadFailed(_ error: any Error) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label {
                Text("Couldn\u{2019}t load your quotes")
                    .font(.headline)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            Text(error.friendlyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                retry()
            } label: {
                // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                ZStack {
                    Text("Try again").opacity(isRetrying ? 0 : 1)
                    if isRetrying {
                        ProgressView()
                    }
                }
                .capsuleButtonLabel()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(isRetrying)
            .accessibilityLabel(isRetrying ? "Loading" : "Try again")
            .padding(.top, Theme.Spacing.xxs)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            await library.refresh(userInitiated: true)
            isRetrying = false
        }
    }

    private func quotesHeader(count: Int) -> some View {
        @Bindable var reminders = reminders
        // `Color.secondary`, not `.secondary`: a list header already dims its content, and the
        // hierarchical style would dim it twice.
        let countText = Text(count == 1 ? "1 quote" : "\(count) quotes")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .accessibilityAddTraits(.isHeader)
        let picker = Picker("Order", selection: $reminders.settings.order) {
            Text("In order").tag(ReminderOrder.inOrder)
            Text("Shuffle").tag(ReminderOrder.shuffle)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Order")
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    countText
                    picker
                }
            } else {
                HStack(spacing: Theme.Spacing.m) {
                    countText
                    Spacer(minLength: 0)
                    picker
                        .fixedSize()
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, Theme.Spacing.xxs)
        .listRowInsets(EdgeInsets(top: Theme.Spacing.m, leading: 0, bottom: Theme.Spacing.xs, trailing: 0))
    }

    private var addQuotesSection: some View {
        Section {
            // Never disabled: with every Library quote already here, the picker offers the starter
            // pack and Write your own instead (the dead end testers hit after onboarding).
            Button {
                router.present(.reminderPicker)
            } label: {
                Label("Add quotes", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .listRowBackground(Color.surface)
        }
        .listSectionMargins(.horizontal, Theme.Spacing.gutter)
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.isEmpty {
            EmptyStateView(
                systemImage: "bell",
                title: "No quotes yet",
                message: "Save a quote and it can show up here, in notifications and in your widget.",
                actionTitle: "Add a quote",
                action: { router.present(.addQuote) }
            )
        } else {
            EmptyStateView(
                systemImage: "bell",
                title: "No quotes in your reminders",
                message: "Pick quotes from your library to see them through the day.",
                actionTitle: "Add quotes",
                action: { router.present(.reminderPicker) }
            )
        }
    }

    // MARK: Bindings

    /// On only while reminders go out. Turning it on also asks for notification permission when it
    /// was never asked, or opens Settings when it was denied (only Settings can change that).
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { reminders.isDelivering },
            set: { isOn in
                guard isOn else {
                    reminders.settings.enabled = false
                    return
                }
                reminders.settings.enabled = true
                switch reminders.permission {
                case .notDetermined:
                    Task { await reminders.requestAuthorization() }
                case .denied:
                    Task { await ReminderStore.openNotificationSettings() }
                case .authorized:
                    break
                }
            }
        )
    }

    private var timesPerDayBinding: Binding<Int> {
        Binding(
            get: { draft?.timesPerDay ?? reminders.settings.timesPerDay },
            set: { value in updateDraft { $0.timesPerDay = value } }
        )
    }

    private var windowStartBinding: Binding<Date> {
        Binding(
            get: { draft?.windowStart ?? reminders.settings.windowStartTime },
            set: { value in updateDraft { $0.windowStart = value } }
        )
    }

    private var windowEndBinding: Binding<Date> {
        Binding(
            get: { draft?.windowEnd ?? reminders.settings.windowEndTime },
            set: { value in updateDraft { $0.windowEnd = value } }
        )
    }

    // MARK: Actions

    private func updateDraft(_ change: (inout ScheduleDraft) -> Void) {
        var next = draft ?? ScheduleDraft(reminders.settings)
        change(&next)
        draft = next
    }

    /// Saves the debounced values (the store sanitizes them and replans).
    private func commitDraft() {
        guard let draft else { return }
        var settings = reminders.settings
        settings.timesPerDay = draft.timesPerDay
        let start = ReminderSettings.minutes(of: draft.windowStart)
        let end = ReminderSettings.minutes(of: draft.windowEnd)
        // The pickers keep start before end; if a value still crosses, keep the one just edited.
        settings.windowStart = min(start, end - 1)
        settings.windowEnd = max(end, start + 1)
        self.draft = nil
        reminders.settings = settings
    }

    /// Turns a day on or off. At least one day stays on.
    private func toggle(weekday: Int) {
        var settings = reminders.settings
        if settings.isEnabled(weekday: weekday), settings.weekdays.count <= 1 {
            Haptics.warning()
            toasts.show("Keep at least one day on")
            return
        }
        settings.toggle(weekday: weekday)
        Haptics.selection()
        reminders.settings = settings
    }

    /// Swipe (or the VoiceOver action) to take a quote out of reminders, with Undo (back in its place).
    private func remove(_ quote: Quote) {
        ReminderMembership.remove(quote, library: library, toasts: toasts)
    }

    /// The VoiceOver "Move up" / "Move down" actions.
    private func move(_ quote: Quote, by delta: Int) {
        var ids = library.reminderQuotes.map(\.id)
        guard let index = ids.firstIndex(of: quote.id) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        let library = self.library
        Task { await library.reorderReminders(ids) }
    }
}

// MARK: - Draft

/// The stepper and time-picker values waiting for the debounce.
private struct ScheduleDraft: Equatable {
    var timesPerDay: Int
    var windowStart: Date
    var windowEnd: Date

    init(_ settings: ReminderSettings) {
        timesPerDay = settings.timesPerDay
        windowStart = settings.windowStartTime
        windowEnd = settings.windowEndTime
    }
}

// MARK: - Permission banner

/// "Notifications are off for Quoted · Open Settings" (denied), or "Allow" when never asked.
private struct PermissionBanner: View {
    enum Kind {
        case denied
        case notAsked

        init?(permission: NotificationPermission, enabled: Bool) {
            switch permission {
            case .denied: self = .denied
            case .notDetermined where enabled: self = .notAsked
            default: return nil
            }
        }
    }

    let kind: Kind

    @Environment(ReminderStore.self) private var reminders
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let tileLayout = IconTile.layout(for: dynamicTypeSize, alignment: .top)
        tileLayout {
            IconTile(systemName: "bell.slash.fill", tone: .muted)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Button {
                    Task { await act() }
                } label: {
                    // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                    Text(actionTitle)
                        .fontWeight(.semibold)
                        .capsuleButtonLabel()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private var title: String {
        switch kind {
        case .denied: "Notifications are off for Quoted"
        case .notAsked: "Notifications aren\u{2019}t allowed yet"
        }
    }

    private var detail: String {
        switch kind {
        case .denied: "Turn them on in Settings to get your reminders. Your widget keeps working."
        case .notAsked: "Allow notifications to see your quotes through the day."
        }
    }

    private var actionTitle: String {
        switch kind {
        case .denied: "Open Settings"
        case .notAsked: "Allow"
        }
    }

    private func act() async {
        switch kind {
        case .denied: await ReminderStore.openNotificationSettings()
        case .notAsked: await reminders.requestAuthorization()
        }
    }
}

// MARK: - Day chips

/// Seven day chips in the calendar's order. On: a solid accent circle with an `OnAccent` letter.
/// Off: an outlined circle with an ink letter. Each is at least 44 pt; VoiceOver reads "Monday, on".
private struct DayChips: View {
    let settings: ReminderSettings
    let onToggle: (Int) -> Void

    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = Theme.Metrics.minTouchTarget

    private var chipSize: CGFloat { min(max(scaledSize, Theme.Metrics.minTouchTarget), 72) }
    private var options: [WeekdayOption] { ReminderStore.weekdayOptions() }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(options) { option in
                    chip(option)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: chipSize), spacing: Theme.Spacing.xs)], alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(options) { option in
                    chip(option)
                }
            }
        }
    }

    private func chip(_ option: WeekdayOption) -> some View {
        let isOn = settings.isEnabled(weekday: option.weekday)
        return Button {
            onToggle(option.weekday)
        } label: {
            Text(option.letter)
                .font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(isOn ? Color.onAccent : Color.primary)
                .frame(width: chipSize, height: chipSize)
                .background {
                    if isOn {
                        Circle().fill(Color.accentColor)
                    } else {
                        Circle().strokeBorder(.secondary, lineWidth: 1.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityHint(isOn ? "Turns reminders off on this day" : "Turns reminders on on this day")
    }
}

// MARK: - Quote row

/// One reminder quote: its number (In order only), a one-line serif excerpt and the author in small caps.
private struct ReminderQuoteRow: View {
    /// The position in the delivery order; nil in Shuffle, where there is no fixed order.
    let number: Int?
    let quote: Quote
    let onOpen: () -> Void
    let onRemove: () -> Void
    /// Moves the quote by -1 / +1 (the VoiceOver Move up / Move down actions); nil when the list
    /// can't be reordered.
    let onMove: ((Int) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                if let number {
                    Text(number, format: .number)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Theme.Spacing.l, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    // One line each normally; at accessibility sizes a single line holds only a word,
                    // so give the excerpt three lines and the author two.
                    QuoteText(quote, style: .excerpt, lineLimit: dynamicTypeSize.isAccessibilitySize ? 3 : nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let author = quote.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                        AttributionStyle.author(author)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the quote")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            Button("Remove from reminders", action: onRemove)
            if let onMove {
                Button("Move up") { onMove(-1) }
                Button("Move down") { onMove(1) }
            }
        }
    }

    private var accessibilityText: String {
        var text = number.map { "\($0). " } ?? ""
        text += quote.body
        if let author = quote.author, !author.isEmpty {
            text += ", \(author)"
        }
        return text
    }
}

// MARK: - Previews

#Preview("Reminders") {
    NavigationStack { RemindersView() }
        .previewEnvironment()
}

#Preview("Reminders · denied") {
    let model = AppModel.preview()
    model.reminders.seedPreview(permission: .denied)
    return NavigationStack { RemindersView() }
        .previewEnvironment(model)
}

#Preview("Reminders · empty") {
    NavigationStack { RemindersView() }
        .previewEnvironment(.preview(emptyLibrary: true))
}
