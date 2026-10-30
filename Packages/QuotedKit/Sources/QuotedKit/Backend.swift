import Foundation
import QuotedCore
import Supabase
import Synchronization

/// The app's connection to Supabase. Create one at launch and share it; it is `Sendable`.
///
/// It owns the `SupabaseClient` (PKCE auth with the `quoted://auth-callback` redirect, the session
/// in the Keychain, PostgREST rows decoded with ``QuotedJSON``) and exposes one service per area.
/// All traffic goes through a URL session with no response cache (see ``makeURLSessionConfiguration()``).
public final class Backend: Sendable {
    /// Where the session is kept between launches.
    public enum SessionPersistence: Sendable {
        /// The Keychain, this device only (no backup migration). Use this in the app.
        case keychain
        /// Memory only: the session ends with the process. For tests and previews.
        case inMemory
    }

    public let config: SupabaseConfig
    public let auth: AuthService
    /// Your library, and saving other people's quotes into it.
    public let quotes: QuotesRepository
    /// Your account, terms and other people's profiles and profile pages.
    public let profiles: ProfilesRepository
    /// Friends and blocks.
    public let social: SocialRepository
    /// Posts and the Feed.
    public let posts: PostsRepository
    /// Playlists, yours and the ones you can view.
    public let playlists: PlaylistsRepository
    /// Conversations, messages and the Inbox.
    public let messages: MessagesRepository
    /// Reports.
    public let reports: ReportsRepository
    /// The onboarding starters (`starter_quotes`).
    public let starter: StarterRepository
    /// The Quoted Catalog (`catalog_quotes`): the Verified Quotes list and the seal's sources.
    public let catalog: CatalogRepository
    public let events: EventsRepository
    public let account: AccountService

    let client: SupabaseClient

    /// Creates the backend for `config`.
    public convenience init(config: SupabaseConfig, sessionPersistence: SessionPersistence = .keychain) {
        let storage: any AuthLocalStorage = switch sessionPersistence {
        case .keychain: DeviceKeychainStorage()
        case .inMemory: InMemoryAuthStorage()
        }
        self.init(config: config, authStorage: storage)
    }

    /// Reads ``SupabaseConfig`` from the bundle's Info.plist and creates the backend.
    public static func fromBundle(
        _ bundle: Bundle = .main,
        sessionPersistence: SessionPersistence = .keychain
    ) throws(SupabaseConfigError) -> Backend {
        Backend(config: try SupabaseConfig.fromBundle(bundle), sessionPersistence: sessionPersistence)
    }

    /// Designated initializer. Tests inject a URL session and extra headers here.
    init(
        config: SupabaseConfig,
        authStorage: any AuthLocalStorage,
        urlSession: URLSession = Backend.makeURLSession(),
        headers: [String: String] = [:]
    ) {
        self.config = config
        let storageKey = Self.sessionStorageKey(for: config.url)
        let options = SupabaseClientOptions(
            db: .init(encoder: QuotedJSON.makeEncoder(), decoder: QuotedJSON.makeDecoder()),
            auth: .init(
                storage: authStorage,
                redirectToURL: DeepLink.authCallbackURL,
                // The SDK's default key, spelled out so `AuthService.clearLocalSession()` can find it.
                storageKey: storageKey,
                flowType: .pkce,
                autoRefreshToken: true,
                // Launch shows the cached library at once: emit the stored session immediately and
                // let the SDK refresh it in the background.
                emitLocalSessionAsInitialSession: true
            ),
            global: .init(headers: headers, session: urlSession)
        )
        let client = SupabaseClient(supabaseURL: config.url, supabaseKey: config.publishableKey, options: options)
        self.client = client
        auth = AuthService(client: client, storage: authStorage, storageKey: storageKey)
        quotes = QuotesRepository(client: client)
        let profiles = ProfilesRepository(client: client)
        self.profiles = profiles
        social = SocialRepository(client: client, profiles: profiles)
        posts = PostsRepository(client: client)
        playlists = PlaylistsRepository(client: client)
        messages = MessagesRepository(client: client)
        reports = ReportsRepository(client: client)
        starter = StarterRepository(client: client)
        catalog = CatalogRepository(client: client)
        events = EventsRepository(client: client)
        account = AccountService(client: client, auth: auth)
    }

    // MARK: HTTP caching

    /// The configuration of the backend's URL session: ephemeral, with no `URLCache`, no cookies and
    /// no credential store, and every request loaded from the network. Auth responses carry tokens
    /// and PostgREST responses carry the user's library, messages and friends, so none of it may land
    /// in `Library/Caches` (`URLSession.shared` would write it to `Cache.db`).
    ///
    /// Requests time out after ``requestTimeout`` without data and ``resourceTimeout`` in all, instead
    /// of URLSession's 60 s and 7 days: launch, Save and background refresh fail with a message and
    /// Try again rather than a spinner that lasts minutes (the SDK retries GETs up to three times).
    public static func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Seconds a request may wait for data before it fails.
    public static let requestTimeout: TimeInterval = 15
    /// Seconds a request may take in all.
    public static let resourceTimeout: TimeInterval = 45

    /// A URL session with ``makeURLSessionConfiguration()``.
    static func makeURLSession() -> URLSession {
        URLSession(configuration: makeURLSessionConfiguration())
    }

    /// Removes every response in `URLCache.shared` (memory and disk). The backend never caches, but
    /// builds before it used `URLSession.shared`, whose `Cache.db` may still hold tokens and library
    /// responses. Call it on sign-out, after deleting the account, and once at launch.
    public static func purgeHTTPCaches() {
        URLCache.shared.removeAllCachedResponses()
    }

    /// The Keychain account the SDK stores the session under by default: `sb-<first host label>-auth-token`
    /// (supabase-swift 2.55, `SupabaseClient.init`).
    static func sessionStorageKey(for url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        let label = host.split(separator: ".").first.map(String.init) ?? host
        return "sb-\(label)-auth-token"
    }
}

/// Shared helpers for the services.
extension SupabaseClient {
    /// The signed-in user's ID from the stored session, without a network round trip.
    var signedInUserID: UUID? { auth.currentUser?.id }

    /// The signed-in user's ID, or ``QuotedError/notSignedIn``.
    func requireUserID() throws(QuotedError) -> UUID {
        guard let id = signedInUserID else { throw .notSignedIn }
        return id
    }

    /// Calls a read-only (STABLE) function as GET, so the SDK retries it after a dropped connection
    /// or a 5xx the way it retries table reads (it retries only GET and HEAD; an RPC goes as POST by
    /// default). Arguments become query items. `SupabaseClient.rpc` has no `get` option, so this goes
    /// through the database client for `public`, the schema `Backend` configures (the default).
    func readRPC(_ function: String) throws -> PostgrestFilterBuilder {
        try schema("public").rpc(function, get: true)
    }

    /// ``readRPC(_:)`` with arguments (each one becomes a query item; leave out nil ones).
    func readRPC(_ function: String, params: some Encodable) throws -> PostgrestFilterBuilder {
        try schema("public").rpc(function, params: params, get: true)
    }
}

/// An `AuthLocalStorage` that keeps the session in memory only.
final class InMemoryAuthStorage: AuthLocalStorage {
    private let items = Mutex<[String: Data]>([:])

    func store(key: String, value: Data) throws {
        items.withLock { $0[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        items.withLock { $0[key] }
    }

    func remove(key: String) throws {
        _ = items.withLock { $0.removeValue(forKey: key) }
    }
}
