import Foundation

/// Values from Info.plist.
enum AppInfo {
    /// The support address (`SupportEmail`), or nil when it is empty. Account hides "Contact support"
    /// when this is nil.
    static var supportEmail: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "SupportEmail") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    /// A `mailto:` URL for the support address, or nil.
    static var supportMailURL: URL? {
        supportEmail.flatMap { URL(string: "mailto:\($0)") }
    }

    /// "1.0.0" (CFBundleShortVersionString).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// "1" (CFBundleVersion).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// The Account footer: "Quoted 1.0.0 (1)".
    static var versionLine: String { "Quoted \(version) (\(build))" }
}
