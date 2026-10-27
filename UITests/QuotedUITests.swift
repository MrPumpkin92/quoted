// The happy-path smoke flow against the LOCAL Supabase stack (scheme "Quoted Local", Debug-Local).
// Besides onboarding, Add, detail, share sheet, Reminders, Search, Friends and Account, it checks that
// Undo puts a quote back in its reminder place (after "Remove from reminders" and after Delete, also
// on the server) and that "Search the web" opens the Safari app. The seeded-account flow below adds
// the inbox (save, delete + Undo), a friend request, and deep links that must not discard a draft.
//
// The app has no sign-in screen. Every test launches it with `-UITestReset`, which clears any
// session, App Group data and preferences a previous run left behind, so the happy path starts on
// Welcome; Get started creates a new anonymous account and opens "Choose a username". Run
// `supabase start` first, with
// `enable_anonymous_sign_ins = true` in supabase/config.toml (scripts/test.sh checks it).
//
// The seeded-account tests sign in to an email account through the app's DEBUG sign-in hook: they put
// QUOTED_DEBUG_SIGNIN_EMAIL and QUOTED_DEBUG_SIGNIN_PASSWORD in the launch environment, and with no
// stored session the app signs in with them instead of creating an anonymous account (DEBUG builds
// against 127.0.0.1 or localhost only).
//
// The happy path reads its quotes back from the server with the local secret key, which bypasses
// RLS. It uses TEST_RUNNER_QUOTED_LOCAL_SUPABASE_URL (default http://127.0.0.1:54321, the URL
// Config/Local.xcconfig builds in; it must be the stack the app talks to) and
// TEST_RUNNER_QUOTED_LOCAL_SECRET_KEY (no default: scripts/test.sh passes it), and refuses any
// host but 127.0.0.1 or localhost.
//
// Notification priming only shows while the permission is undecided, so uninstall the app first
// (`xcrun simctl uninstall <udid> com.hwei.quoted`) for the full flow; with the permission already
// decided the test skips the priming step and carries on.
//
// Every screen gets a screenshot attachment (kept on success). Export them with:
//   xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path build/screens
//
// Each happy-path run leaves an anonymous account with the username `ui<time>`; delete them afterwards
// with scripts/clean-local-test-users.sh (local stack only).

import Synchronization
import XCTest

final class QuotedUITests: XCTestCase {
    /// The local stack the Debug-Local build talks to (Config/Local.xcconfig), unless
    /// TEST_RUNNER_QUOTED_LOCAL_SUPABASE_URL names another one.
    private static let defaultSupabaseURL = "http://127.0.0.1:54321"

    private static let emersonBody = "Trust thyself: every heart vibrates to that iron string."
    private static let emersonAuthor = "Ralph Waldo Emerson"
    /// The start of the quote scripts/seed-local-friend.sh shares by default (Jane Austen).
    private static let seededShareStart = "There is a stubbornness about me"

