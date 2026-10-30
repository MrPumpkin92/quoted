import Foundation

/// The app's `quoted://` URLs.
public enum DeepLink: Hashable, Sendable {
    /// `quoted://auth-callback…` from the confirmation email. Holds the full URL for `auth.session(from:)`.
    case authCallback(URL)
    /// `quoted://quote/<uuid>` from a notification or widget.
    case quote(UUID)
    /// `quoted://rotation`, from the empty widget.
    case rotation
    /// `quoted://inbox`: the Inbox at its root. A tap on an inbox alert posted by an earlier build
    /// opens it.
    case inbox

    public static let scheme = "quoted"

    /// The redirect URL to pass to `auth.signUp(…redirectTo:)`.
    public static let authCallbackURL = URL(string: "quoted://auth-callback")!

    /// Parses a URL. Scheme and host are case-insensitive. Returns nil for anything unknown.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return nil }
        let pathParts = components.path.split(separator: "/").map(String.init)
        switch host {
        case "auth-callback":
            return .authCallback(url)
        case "quote":
            guard pathParts.count == 1, let id = UUID(uuidString: pathParts[0]) else { return nil }
            return .quote(id)
        case "rotation":
            return pathParts.isEmpty ? .rotation : nil
        case "inbox":
            return pathParts.isEmpty ? .inbox : nil
        default:
            return nil
        }
    }

    /// Parses a URL. See ``parse(_:)``.
    public init?(url: URL) {
        guard let link = Self.parse(url) else { return nil }
        self = link
    }

    /// The URL for a link. `.authCallback` returns the URL it holds.
    public static func url(for link: DeepLink) -> URL {
        link.url
    }

    /// The URL for this link.
    public var url: URL {
        switch self {
        case .authCallback(let url):
            return url
        case .quote(let id):
            return URL(string: "\(Self.scheme)://quote/\(id.uuidString.lowercased())")!
        case .rotation:
            return URL(string: "\(Self.scheme)://rotation")!
        case .inbox:
            return URL(string: "\(Self.scheme)://inbox")!
        }
    }
}
