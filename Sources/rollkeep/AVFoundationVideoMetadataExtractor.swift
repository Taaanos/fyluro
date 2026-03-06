import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

struct AVFoundationVideoMetadataExtractor: VideoMetadataExtracting {
    private let parser = VideoCreationDateParser()

    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        if let captureDateTime = extractCreationDate(from: fileURL) {
            return VideoMetadata(
                captureDateTime: captureDateTime,
                captureDateSource: .creationTime,
                usedFallback: false
            )
        }

        return VideoMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            usedFallback: true
        )
    }

    private func extractCreationDate(from fileURL: URL) -> Date? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: fileURL)
        var allMetadata = asset.commonMetadata
        for format in asset.availableMetadataFormats {
            allMetadata.append(contentsOf: asset.metadata(forFormat: format))
        }

        for item in allMetadata where isCreationDateItem(item) {
            if let date = dateValue(from: item) {
                return date
            }
        }
        #endif

        return nil
    }

    #if canImport(AVFoundation)
    private func isCreationDateItem(_ item: AVMetadataItem) -> Bool {
        if item.commonKey?.rawValue.lowercased() == "creationdate" {
            return true
        }

        if let identifier = item.identifier?.rawValue.lowercased(),
           identifier.contains("creationdate") || identifier.contains("creation_time")
        {
            return true
        }

        if let key = item.key as? String {
            let normalized = key.lowercased()
            return normalized.contains("creationdate") || normalized.contains("creation_time")
        }

        return false
    }

    private func dateValue(from item: AVMetadataItem) -> Date? {
        if let date = item.dateValue {
            return date
        }

        if let raw = item.stringValue {
            return parser.parse(raw)
        }

        return nil
    }
    #endif
}

struct VideoCreationDateParser {
    func parse(_ rawValue: String) -> Date? {
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
    ]

    private static let formattersWithoutTimeZone: [DateFormatter] = [
        buildDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: .current),
        buildDateFormatter(format: "yyyy-MM-dd HH:mm:ss", timeZone: .current),
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
