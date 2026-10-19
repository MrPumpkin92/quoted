import Foundation

/// JSON coders shared by the app, the widget and the QuotedKit repositories.
///
/// The models declare snake_case `CodingKeys` that match the Postgres column names, so these coders use
/// the default key strategy. Never combine the models with `.convertFromSnakeCase`.
/// Dates use ``Timestamp``: Postgres `timestamptz` text in, ISO 8601 UTC with microseconds out.
public enum QuotedJSON {
    /// A decoder that reads PostgREST rows and the local cache files.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        return decoder
    }

    /// An encoder that writes Postgres-compatible timestamps. Keys are sorted so output is stable.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decodes dates with ``Timestamp/date(from:)``. Use it to configure a decoder you do not own.
    public static var dateDecodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = Timestamp.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 / timestamptz string, got \(text)"
                )
            }
            return date
        }
    }

    /// Encodes dates with ``Timestamp/string(from:)``.
    public static var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Timestamp.string(from: date))
        }
    }
}

/// Parses and formats the timestamp text Postgres and PostgREST exchange.
///
/// Accepted: `YYYY-MM-DD(T| )HH:MM[:SS[.fraction]][Z | ±HH[[:]MM[[:]SS]]]`, for example
/// `2026-10-19T03:26:38.123456+00:00`, `2026-10-19T03:26:38Z` or `2026-10-19 03:26:38+02`.
/// Text without an offset is read as UTC. The parser is pure arithmetic, so it does not depend on
/// the device locale, calendar or time zone.
public enum Timestamp {
    /// Parses a timestamp, or returns nil if the text is not a valid timestamp.
    public static func date(from text: String) -> Date? {
        var scanner = Scanner(Array(text.utf8))
        guard
            let year = scanner.digits(4), scanner.take(UInt8(ascii: "-")),
            let month = scanner.digits(2), scanner.take(UInt8(ascii: "-")),
            let day = scanner.digits(2),
            scanner.take(UInt8(ascii: "T")) || scanner.take(UInt8(ascii: "t")) || scanner.take(UInt8(ascii: " ")),
            let hour = scanner.digits(2), scanner.take(UInt8(ascii: ":")),
            let minute = scanner.digits(2)
        else { return nil }

        var second = 0
        var fraction = 0.0
        if scanner.take(UInt8(ascii: ":")) {
            guard let value = scanner.digits(2) else { return nil }
            second = value
            if scanner.take(UInt8(ascii: ".")) || scanner.take(UInt8(ascii: ",")) {
                guard let value = scanner.fraction() else { return nil }
                fraction = value
            }
        }

        var offsetSeconds = 0
        if scanner.take(UInt8(ascii: "Z")) || scanner.take(UInt8(ascii: "z")) {
            offsetSeconds = 0
        } else if let sign = scanner.sign() {
            guard let offsetHours = scanner.digits(2) else { return nil }
            var offsetMinutes = 0
            var offsetSecs = 0
            _ = scanner.take(UInt8(ascii: ":"))
            if let value = scanner.digits(2) {
                offsetMinutes = value
                _ = scanner.take(UInt8(ascii: ":"))
                if let value = scanner.digits(2) { offsetSecs = value }
            }
            guard offsetHours <= 15, offsetMinutes < 60, offsetSecs < 60 else { return nil }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60 + offsetSecs)
        }
        guard scanner.isAtEnd else { return nil }

        guard (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Formats a date as UTC ISO 8601 with microseconds, for example `2026-10-19T03:26:38.123456Z`.
    public static func string(from date: Date) -> String {
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let (wholeSeconds, micro) = floorDivMod(micros, 1_000_000)
        let (days, secondOfDay) = floorDivMod(wholeSeconds, 86_400)
        let (year, month, day) = civilFromDays(Int(days))
        let hour = Int(secondOfDay / 3600)
        let minute = Int(secondOfDay % 3600 / 60)
        let second = Int(secondOfDay % 60)
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2)).\(pad(Int(micro), 6))Z"
    }

    // MARK: Calendar arithmetic (proleptic Gregorian, after Howard Hinnant's algorithms)

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func floorDivMod(_ value: Int64, _ divisor: Int64) -> (Int64, Int64) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index == bytes.count }

        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func sign() -> Int? {
            if take(UInt8(ascii: "+")) { return 1 }
            if take(UInt8(ascii: "-")) { return -1 }
            return nil
        }

        mutating func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            index += count
            return value
        }

        /// Reads one or more fraction digits. Digits past nanoseconds are ignored.
        mutating func fraction() -> Double? {
            var numerator = 0
            var scale = 1
            var read = 0
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                if read < 9 {
                    numerator = numerator * 10 + Int(bytes[index] - UInt8(ascii: "0"))
                    scale *= 10
                }
                read += 1
                index += 1
            }
            return read == 0 ? nil : Double(numerator) / Double(scale)
        }
    }
}
