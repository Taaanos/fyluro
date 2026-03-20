import Foundation

public struct VideoCreationDateParser {
    public init() {}

    public func parse(_ rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        for formatter in Self.iso8601WithTimeZone {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        for formatter in Self.formattersWithTimeZone {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        for formatter in Self.formattersWithoutTimeZone {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private static let iso8601WithTimeZone: [ISO8601DateFormatter] = [
        buildISO8601(options: [.withInternetDateTime, .withFractionalSeconds]),
        buildISO8601(options: [.withInternetDateTime]),
    ]

    private static let formattersWithTimeZone: [DateFormatter] = [
        buildDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ssZ", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ssXXXXX", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy-MM-dd HH:mm:ssZ", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ssZ", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ssXXXXX", timeZone: TimeZone(secondsFromGMT: 0)),
    ]

    private static let formattersWithoutTimeZone: [DateFormatter] = [
        buildDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: .current),
        buildDateFormatter(format: "yyyy-MM-dd HH:mm:ss", timeZone: .current),
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ss", timeZone: .current),
    ]

    private static func buildISO8601(options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    private static func buildDateFormatter(format: String, timeZone: TimeZone?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }
}
