import Foundation

/// Where the backend lives: the project URL and the publishable key (designed to ship in clients).
///
/// The app reads both from Info.plist (`SupabaseURL`, `SupabasePublishableKey`), which get their
/// values from `Config/*.xcconfig`. Never put a secret or service-role key here.
public struct SupabaseConfig: Hashable, Sendable {
    public var url: URL
    public var publishableKey: String

    public init(url: URL, publishableKey: String) {
        self.url = url
        self.publishableKey = publishableKey
    }

    /// Info.plist key for the project URL.
    public static let urlInfoKey = "SupabaseURL"
    /// Info.plist key for the publishable key.
    public static let publishableKeyInfoKey = "SupabasePublishableKey"

    /// Reads the configuration from a bundle's Info.plist.
    public static func fromBundle(_ bundle: Bundle = .main) throws(SupabaseConfigError) -> SupabaseConfig {
        try fromInfoDictionary(bundle.infoDictionary)
    }

    /// Reads the configuration from an Info.plist dictionary. Unexpanded build settings such as
    /// `$(SUPABASE_URL)` count as missing.
    static func fromInfoDictionary(_ info: [String: Any]?) throws(SupabaseConfigError) -> SupabaseConfig {
        let rawURL = try value(for: urlInfoKey, in: info)
        let key = try value(for: publishableKeyInfoKey, in: info)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { throw .invalidURL(rawURL) }
        if key.hasPrefix("sb_secret_") { throw .secretKeyInClient }
        return SupabaseConfig(url: url, publishableKey: key)
    }

    private static func value(for key: String, in info: [String: Any]?) throws(SupabaseConfigError) -> String {
        guard let raw = info?[key] as? String else { throw .missing(key) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("$(") else { throw .missing(key) }
        return text
    }
}

/// Why ``SupabaseConfig/fromBundle(_:)`` failed. These are build-configuration mistakes.
public enum SupabaseConfigError: Error, Hashable, Sendable, LocalizedError {
    /// The Info.plist key is missing, empty or an unexpanded `$(…)` build setting.
    case missing(String)
    /// `SupabaseURL` is not an http(s) URL with a host.
    case invalidURL(String)
    /// The key is a secret key, which must never ship in the app.
    case secretKeyInClient

    public var errorDescription: String? {
        switch self {
        case .missing(let key):
            "Info.plist key \(key) is missing or empty. Set it from Config/*.xcconfig."
        case .invalidURL(let value):
            "Info.plist key SupabaseURL is not a valid http(s) URL: \(value)"
        case .secretKeyInClient:
            "SupabasePublishableKey holds a secret key. Use the publishable key (sb_publishable_…)."
        }
    }
}