    /// Thrown after a failed wait (already recorded) to end the test.
    private struct StepFailed: Error {}

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testHappyPath() {
        // Failures are recorded where they happen; StepFailed only ends the flow.
        do {
            try runHappyPath()
        } catch is StepFailed {
            return
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func runHappyPath() throws {
        // Checked first, so a bad URL or key fails before the long UI flow.
        let server: LocalServer
        do {
            server = try LocalServer.fromEnvironment()
        } catch {
            XCTFail("\(error)")
            throw StepFailed()
        }
        let stamp = String(Int(Date().timeIntervalSince1970) % 100_000_000)
        let username = "ui\(stamp)"

        let app = XCUIApplication()
        app.launchArguments += ["-UITestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // 1. No sign-in: Welcome, with one Get started button and the Terms consent line. Get started
        // creates an anonymous account (allow for the sign-in call) and opens Choose a username.
        let getStarted = app.buttons["Get started"]
        try waitFor(getStarted, timeout: 20)
        XCTAssertTrue(element(in: app, labelContaining: "By continuing you agree").exists, "Welcome should show the consent line")
        snapshot("00-welcome")
        getStarted.tap()
        try waitFor(app.staticTexts["Choose a username"], timeout: 20)
        let usernameField = field(app.textFields, label: "Username", placeholder: "yourname")
        try waitFor(usernameField)
        snapshot("01-new-account-username")
        XCTAssertFalse(
            field(app.textFields, label: "Email", placeholder: "name@example.com").exists,
            "A new anonymous account should show no Email field"
        )
        let accountButtons = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "Create account", "Sign in", "Sign out"
        ))
        XCTAssertEqual(accountButtons.count, 0, "A new anonymous account should show no Create account, Sign in or Sign out")

        // 2. Username.
        usernameField.tap()
        usernameField.typeText(username)
        try waitFor(app.images["Available"], timeout: 15)
        let displayName = field(app.textFields, label: "Display name", placeholder: "Optional")
        displayName.tap()
        displayName.typeText("Alex Tester")
        snapshot("02-username-filled")
        app.buttons["Continue"].tap()

        // 3. Starter pack: pick the first three quotes.
        try waitFor(app.navigationBars["Pick a few to start"], timeout: 20)
        let starterRows = app.collectionViews.firstMatch.buttons
        try waitFor(starterRows.element(boundBy: 2), timeout: 20)
        for index in 0..<3 {
            starterRows.element(boundBy: index).tap()
        }
        let continueButton = app.buttons["Continue with 3 quotes"]
        try waitFor(continueButton)
        snapshot("04-starter-picked")
        continueButton.tap()

        // 4. Notification priming → Allow → the system alert.
        let allow = app.buttons["Allow notifications"]
        if allow.waitForExistence(timeout: 15) {
            snapshot("05-priming")
            allow.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let systemAllow = springboard.alerts.buttons["Allow"]
            if systemAllow.waitForExistence(timeout: 10) {
                snapshot("06-system-alert")
                systemAllow.tap()
            }
        } else {
            XCTContext.runActivity(named: "Notification permission already decided; priming skipped") { _ in }
        }

        // 5. Library: three quotes and the reminders status card.
        try waitFor(app.navigationBars["Library"], timeout: 20)
        try waitFor(element(in: app, labelContaining: "3 quotes in your reminders"), timeout: 15)
        try waitFor(app.staticTexts["3 quotes"])
        snapshot("07-library")

        // 6. Add a quote, with "Trust thyself" in bold from the B button. The "+" is a menu.
        try openNewQuote(in: app)
        let editor = app.textViews["Quote"]
        try waitFor(editor)
        try waitFor(app.navigationBars["New quote"])
        if !app.buttons["Bold"].waitForExistence(timeout: 3) {
            editor.tap()
        }
        let bold = app.buttons["Bold"]
        try waitFor(bold)
        bold.tap()
        editor.typeText("Trust thyself")
        bold.tap()
        editor.typeText(": every heart vibrates to that iron string.")
        let author = field(app.textFields, label: "Author", placeholder: "Name")
        author.tap()
        author.typeText(Self.emersonAuthor)
        snapshot("08-add-quote")
        app.navigationBars["New quote"].buttons["Save"].tap()

        // 7. It appears in the library. Wait for the sheet to close first: its editor also contains
        // "Trust thyself", and a slow save keeps the sheet up with a spinner.
        XCTAssertTrue(app.navigationBars["New quote"].waitForNonExistence(timeout: 30), "The Add sheet should close after saving")
        let newRow = element(in: app, labelContaining: "Trust thyself")
        try waitFor(newRow, timeout: 20)
        try waitFor(app.staticTexts["4 quotes"])
        snapshot("09-library-with-new-quote")

        // 8. Its detail screen, then back.
        newRow.tap()
        try waitFor(app.navigationBars["Quote"])
        try waitFor(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "In reminders")).firstMatch)
        snapshot("10-quote-detail")
        // The share sheet: no friends yet, so it offers Friends, then the image and text options.
        app.buttons["Share"].firstMatch.tap()
        try waitFor(app.navigationBars["Share quote"])
        try waitFor(element(in: app, labelContaining: "Share as text"))
        snapshot("10b-share-sheet")
        app.navigationBars["Share quote"].buttons["Cancel"].tap()
        try waitFor(app.navigationBars["Quote"])
        tapBack(in: app, from: "Quote")
        try waitFor(app.navigationBars["Library"])

