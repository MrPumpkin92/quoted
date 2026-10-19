import Foundation
@testable import QuotedCore

/// Shared fixtures for the QuotedCore tests.
enum Fixture {
    /// A Gregorian calendar in Los Angeles (DST on 2026-11-01 and 2027-03-14).
    static let losAngeles: Calendar = calendar("America/Los_Angeles")

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A wall-clock date in `calendar`.
    static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in calendar: Calendar = losAngeles
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// A deterministic UUID whose last group encodes `n`.
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", n))!
    }

    static func ids(_ count: Int) -> [UUID] { (1...count).map(id) }

    /// The hour and minute of `date` in `calendar`.
    static func clock(_ date: Date, in calendar: Calendar = losAngeles) -> (hour: Int, minute: Int) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour!, components.minute!)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try QuotedJSON.makeDecoder().decode(type, from: Data(json.utf8))
    }

    /// Encodes and returns the top-level JSON object.
    static func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try QuotedJSON.makeEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! [String: Any]
    }

    static func jsonString(_ value: some Encodable) throws -> String {
        String(decoding: try QuotedJSON.makeEncoder().encode(value), as: UTF8.self)
    }
}
