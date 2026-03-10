import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct AVFoundationVideoMetadataExtractor: VideoMetadataExtracting {
    private let parser = VideoCreationDateParser()
    private let embeddedMetadataParser = EmbeddedVideoMetadataTextParser()

    public init() {}

    public func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        let metadata = extractMetadata(from: fileURL)
        if let captureDateTime = metadata.captureDateTime {
            return VideoMetadata(
                captureDateTime: captureDateTime,
                captureDateSource: .creationTime,
                usedFallback: false,
                cameraMake: metadata.cameraMake,
                cameraModel: metadata.cameraModel,
                cameraSerial: metadata.cameraSerial
            )
        }

        return VideoMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            usedFallback: true,
            cameraMake: metadata.cameraMake,
            cameraModel: metadata.cameraModel,
            cameraSerial: metadata.cameraSerial
        )
    }

    private func extractMetadata(from fileURL: URL) -> VideoMetadataSnapshot {
        #if canImport(AVFoundation)
            let asset = AVURLAsset(url: fileURL)
            var allMetadata = asset.commonMetadata
            for format in asset.availableMetadataFormats {
                allMetadata.append(contentsOf: asset.metadata(forFormat: format))
            }

            var captureDateTime: Date?
            var cameraMake: String?
            var cameraModel: String?
            var cameraSerial: String?

            for item in allMetadata where isCreationDateItem(item) {
                if captureDateTime == nil, let date = dateValue(from: item) {
                    captureDateTime = date
                }
            }

            for item in allMetadata {
                if cameraMake == nil, isMakeItem(item) {
                    cameraMake = sanitize(item.stringValue)
                }
                if cameraModel == nil, isModelItem(item) {
                    cameraModel = sanitize(item.stringValue)
                }
                if cameraSerial == nil, isSerialItem(item) {
                    cameraSerial = sanitize(item.stringValue)
                }
            }

            let embeddedMetadata = embeddedMetadataParser.extract(
                from: fileURL,
                parser: parser
            )

            return VideoMetadataSnapshot(
                captureDateTime: captureDateTime ?? embeddedMetadata.captureDateTime,
                cameraMake: cameraMake ?? embeddedMetadata.cameraMake,
                cameraModel: cameraModel ?? embeddedMetadata.cameraModel,
                cameraSerial: cameraSerial ?? embeddedMetadata.cameraSerial
            )
        #else
            return VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
        #endif
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

    private func isMakeItem(_ item: AVMetadataItem) -> Bool {
        if let commonKey = item.commonKey?.rawValue.lowercased(), commonKey == "make" {
            return true
        }

        return keyContainsAny(item, fragments: ["make", "manufacturer"])
    }

    private func isModelItem(_ item: AVMetadataItem) -> Bool {
        if let commonKey = item.commonKey?.rawValue.lowercased(), commonKey == "model" {
            return true
        }

        return keyContainsAny(item, fragments: ["model"])
    }

    private func isSerialItem(_ item: AVMetadataItem) -> Bool {
        return keyContainsAny(item, fragments: ["serial"])
    }

    private func keyContainsAny(_ item: AVMetadataItem, fragments: [String]) -> Bool {
        if let identifier = item.identifier?.rawValue.lowercased(),
           fragments.contains(where: { identifier.contains($0) }) {
            return true
        }

        if let key = item.key as? String {
            let normalized = key.lowercased()
            return fragments.contains(where: { normalized.contains($0) })
        }

        return false
    }

    private func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
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

struct VideoMetadataSnapshot {
    let captureDateTime: Date?
    let cameraMake: String?
    let cameraModel: String?
    let cameraSerial: String?
}

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

struct EmbeddedVideoMetadataTextParser {
    func extract(from fileURL: URL, parser: VideoCreationDateParser) -> VideoMetadataSnapshot {
        guard let data = readSearchData(from: fileURL, byteCount: 16 * 1024 * 1024) else {
            return VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
        }

        let printableStrings = extractPrintableStrings(from: data, minimumLength: 6)
        let rawText = String(decoding: data, as: UTF8.self)
        return parse(rawText: rawText, printableStrings: printableStrings, parser: parser)
    }

    func parse(
        rawText: String,
        printableStrings: [String],
        parser: VideoCreationDateParser
    ) -> VideoMetadataSnapshot {
        let searchableText = ([rawText] + printableStrings).joined(separator: "\n")
        let creationDate = firstMatch(
            in: searchableText,
            patterns: [
                #"<CreationDate[^>]*value="([^"]+)""#,
                #"CreationDate(?:Value)?\s*[:=]\s*([^\r\n<]+)"#,
            ]
        ).flatMap(parser.parse)

        let xmlDevice = parseXMLDevice(in: searchableText)
        let labeledModel = firstMatch(
            in: searchableText,
            patterns: [
                #"Camera Model Name\s*[:=]\s*([^\r\n<]+)"#,
                #"Device Model Name\s*[:=]\s*([^\r\n<]+)"#,
                #"Model Name\s*[:=]\s*([^\r\n<]+)"#,
            ]
        )
        let labeledMake = firstMatch(
            in: searchableText,
            patterns: [
                #"Camera Make Name\s*[:=]\s*([^\r\n<]+)"#,
                #"Device Manufacturer\s*[:=]\s*([^\r\n<]+)"#,
                #"Make\s*[:=]\s*([^\r\n<]+)"#,
            ]
        )

        let heuristicModel = firstMatchingPrintableString(
            in: printableStrings,
            patterns: [
                #"^ILCE-[A-Z0-9-]+$"#,
                #"^DSC-[A-Z0-9-]+$"#,
                #"^HERO\d+(?:\s+[A-Za-z0-9]+)+$"#,
                #"^[A-Z]{2,5}-[A-Z0-9]{2,}(?:-[A-Z0-9]+)*$"#,
            ]
        )
        let heuristicMake = firstMatchingPrintableString(
            in: printableStrings,
            patterns: [
                #"^Sony$"#,
                #"^GoPro$"#,
                #"^Canon$"#,
                #"^FUJIFILM$"#,
                #"^NIKON$"#,
                #"^DJI$"#,
            ]
        )

        return VideoMetadataSnapshot(
            captureDateTime: creationDate,
            cameraMake: sanitize(xmlDevice.make ?? labeledMake ?? heuristicMake),
            cameraModel: sanitize(xmlDevice.model ?? labeledModel ?? heuristicModel),
            cameraSerial: sanitizeSerial(xmlDevice.serial)
        )
    }

    private func readSearchData(from fileURL: URL, byteCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 0 else {
            return try? handle.read(upToCount: byteCount)
        }

        guard fileSize > byteCount else {
            return try? handle.read(upToCount: byteCount)
        }

        let prefix = try? handle.read(upToCount: byteCount)
        let suffixOffset = max(fileSize - byteCount, 0)
        try? handle.seek(toOffset: UInt64(suffixOffset))
        let suffix = try? handle.readToEnd()

        var combined = Data()
        if let prefix {
            combined.append(prefix)
        }
        combined.append(0x0A)
        if let suffix {
            combined.append(suffix)
        }
        return combined
    }

    func extractPrintableStrings(from data: Data, minimumLength: Int) -> [String] {
        guard !data.isEmpty else {
            return []
        }

        var strings: [String] = []
        var buffer = ""
        buffer.reserveCapacity(minimumLength * 2)

        for byte in data {
            if byte == 9 || byte == 10 || byte == 13 || (32...126).contains(byte) {
                buffer.append(Character(UnicodeScalar(Int(byte))!))
                continue
            }

            flushBuffer(&buffer, into: &strings, minimumLength: minimumLength)
        }

        flushBuffer(&buffer, into: &strings, minimumLength: minimumLength)
        return strings
    }

    private func flushBuffer(_ buffer: inout String, into strings: inout [String], minimumLength: Int) {
        defer { buffer.removeAll(keepingCapacity: true) }

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else {
            return
        }

        strings.append(trimmed)
    }

    private func parseXMLDevice(in rawText: String) -> (make: String?, model: String?, serial: String?) {
        let devicePattern = #"<Device\b[^>]*manufacturer="([^"]+)"[^>]*modelName="([^"]+)"[^>]*serialNo="([^"]+)""#
        guard
            let regex = try? NSRegularExpression(pattern: devicePattern),
            let match = regex.firstMatch(in: rawText, range: NSRange(rawText.startIndex..., in: rawText)),
            let make = substring(in: rawText, result: match, at: 1),
            let model = substring(in: rawText, result: match, at: 2)
        else {
            return (nil, nil, nil)
        }

        return (
            make: make,
            model: model,
            serial: substring(in: rawText, result: match, at: 3)
        )
    }

    private func firstMatch(in rawText: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            guard let match = regex.firstMatch(in: rawText, range: NSRange(rawText.startIndex..., in: rawText)),
                  let value = substring(in: rawText, result: match, at: 1)
            else {
                continue
            }

            return value
        }

        return nil
    }

    private func firstMatchingPrintableString(in strings: [String], patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            for candidate in strings {
                let range = NSRange(candidate.startIndex..., in: candidate)
                guard regex.firstMatch(in: candidate, range: range) != nil else {
                    continue
                }

                if candidate.hasSuffix("STRM") {
                    return String(candidate.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                return candidate
            }
        }

        return nil
    }

    private func substring(in text: String, result: NSTextCheckingResult, at index: Int) -> String? {
        guard let range = Range(result.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func sanitizeSerial(_ value: String?) -> String? {
        guard let trimmed = sanitize(value) else {
            return nil
        }

        if trimmed == "0" || trimmed == "4294967295" {
            return nil
        }

        if trimmed.allSatisfy(\.isNumber), Set(trimmed).count == 1 {
            return nil
        }

        return trimmed
    }
}
