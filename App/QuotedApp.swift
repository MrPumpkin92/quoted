import OSLog
import QuotedCore
import QuotedKit
import Security
import SwiftUI

/// The app entry point. Builds the backend from Info.plist (a misconfigured build shows
/// `ConfigurationErrorView` instead of crashing), clears a session left in the Keychain by an earlier
/// install, empties the HTTP cache, creates `AppModel`, installs the notification delegate before
/// launch finishes, and registers the background refresh task.
@main
struct QuotedApp: App {
    @State private var launch: Launch

    init() {
        let launch = Launch.make()
        if case .ready(let model) = launch {
            model.installNotificationDelegate()
        }
        _launch = State(initialValue: launch)
    }

    var body: some Scene {
        let model = launch.model
        WindowGroup {
            switch launch {
            case .ready(let model):
                RootView()
                    .appEnvironment(model)
            case .misconfigured(let message):
                ConfigurationErrorView(message: message)
            #if DEBUG
            case .gallery(let model):
                ComponentGallery()
                    .toastHost()
                    .appEnvironment(model)
            #endif
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await model?.performBackgroundRefresh()
        }
    }
}

/// The result of building the app at launch.
private enum Launch {
    case ready(AppModel)
    case misconfigured(String)
    #if DEBUG
    /// `-QuotedGallery`: the design-system gallery with preview data.
    case gallery(AppModel)
    #endif

    var model: AppModel? {
        if case .ready(let model) = self { return model }
        return nil
    }

    @MainActor
    static func make() -> Launch {
        #if DEBUG
        // `-QuotedDemo`: boot straight into the seeded preview data (no backend, notifications or
        // widgets), for screenshots of feature screens: `xcrun simctl launch <udid> com.hwei.quoted -QuotedDemo`.
        if ProcessInfo.processInfo.arguments.contains("-QuotedDemo") {
            return .ready(AppModel.preview())
        }
        if ProcessInfo.processInfo.arguments.contains("-QuotedGallery") {
            return .gallery(AppModel.preview())
        }
        // `-UITestReset`: start with no session or local state (UI tests against the local stack).
        if ProcessInfo.processInfo.arguments.contains("-UITestReset") {
            UITestReset.wipeLocalState()
        }
        #endif
        do {
            let backend = try Backend.fromBundle()
            // Before anything reads the session (`SessionStore.start()` runs on RootView's appear).
            InstallMarker.clearSessionLeftByEarlierInstall(backend)
            // Builds before the backend's no-cache URL session wrote tokens and library responses to
            // `URLCache.shared`; empty it on every launch.
            Backend.purgeHTTPCaches()
            return .ready(AppModel(backend: backend))
        } catch {
            let message = error.errorDescription ?? String(describing: error)
            Logger.app.fault("Backend configuration failed: \(message, privacy: .public)")
            return .misconfigured(message)
        }
    }
}

/// Detects the first launch after an install. Keychain items outlive the app, so without this a
/// reinstall (or the next owner of a device the app was deleted from) would open signed in as the
/// previous user. The marker lives in `UserDefaults.standard`, which iOS deletes with the app; the App
/// Group suite is not used because it can outlive the app's own container.
enum InstallMarker {
    static let key = "quoted.installMarker"

    /// On the first launch after an install, removes any stored session (no network) and sets the
    /// marker. The marker is set even if the Keychain refuses, so a later launch never signs out a
    /// user who signed in after this one.
    @MainActor
    static func clearSessionLeftByEarlierInstall(_ backend: Backend, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        if backend.auth.clearLocalSession() {
            Logger.app.info("First launch after install: cleared any stored session")
        } else {
            Logger.app.error("First launch after install: a stored session could not be removed")
        }
        defaults.set(true, forKey: key)
    }
}

#if DEBUG
/// A local email account for UI tests and `scripts/sign-in-local-demo.sh`, now that there is no
/// sign-in screen. With `QUOTED_DEBUG_SIGNIN_EMAIL` and `QUOTED_DEBUG_SIGNIN_PASSWORD` in the launch
/// environment, a launch with no stored session signs in to that account instead of creating an
/// anonymous one (`SessionStore`); a stored session wins. Only against the local stack (`127.0.0.1` or
/// `localhost`), and only in DEBUG builds.
enum DebugSignIn {
    struct Credentials: Sendable {
        let email: String
        let password: String
    }

    static let emailKey = "QUOTED_DEBUG_SIGNIN_EMAIL"
    static let passwordKey = "QUOTED_DEBUG_SIGNIN_PASSWORD"

    static func credentials(
        for config: SupabaseConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Credentials? {
        guard let email = environment[emailKey], !email.isEmpty,
              let password = environment[passwordKey], !password.isEmpty
        else { return nil }
        guard let host = config.url.host(), host == "127.0.0.1" || host == "localhost" else {
            Logger.app.error("DEBUG sign-in ignored: the backend is not the local stack")
            return nil
        }
        return Credentials(email: email, password: password)
    }
}

/// `-UITestReset` support: wipes everything a previous run left on the device before the backend is
/// built, so a UI test always starts with no session: on Choose a username with a new anonymous
/// account (or signed in through `DebugSignIn`). DEBUG builds only.
enum UITestReset {
    /// The Keychain service supabase-swift's `KeychainLocalStorage` stores the session under.
    private static let authKeychainService = "supabase.gotrue.swift"
    /// Every key the app writes to `UserDefaults` starts with this.
    private static let defaultsKeyPrefix = "quoted."

    static func wipeLocalState() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: authKeychainService,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Logger.app.error("UI test reset: Keychain delete failed (\(status, privacy: .public))")
        }
        AppGroupStore()?.wipeAll()
        for defaults in [UserDefaults(suiteName: AppGroup.identifier), UserDefaults.standard].compactMap({ $0 }) {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(defaultsKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        Logger.app.info("UI test reset: cleared the session, App Group and preferences")
    }
}
#endif
