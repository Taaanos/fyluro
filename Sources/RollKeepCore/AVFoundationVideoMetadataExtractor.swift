import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct AVFoundationVideoMetadataExtractor: VideoMetadataExtracting {
    private let parser = VideoCreationDateParser()
    private let embeddedMetadataExtractor: @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    private static let embeddedFallbackSearchByteCount = 2 * 1024 * 1024

    public init() {
        self.embeddedMetadataExtractor = { fileURL, parser in
            EmbeddedVideoMetadataTextParser().extract(
                from: fileURL,
                parser: parser,
                byteCount: Self.embeddedFallbackSearchByteCount
            )
        }
    }

    init(embeddedMetadataExtractor: @escaping @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot) {
        self.embeddedMetadataExtractor = embeddedMetadataExtractor
    }

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
            var captureDateTime: Date?
            var cameraMake: String?
            var cameraModel: String?
            var cameraSerial: String?

            consumeMetadataItems(
                asset.commonMetadata,
                captureDateTime: &captureDateTime,
                cameraMake: &cameraMake,
                cameraModel: &cameraModel,
                cameraSerial: &cameraSerial
            )

            for format in asset.availableMetadataFormats {
                consumeMetadataItems(
                    asset.metadata(forFormat: format),
                    captureDateTime: &captureDateTime,
                    cameraMake: &cameraMake,
                    cameraModel: &cameraModel,
                    cameraSerial: &cameraSerial
                )
            }

            let primarySnapshot = VideoMetadataSnapshot(
                captureDateTime: captureDateTime,
                cameraMake: cameraMake,
                cameraModel: cameraModel,
                cameraSerial: cameraSerial
            )
            return resolveEmbeddedFallbackIfNeeded(primary: primarySnapshot, fileURL: fileURL)
        #else
            return VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
        #endif
    }

    func resolveEmbeddedFallbackIfNeeded(primary: VideoMetadataSnapshot, fileURL: URL) -> VideoMetadataSnapshot {
        guard Self.requiresEmbeddedFallback(primary) else {
            return primary
        }

        let embeddedMetadata = embeddedMetadataExtractor(fileURL, parser)
        return VideoMetadataSnapshot(
            captureDateTime: primary.captureDateTime ?? embeddedMetadata.captureDateTime,
            cameraMake: primary.cameraMake ?? embeddedMetadata.cameraMake,
            cameraModel: primary.cameraModel ?? embeddedMetadata.cameraModel,
            cameraSerial: primary.cameraSerial ?? embeddedMetadata.cameraSerial
        )
    }

    static func requiresEmbeddedFallback(_ metadata: VideoMetadataSnapshot) -> Bool {
        metadata.captureDateTime == nil &&
            metadata.cameraMake == nil &&
            metadata.cameraModel == nil
    }

    #if canImport(AVFoundation)
    private func consumeMetadataItems(
        _ items: [AVMetadataItem],
        captureDateTime: inout Date?,
        cameraMake: inout String?,
        cameraModel: inout String?,
        cameraSerial: inout String?
    ) {
        for item in items {
            if captureDateTime == nil, isCreationDateItem(item), let date = dateValue(from: item) {
                captureDateTime = date
            }
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
    }

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
    func extract(
        from fileURL: URL,
        parser: VideoCreationDateParser,
        byteCount: Int = 2 * 1024 * 1024
    ) -> VideoMetadataSnapshot {
        guard let data = readSearchData(from: fileURL, byteCount: byteCount) else {
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
        var searchableTextCache: String?
        func searchableText() -> String {
            if let searchableTextCache {
                return searchableTextCache
            }
            if printableStrings.isEmpty {
                searchableTextCache = rawText
            } else {
                searchableTextCache = rawText + "\n" + printableStrings.joined(separator: "\n")
            }
            return searchableTextCache ?? rawText
        }

        var creationDate = firstMatch(in: rawText, regexes: Self.creationDateRegexes).flatMap(parser.parse)
        var xmlDevice = parseXMLDevice(in: rawText)
        var cameraMake = sanitize(xmlDevice.make ?? firstMatch(in: rawText, regexes: Self.labeledMakeRegexes))
        var cameraModel = sanitize(xmlDevice.model ?? firstMatch(in: rawText, regexes: Self.labeledModelRegexes))
        var cameraSerial = sanitizeSerial(xmlDevice.serial)

        if creationDate == nil || cameraMake == nil || cameraModel == nil {
            let combinedText = searchableText()
            if creationDate == nil {
                creationDate = firstMatch(in: combinedText, regexes: Self.creationDateRegexes).flatMap(parser.parse)
            }
            if cameraMake == nil || cameraModel == nil {
                xmlDevice = parseXMLDevice(in: combinedText)
                if cameraSerial == nil {
                    cameraSerial = sanitizeSerial(xmlDevice.serial)
                }
                if cameraMake == nil {
                    cameraMake = sanitize(xmlDevice.make ?? firstMatch(in: combinedText, regexes: Self.labeledMakeRegexes))
                }
                if cameraModel == nil {
                    cameraModel = sanitize(xmlDevice.model ?? firstMatch(in: combinedText, regexes: Self.labeledModelRegexes))
                }
            }
        }

        if cameraMake == nil {
            cameraMake = firstMatchingPrintableString(
                in: printableStrings,
                regexes: Self.heuristicMakeRegexes
            )
        }
        if cameraModel == nil {
            cameraModel = firstMatchingPrintableString(
                in: printableStrings,
                regexes: Self.heuristicModelRegexes
            )
        }

        return VideoMetadataSnapshot(
            captureDateTime: creationDate,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial
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
        guard
            let match = Self.xmlDeviceRegex.firstMatch(in: rawText, range: NSRange(rawText.startIndex..., in: rawText)),
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

    private func firstMatch(in rawText: String, regexes: [NSRegularExpression]) -> String? {
        for regex in regexes {
            guard let match = regex.firstMatch(in: rawText, range: NSRange(rawText.startIndex..., in: rawText)),
                  let value = substring(in: rawText, result: match, at: 1)
            else {
                continue
            }

            return value
        }

        return nil
    }

    private func firstMatchingPrintableString(in strings: [String], regexes: [NSRegularExpression]) -> String? {
        for regex in regexes {
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

    private static let xmlDeviceRegex = try! NSRegularExpression(
        pattern: #"<Device\b[^>]*manufacturer="([^"]+)"[^>]*modelName="([^"]+)"[^>]*serialNo="([^"]+)""#,
        options: [.caseInsensitive]
    )

    private static let creationDateRegexes = compileRegexes(
        [
            #"<CreationDate[^>]*value="([^"]+)""#,
            #"CreationDate(?:Value)?\s*[:=]\s*([^\r\n<]+)"#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledModelRegexes = compileRegexes(
        [
            #"Camera Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Device Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Model Name\s*[:=]\s*([^\r\n<]+)"#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledMakeRegexes = compileRegexes(
        [
            #"Camera Make Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Device Manufacturer\s*[:=]\s*([^\r\n<]+)"#,
            #"Make\s*[:=]\s*([^\r\n<]+)"#,
        ],
        options: [.caseInsensitive]
    )

    private static let heuristicModelRegexes = compileRegexes(
        [
            #"^ILCE-[A-Z0-9-]+$"#,
            #"^DSC-[A-Z0-9-]+$"#,
            #"^HERO\d+(?:\s+[A-Za-z0-9]+)+$"#,
            #"^[A-Z]{2,5}-[A-Z0-9]{2,}(?:-[A-Z0-9]+)*$"#,
        ]
    )

    private static let heuristicMakeRegexes = compileRegexes(
        [
            #"^Sony$"#,
            #"^GoPro$"#,
            #"^Canon$"#,
            #"^FUJIFILM$"#,
            #"^NIKON$"#,
            #"^DJI$"#,
        ]
    )

    private static func compileRegexes(
        _ patterns: [String],
        options: NSRegularExpression.Options = []
    ) -> [NSRegularExpression] {
        patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: options)
        }
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