        // 8b. Undo puts a quote taken out of reminders back in its old place (#2), not at the end.
        // Reminder order: 1 Trust thyself (starter), 2 Hope, 3 Beware, 4 Trust thyself (typed).
        element(in: app, labelContaining: "Hope is the thing").press(forDuration: 1.2)
        let removeFromReminders = app.buttons["Remove from reminders"]
        try waitFor(removeFromReminders)
        removeFromReminders.tap()
        try waitFor(element(in: app, labelContaining: "3 quotes in your reminders"))
        try tapUndo(in: app, toast: "Removed from reminders", snapshotName: "09b-removed-from-reminders-toast")
        try waitFor(element(in: app, labelContaining: "4 quotes in your reminders"))

        // 8c. Delete commits at once; Undo restores the same quote with its reminder place (#3).
        element(in: app, labelContaining: "Beware; for I am fearless").press(forDuration: 1.2)
        let deleteButton = app.buttons["Delete"]
        try waitFor(deleteButton)
        deleteButton.tap()
        try waitFor(app.staticTexts["3 quotes"])
        try tapUndo(in: app, toast: "Quote deleted", snapshotName: "09c-quote-deleted-toast")
        try waitFor(app.staticTexts["4 quotes"])
        snapshot("09d-library-after-undo")

        // 9. Reminders: the order survived both Undos; then two a day instead of three.
        element(in: app, labelContaining: "quotes in your reminders").tap()
        try waitFor(app.navigationBars["Reminders"])
        try waitFor(element(in: app, labelContaining: "3\u{00D7} a day"))
        try waitFor(reminderRow(in: app, number: 2, startingWith: "Hope is the thing"))
        try waitFor(reminderRow(in: app, number: 3, startingWith: "Beware; for I am fearless"))
        snapshot("11-reminders")
        let stepper = app.steppers.firstMatch
        try waitFor(stepper)
        stepper.buttons.element(boundBy: 0).tap()
        try waitFor(element(in: app, labelContaining: "2\u{00D7} a day"))
        snapshot("12-reminders-2x")
        tapBack(in: app, from: "Reminders")
        try waitFor(app.navigationBars["Library"])
        try waitFor(element(in: app, labelContaining: "2\u{00D7} daily"))

        // 10. Search: "courage" lists the web row last.
        app.tabBars.buttons["Search"].tap()
        let searchField = app.searchFields.firstMatch
        try waitFor(searchField)
        snapshot("13-search-empty")
        searchField.tap()
        searchField.typeText("courage")
        try waitFor(element(in: app, labelContaining: "Search the web for \u{201C}courage\u{201D} quotes"))
        snapshot("14-search-courage")
        // The keyboard's Search key remembers the term; closing the search brings the tab bar back.
        searchField.typeText("\n")
        let friendsTab = app.tabBars.buttons["Friends"]
        if !friendsTab.waitForExistence(timeout: 2) {
            for label in ["Close", "Cancel"] where app.buttons[label].exists {
                app.buttons[label].firstMatch.tap()
                break
            }
        }
        try waitFor(element(in: app, labelContaining: "courage"))
        snapshot("14b-search-recent")

        // 11. Friends, then Account. While Search is selected, iOS 26 folds the other tabs into one
        // button (the last tab, Library); it expands them again.
        if !friendsTab.waitForExistence(timeout: 2) {
            let folded = app.tabBars.buttons["Library"].exists ? app.tabBars.buttons["Library"] : app.tabBars.buttons.firstMatch
            folded.tap()
        }
        try waitFor(friendsTab)
        friendsTab.tap()
        try waitFor(app.navigationBars["Friends"])
        snapshot("15-friends")
        element(in: app, labelContaining: "Account and settings").tap()
        try waitFor(app.navigationBars["Account"])
        try waitFor(element(in: app, labelContaining: "@\(username)"))
        snapshot("16-account")
        // The bottom of Account: Delete account and the anonymous-account footer, and no Sign out.
        app.swipeUp()
        try waitFor(element(in: app, labelContaining: "Your account belongs to this iPhone"))
        try waitFor(app.buttons["Delete account"])
        XCTAssertFalse(app.buttons["Sign out"].exists, "An anonymous account should have no Sign out")
        snapshot("16b-account-bottom")

