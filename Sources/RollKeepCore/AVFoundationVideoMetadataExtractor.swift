import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct AVFoundationVideoMetadataExtractor: VideoMetadataExtracting {
    public enum EmbeddedFallbackMode: Sendable {
        case full
        case disabled
    }

    private let parser = VideoCreationDateParser()
    private let embeddedMetadataExtractor: @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    private let sidecarMetadataExtractor: @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    private let embeddedFallbackMode: EmbeddedFallbackMode
    private static let embeddedFallbackSearchByteCount = 2 * 1024 * 1024

    public init(embeddedFallbackMode: EmbeddedFallbackMode = .full) {
        self.embeddedFallbackMode = embeddedFallbackMode
        self.sidecarMetadataExtractor = { fileURL, parser in
            VideoSidecarMetadataExtractor().extract(for: fileURL, parser: parser)
        }
        self.embeddedMetadataExtractor = { fileURL, parser in
            EmbeddedVideoMetadataTextParser().extract(
                from: fileURL,
                parser: parser,
                byteCount: Self.embeddedFallbackSearchByteCount
            )
        }
    }

    init(
        embeddedFallbackMode: EmbeddedFallbackMode = .full,
        sidecarMetadataExtractor: @escaping @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot = { fileURL, parser in
            VideoSidecarMetadataExtractor().extract(for: fileURL, parser: parser)
        },
        embeddedMetadataExtractor: @escaping @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    ) {
        self.embeddedFallbackMode = embeddedFallbackMode
        self.sidecarMetadataExtractor = sidecarMetadataExtractor
        self.embeddedMetadataExtractor = embeddedMetadataExtractor
    }

    public func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        let metadata = extractMetadata(from: fileURL)
        if let captureDateTime = metadata.captureDateTime {
            let source = metadata.captureDateSource ?? .creationTime
            return VideoMetadata(
                captureDateTime: captureDateTime,
                captureDateSource: source,
                usedFallback: source == .mtimeFallback,
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
                captureDateSource: captureDateTime == nil ? nil : .creationTime,
                cameraMake: cameraMake,
                cameraModel: cameraModel,
                cameraSerial: cameraSerial
            )
            let sidecarResolvedSnapshot = resolveSidecarFallbackIfNeeded(primary: primarySnapshot, fileURL: fileURL)
            return resolveEmbeddedFallbackIfNeeded(primary: sidecarResolvedSnapshot, fileURL: fileURL)
        #else
            return resolveSidecarFallbackIfNeeded(
                primary: VideoMetadataSnapshot(
                    captureDateTime: nil,
                    captureDateSource: nil,
                    cameraMake: nil,
                    cameraModel: nil,
                    cameraSerial: nil
                ),
                fileURL: fileURL
            )
        #endif
    }

    func resolveSidecarFallbackIfNeeded(primary: VideoMetadataSnapshot, fileURL: URL) -> VideoMetadataSnapshot {
        guard Self.requiresSidecarFallback(primary) else {
            return primary
        }

        let sidecarMetadata = sidecarMetadataExtractor(fileURL, parser)
        return VideoMetadataSnapshot(
            captureDateTime: primary.captureDateTime ?? sidecarMetadata.captureDateTime,
            captureDateSource: primary.captureDateSource ?? sidecarMetadata.captureDateSource,
            cameraMake: primary.cameraMake ?? sidecarMetadata.cameraMake,
            cameraModel: primary.cameraModel ?? sidecarMetadata.cameraModel,
            cameraSerial: primary.cameraSerial ?? sidecarMetadata.cameraSerial
        )
    }

    func resolveEmbeddedFallbackIfNeeded(primary: VideoMetadataSnapshot, fileURL: URL) -> VideoMetadataSnapshot {
        guard embeddedFallbackMode == .full else {
            return primary
        }

        guard Self.requiresEmbeddedFallback(primary) else {
            return primary
        }

        let embeddedMetadata = embeddedMetadataExtractor(fileURL, parser)
        return VideoMetadataSnapshot(
            captureDateTime: primary.captureDateTime ?? embeddedMetadata.captureDateTime,
            captureDateSource: primary.captureDateSource ?? embeddedMetadata.captureDateSource,
            cameraMake: primary.cameraMake ?? embeddedMetadata.cameraMake,
            cameraModel: primary.cameraModel ?? embeddedMetadata.cameraModel,
            cameraSerial: primary.cameraSerial ?? embeddedMetadata.cameraSerial
        )
    }

    static func requiresSidecarFallback(_ metadata: VideoMetadataSnapshot) -> Bool {
        metadata.captureDateTime == nil ||
            metadata.cameraMake == nil ||
            metadata.cameraModel == nil ||
            metadata.cameraSerial == nil
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
    let captureDateSource: VideoCaptureDateSource?
    let cameraMake: String?
    let cameraModel: String?
    let cameraSerial: String?

    init(
        captureDateTime: Date?,
        captureDateSource: VideoCaptureDateSource? = nil,
        cameraMake: String?,
        cameraModel: String?,
        cameraSerial: String?
    ) {
        self.captureDateTime = captureDateTime
        self.captureDateSource = captureDateSource
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
    }
}

private struct VideoSidecarMetadataExtractor {
    private let photoMetadataExtractor: any PhotoMetadataExtracting

    init(photoMetadataExtractor: any PhotoMetadataExtracting = ImageIOPhotoMetadataExtractor()) {
        self.photoMetadataExtractor = photoMetadataExtractor
    }

    func extract(for videoURL: URL, parser: VideoCreationDateParser) -> VideoMetadataSnapshot {
        let sidecarURLs = MediaSidecarSupport.discoverSidecarURLs(for: videoURL)
        guard !sidecarURLs.isEmpty else {
            return VideoMetadataSnapshot(
                captureDateTime: nil,
                captureDateSource: nil,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        }

        var captureDateTime: Date?
        var cameraMake: String?
        var cameraModel: String?
        var cameraSerial: String?

        for sidecarURL in sidecarURLs {
            let ext = sidecarURL.pathExtension.lowercased()
            let snapshot: VideoMetadataSnapshot

            if ext == "thm" {
                let photoMetadata = photoMetadataExtractor.extract(from: sidecarURL)
                snapshot = VideoMetadataSnapshot(
                    captureDateTime: photoMetadata.captureDateTime,
                    captureDateSource: photoMetadata.captureDateTime == nil ? nil : .sidecarMetadata,
                    cameraMake: photoMetadata.cameraMake,
                    cameraModel: photoMetadata.cameraModel,
                    cameraSerial: photoMetadata.cameraSerial
                )
            } else {
                let parsed = EmbeddedVideoMetadataTextParser().extract(
                    from: sidecarURL,
                    parser: parser,
                    byteCount: 512 * 1024
                )
                snapshot = VideoMetadataSnapshot(
                    captureDateTime: parsed.captureDateTime,
                    captureDateSource: parsed.captureDateTime == nil ? nil : .sidecarMetadata,
                    cameraMake: parsed.cameraMake,
                    cameraModel: parsed.cameraModel,
                    cameraSerial: parsed.cameraSerial
                )
            }

            if captureDateTime == nil {
                captureDateTime = snapshot.captureDateTime
            }
            if cameraMake == nil {
                cameraMake = snapshot.cameraMake
            }
            if cameraModel == nil {
                cameraModel = snapshot.cameraModel
            }
            if cameraSerial == nil {
                cameraSerial = snapshot.cameraSerial
            }

            if captureDateTime != nil && cameraMake != nil && cameraModel != nil && cameraSerial != nil {
                break
            }
        }

        return VideoMetadataSnapshot(
            captureDateTime: captureDateTime,
            captureDateSource: captureDateTime == nil ? nil : .sidecarMetadata,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial
        )
    }
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
            return VideoMetadataSnapshot(
                captureDateTime: nil,
                captureDateSource: nil,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
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
        var cameraSerial = sanitizeSerial(xmlDevice.serial ?? firstMatch(in: rawText, regexes: Self.labeledSerialRegexes))

        if creationDate == nil || cameraMake == nil || cameraModel == nil || cameraSerial == nil {
            let combinedText = searchableText()
            if creationDate == nil {
                creationDate = firstMatch(in: combinedText, regexes: Self.creationDateRegexes).flatMap(parser.parse)
            }
            if cameraMake == nil || cameraModel == nil || cameraSerial == nil {
                xmlDevice = parseXMLDevice(in: combinedText)
                if cameraSerial == nil {
                    cameraSerial = sanitizeSerial(xmlDevice.serial ?? firstMatch(in: combinedText, regexes: Self.labeledSerialRegexes))
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
            captureDateSource: creationDate == nil ? nil : .creationTime,
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
            #"CreateDate\s*[:=]\s*([^\r\n<]+)"#,
            #"DateTimeOriginal\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?CreateDate>\s*([^<]+)\s*</(?:[\w-]+:)?CreateDate>"#,
            #"<(?:[\w-]+:)?DateTimeOriginal>\s*([^<]+)\s*</(?:[\w-]+:)?DateTimeOriginal>"#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledModelRegexes = compileRegexes(
        [
            #"Camera Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Device Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Model\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?Model>\s*([^<]+)\s*</(?:[\w-]+:)?Model>"#,
            #"(?:\b[\w-]+:)?Model\s*=\s*"([^"]+)""#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledMakeRegexes = compileRegexes(
        [
            #"Camera Make Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Device Manufacturer\s*[:=]\s*([^\r\n<]+)"#,
            #"Make\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?Make>\s*([^<]+)\s*</(?:[\w-]+:)?Make>"#,
            #"(?:\b[\w-]+:)?Make\s*=\s*"([^"]+)""#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledSerialRegexes = compileRegexes(
        [
            #"Camera Serial Number\s*[:=]\s*([^\r\n<]+)"#,
            #"CameraSerialNumber\s*[:=]\s*([^\r\n<]+)"#,
            #"Serial Number\s*[:=]\s*([^\r\n<]+)"#,
            #"SerialNumber\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?CameraSerialNumber>\s*([^<]+)\s*</(?:[\w-]+:)?CameraSerialNumber>"#,
            #"<(?:[\w-]+:)?SerialNumber>\s*([^<]+)\s*</(?:[\w-]+:)?SerialNumber>"#,
        ],
        options: [.caseInsensitive]
    )

    private static let heuristicModelRegexes = compileRegexes(
        [
            #"^ILCE-[A-Z0-9-]+$"#,
            #"^DSC-[A-Z0-9-]+$"#,
            #"^HERO\d+(?:\s+[A-Za-z0-9]+)+$"#,
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