        // The server kept the bold run: "Trust thyself" is UTF-16 0..<13. Both Undos reached the
        // server too: four quotes, with Hope back at reminder position 1 and Beware (deleted, then
        // restored) at 2.
        let saved: [SavedQuote]
        do {
            saved = try fetchQuotesWaiting(username: username, server: server)
        } catch {
            XCTFail("Couldn't read the quotes back from the local stack: \(error)")
            return
        }
        let typed = saved.first { $0.author == Self.emersonAuthor && $0.origin == "manual" }
        XCTAssertEqual(typed?.body, Self.emersonBody)
        XCTAssertTrue(
            typed?.format.contains { $0.start == 0 && $0.length == 13 && $0.bold == true } == true,
            "Expected a bold run over \u{201C}Trust thyself\u{201D}, got \(String(describing: typed?.format))"
        )
        XCTAssertEqual(saved.count, 4, "Expected the deleted quote to be restored on the server")
        XCTAssertEqual(saved.first { $0.body.hasPrefix("Hope is the thing") }?.rotationPosition, 1)
        XCTAssertEqual(saved.first { $0.body.hasPrefix("Beware; for I am fearless") }?.rotationPosition, 2)

        // 12. "Search the web" opens Google in the in-app browser, and Close returns to Search.
        app.tabBars.buttons["Search"].tap()
        try waitFor(searchField)
        searchField.tap()
        searchField.typeText("kindness")
        let webRow = element(in: app, labelContaining: "Search the web for \u{201C}kindness\u{201D} quotes")
        try waitFor(webRow)
        webRow.tap()
        XCTAssertEqual(app.state, .runningForeground, "The web row should keep Quoted in front")
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), "The in-app browser should show its Close button")
        snapshot("17-in-app-browser")
        close.tap()
        XCTAssertTrue(webRow.waitForExistence(timeout: 10), "Closing the browser should return to Search")
    }

    /// Friends, the shared inbox and deep links on an account seeded by scripts/seed-local-friend.sh.
    /// Skipped unless the runner gets the account (xcodebuild passes `TEST_RUNNER_`-prefixed variables):
    ///
    ///     TEST_RUNNER_QUOTED_QA_EMAIL=... TEST_RUNNER_QUOTED_QA_PASSWORD=... \
    ///     TEST_RUNNER_QUOTED_QA_QUOTE_ID=<a quote in reminders> xcodebuild test ... \
    ///       -only-testing:QuotedUITests/QuotedUITests/testFriendsInboxAndDeepLinks
    ///
    /// The app signs in to the account through its DEBUG sign-in hook (`launchSignedIn`).
    /// Expects one unseen share (seeded with `--accept`) and one incoming request (`--no-share`).
    /// With `TEST_RUNNER_QUOTED_QA_DELETE=1` it ends by deleting the account from Account, after which
    /// the app returns to Welcome.
    @MainActor
    func testFriendsInboxAndDeepLinks() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["QUOTED_QA_EMAIL"], let password = environment["QUOTED_QA_PASSWORD"] else {
            throw XCTSkip("Set TEST_RUNNER_QUOTED_QA_EMAIL and TEST_RUNNER_QUOTED_QA_PASSWORD to run the seeded-account QA flow.")
        }
        do {
            try runFriendsInboxAndDeepLinks(email: email, password: password, quoteID: environment["QUOTED_QA_QUOTE_ID"])
        } catch is StepFailed {
            return
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Signs the simulator into an existing LOCAL account and stops, so the app is ready for manual QA
    /// (the session stays in the simulator's keychain, and later launches use it). Skipped unless the
    /// runner gets the account; `scripts/sign-in-local-demo.sh` passes the demo account from
    /// build/demo-account.txt. The app signs in through its DEBUG sign-in hook (`launchSignedIn`).
    @MainActor
    func testSignInForManualQA() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["QUOTED_SIGNIN_EMAIL"], let password = environment["QUOTED_SIGNIN_PASSWORD"] else {
            throw XCTSkip("Set TEST_RUNNER_QUOTED_SIGNIN_EMAIL and TEST_RUNNER_QUOTED_SIGNIN_PASSWORD to sign in for manual QA.")
        }
        _ = try launchSignedIn(email: email, password: password)
        snapshot("manual-qa-signed-in")
    }

    @MainActor
    private func runFriendsInboxAndDeepLinks(email: String, password: String, quoteID: String?) throws {
        // Library: the unseen share shows as "1 shared with you".
        let app = try launchSignedIn(email: email, password: password)
        let sharedRow = element(in: app, labelContaining: "shared with you")
        try waitFor(sharedRow, timeout: 15)
        snapshot("qa-01-library-shared-row")

        // The inbox: save the shared quote.
        sharedRow.tap()
        try waitFor(app.navigationBars["Shared with you"])
        snapshot("qa-02-inbox")
        let save = app.buttons["Save to your library"].firstMatch
        try waitFor(save)
        save.tap()
        try waitFor(element(in: app, labelContaining: "Saved to your library"))
        snapshot("qa-03-inbox-saved")

        // Swipe to delete the share, then Undo: the card comes back.
        let card = element(in: app, labelContaining: Self.seededShareStart)
        try waitFor(card)
        card.swipeLeft()
        let swipeDelete = app.buttons["Delete"]
        if swipeDelete.waitForExistence(timeout: 2) {
            swipeDelete.tap()
        }
        try tapUndo(in: app, toast: "Deleted the quote from", snapshotName: "qa-03b-inbox-delete-toast")
        try waitFor(element(in: app, labelContaining: Self.seededShareStart))
        snapshot("qa-03c-inbox-after-undo")
        tapBack(in: app, from: "Shared with you")
        try waitFor(app.navigationBars["Library"])

        // Friends: accept the incoming request.
        app.tabBars.buttons["Friends"].tap()
        try waitFor(app.navigationBars["Friends"])
        let accept = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Accept request from")).firstMatch
        try waitFor(accept, timeout: 15)
        snapshot("qa-04-friends-request")
        accept.tap()
        try waitFor(app.staticTexts["Friends"])
        XCTAssertTrue(accept.waitForNonExistence(timeout: 10), "The request should leave Requests once accepted")
        snapshot("qa-05-friends-accepted")

        // Deep links are opened through the system (like a notification or widget tap);
        // `app.open(_:)` would relaunch with `-UITestReset` and start over with a new session.
        // A link never discards a draft: with text typed in Add it waits until the sheet closes.
        app.tabBars.buttons["Library"].tap()
        try waitFor(app.navigationBars["Library"])
        try openNewQuote(in: app)
        let editor = app.textViews["Quote"]
        try waitFor(editor)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            editor.tap()
        }
        editor.typeText("A draft the link must keep")
        if let url = URL(string: "quoted://rotation") {
            XCUIDevice.shared.system.open(url)
            confirmOpenInApp()
        }
        XCTAssertFalse(app.navigationBars["Reminders"].waitForExistence(timeout: 3), "The link must wait for the Add sheet")
        try waitFor(app.navigationBars["New quote"])
        XCTAssertTrue((editor.value as? String)?.contains("A draft the link must keep") == true, "The draft must survive the link")
        snapshot("qa-05b-deeplink-kept-draft")
        app.navigationBars["New quote"].buttons["Cancel"].tap()
        let discard = app.buttons["Discard"]
        try waitFor(discard)
        discard.tap()
        try waitFor(app.navigationBars["Reminders"], timeout: 15)
        snapshot("qa-05c-deeplink-after-discard")

        // A quote opens full screen (QuoteSpotlightView); Open in Library shows its detail. Then Reminders.
        if let quoteID, let url = URL(string: "quoted://quote/\(quoteID)") {
            XCUIDevice.shared.system.open(url)
            confirmOpenInApp()
            let openInLibrary = app.buttons["Open in Library"]
            try waitFor(openInLibrary, timeout: 15)
            snapshot("qa-06-deeplink-quote")
            openInLibrary.tap()
            try waitFor(app.navigationBars["Quote"], timeout: 15)
            snapshot("qa-06b-deeplink-quote-detail")
        }
        if let url = URL(string: "quoted://rotation") {
            XCUIDevice.shared.system.open(url)
            confirmOpenInApp()
            try waitFor(app.navigationBars["Reminders"], timeout: 15)
            snapshot("qa-07-deeplink-reminders")
        }

        // Optionally delete the account from Account (TEST_RUNNER_QUOTED_QA_DELETE=1).
        guard ProcessInfo.processInfo.environment["QUOTED_QA_DELETE"] == "1" else { return }
        app.tabBars.buttons["Friends"].tap()
        try waitFor(app.navigationBars["Friends"])
        element(in: app, labelContaining: "Account and settings").tap()
        try waitFor(app.navigationBars["Account"])
        app.swipeUp()
        let delete = app.buttons["Delete account"]
        try waitFor(delete)
        snapshot("qa-08-account-bottom")
        delete.tap()
        let confirm = app.alerts.buttons["Delete Account"]
        try waitFor(confirm)
        snapshot("qa-09-delete-confirm")
        confirm.tap()
        // Back to Welcome; Get started would create a new, empty account.
        try waitFor(app.buttons["Get started"], timeout: 30)
        snapshot("qa-10-deleted-welcome")
    }

    /// Launches the app with no stored session (`-UITestReset`) and the local email account in the
    /// launch environment. The app has no sign-in screen; its DEBUG sign-in hook signs in with these
    /// instead of creating an anonymous account. Waits for Library (allowing for the sign-in call). A
    /// failed sign-in stays on the launch screen with the error and Try again.
    @MainActor
    private func launchSignedIn(email: String, password: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["QUOTED_DEBUG_SIGNIN_EMAIL"] = email
        app.launchEnvironment["QUOTED_DEBUG_SIGNIN_PASSWORD"] = password
        app.launch()
        try waitFor(app.navigationBars["Library"], timeout: 30)
        return app
    }

    /// iOS may ask "Open in “Quoted”?" before handing a URL to the app.
    @MainActor
    private func confirmOpenInApp() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) {
            open.tap()
        }
    }

    // MARK: Helpers

    /// A full-screen screenshot attachment (it includes system alerts), kept even when the test passes.
    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Library's "+" opens a menu (New Quote / From the Starter Pack); this picks New Quote.
    @MainActor
    private func openNewQuote(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        app.buttons["library.add"].tap()
        let newQuote = app.buttons["New Quote"]
        try waitFor(newQuote, file: file, line: line)
        newQuote.tap()
    }

    /// Waits for `element`; when it never appears, attaches a screenshot and the element tree, fails
    /// and ends the test.
    @MainActor
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) throws {
        guard !element.waitForExistence(timeout: timeout) else { return }
        snapshot("failure-\(line)")
        let tree = XCTAttachment(string: XCUIApplication().debugDescription)
        tree.name = "failure-\(line)-tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail("Timed out waiting for \(element)", file: file, line: line)
        throw StepFailed()
    }

    /// The first element of any type whose label contains `text`.
    @MainActor
    private func element(in app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The Reminders row numbered `number` whose quote starts with `text`. The row reads "2. Hope is…"
    /// to VoiceOver ("Remove, 2. Hope is…" on its delete control); its cell reads "2, Hope is…".
    @MainActor
    private func reminderRow(in app: XCUIApplication, number: Int, startingWith text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            "\(number). \(text)", "Remove, \(number). \(text)", "\(number), \(text)"
        )).firstMatch
    }

    /// Waits for the Undo toast whose message starts with `toast` and taps its Undo button. For
    /// VoiceOver the toast is one button ("Quote deleted. Undo"); a plain tap lands where the visible
    /// Undo button is, at the trailing end. Then waits for the toast to close.
    @MainActor
    private func tapUndo(in app: XCUIApplication, toast: String, snapshotName: String) throws {
        let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", toast, "Undo")).firstMatch
        try waitFor(capsule)
        snapshot(snapshotName)
        capsule.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(capsule.waitForNonExistence(timeout: 5), "The \u{201C}\(toast)\u{201D} toast should close after Undo")
    }

    /// The text field labelled `label`, or showing `placeholder` (SwiftUI fields with a prompt may
    /// expose either).
    @MainActor
    private func field(_ query: XCUIElementQuery, label: String, placeholder: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@ OR identifier == %@", label, placeholder, label)).firstMatch
    }

    /// Taps the back button of the navigation bar titled `title`.
    @MainActor
    private func tapBack(in app: XCUIApplication, from title: String) {
        let bar = app.navigationBars[title]
        let back = bar.buttons["BackButton"]
        if back.exists {
            back.tap()
        } else {
            bar.buttons.element(boundBy: 0).tap()
        }
    }

    // MARK: Server check (local stack only)

    /// The local stack the tests read directly, with the secret key (it bypasses RLS):
    /// TEST_RUNNER_QUOTED_LOCAL_SUPABASE_URL (or the default URL) and TEST_RUNNER_QUOTED_LOCAL_SECRET_KEY.
    /// Refuses any host but 127.0.0.1 or localhost, so the secret key never goes anywhere else.
    private struct LocalServer: Sendable {
        let baseURL: String
        let secretKey: String

        static func fromEnvironment() throws -> LocalServer {
            let environment = ProcessInfo.processInfo.environment
            var url = environment["QUOTED_LOCAL_SUPABASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? QuotedUITests.defaultSupabaseURL
            while url.hasSuffix("/") { url.removeLast() }
            guard let components = URLComponents(string: url),
                  components.scheme == "http" || components.scheme == "https",
                  let host = components.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
                  components.path.isEmpty, components.query == nil
            else {
                throw ServerCheckFailed(reason: "Refusing TEST_RUNNER_QUOTED_LOCAL_SUPABASE_URL \u{201C}\(url)\u{201D}: the tests only talk to a local stack (http://127.0.0.1:<port> or http://localhost:<port>).")
            }
            guard let key = environment["QUOTED_LOCAL_SECRET_KEY"], key.hasPrefix("sb_secret_") else {
                throw ServerCheckFailed(reason: "Set TEST_RUNNER_QUOTED_LOCAL_SECRET_KEY to the local stack's sb_secret_ key (scripts/test.sh does).")
            }
            return LocalServer(baseURL: url, secretKey: key)
        }

        /// GET /rest/v1/<table> with `query`, decoded as rows.
        func rows<Row: Decodable & Sendable>(_ table: String, query: [URLQueryItem]) async throws -> [Row] {
            guard var components = URLComponents(string: "\(baseURL)/rest/v1/\(table)") else {
                throw ServerCheckFailed(reason: "Bad \(table) URL")
            }
            components.queryItems = query
            guard let url = components.url else { throw ServerCheckFailed(reason: "Bad \(table) query") }
            var request = URLRequest(url: url)
            request.setValue(secretKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw ServerCheckFailed(reason: "GET \(table) answered \(code): \(String(decoding: data, as: UTF8.self))")
            }
            return try JSONDecoder().decode([Row].self, from: data)
        }
    }

    /// Runs `fetchQuotes` and waits for it (the test itself stays synchronous).
    @MainActor
    private func fetchQuotesWaiting(username: String, server: LocalServer) throws -> [SavedQuote] {
        let done = expectation(description: "Read the quotes back from the local stack")
        let box = Mutex<Result<[SavedQuote], any Error>?>(nil)
        Task.detached {
            let result: Result<[SavedQuote], any Error>
            do {
                result = .success(try await Self.fetchQuotes(username: username, server: server))
            } catch {
                result = .failure(error)
            }
            box.withLock { $0 = result }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        guard let result = box.withLock({ $0 }) else { throw ServerCheckFailed(reason: "Timed out") }
        return try result.get()
    }

    private struct ServerCheckFailed: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    private struct SavedQuote: Decodable, Sendable {
        struct Run: Decodable, Sendable, CustomStringConvertible {
            let start: Int
            let length: Int
            let bold: Bool?
            var description: String { "{start: \(start), length: \(length), bold: \(bold ?? false)}" }
        }

        let body: String
        let format: [Run]
        let author: String?
        let origin: String
        let rotationPosition: Int?

        enum CodingKeys: String, CodingKey {
            case body
            case format = "body_format"
            case author
            case origin
            case rotationPosition = "rotation_position"
        }
    }

    /// Reads back every quote in the library of the account with `username`. The account is anonymous
    /// and has no password, so this finds it by its profile and reads with the secret key.
    private static func fetchQuotes(username: String, server: LocalServer) async throws -> [SavedQuote] {
        struct Profile: Decodable, Sendable {
            let id: String
        }

        let profiles: [Profile] = try await server.rows("profiles", query: [
            URLQueryItem(name: "username", value: "eq.\(username)"),
            URLQueryItem(name: "select", value: "id"),
        ])
        guard let profile = profiles.first else {
            throw ServerCheckFailed(reason: "No profile @\(username) on \(server.baseURL)")
        }
        return try await server.rows("quotes", query: [
            URLQueryItem(name: "owner_id", value: "eq.\(profile.id)"),
            URLQueryItem(name: "select", value: "body,body_format,author,origin,rotation_position"),
        ])
    }
}
