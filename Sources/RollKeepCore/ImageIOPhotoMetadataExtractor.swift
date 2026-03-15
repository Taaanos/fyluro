import Foundation
import ImageIO

public struct ImageIOPhotoMetadataExtractor: PhotoMetadataExtracting {
    public init() {}

    public func extract(from fileURL: URL) -> PhotoMetadata {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [AnyHashable: Any]
        else {
            return PhotoMetadata(
                captureDateTime: nil,
                captureDateSource: .missing,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        }

        let exif = normalizeDictionary(imageProperties[kCGImagePropertyExifDictionary]) ?? [:]
        let tiff = normalizeDictionary(imageProperties[kCGImagePropertyTIFFDictionary]) ?? [:]
        let tiffMake = sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFMake)])
        let tiffModel = sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFModel)])
        let supplementalMetadata = shouldReadSupplementalMetadata(forPrimaryModel: tiffModel)
            ? EmbeddedPhotoMetadataTextParser().extract(from: fileURL)
            : .empty
        let cameraModel = resolveCameraModel(
            primaryModel: tiffModel,
            supplementalModel: supplementalMetadata.productName
        )
        let cameraSerial = extractSerial(
            exif: exif,
            tiff: tiff,
            supplementalSerial: supplementalMetadata.cameraSerial
        )

        let dateTimeOriginalRaw = exif[stringKey(kCGImagePropertyExifDateTimeOriginal)]
        let createDateRaw = exif[stringKey(kCGImagePropertyExifDateTimeDigitized)] ?? tiff[stringKey(kCGImagePropertyTIFFDateTime)]

        let parser = ExifDateParser()
        if let dateTimeOriginalRaw,
           let parsed = parser.parse(dateTimeOriginalRaw)
        {
            return PhotoMetadata(
                captureDateTime: parsed,
                captureDateSource: .dateTimeOriginal,
                cameraMake: tiffMake,
                cameraModel: cameraModel,
                cameraSerial: cameraSerial
            )
        }

        if let createDateRaw,
           let parsed = parser.parse(createDateRaw)
        {
            return PhotoMetadata(
                captureDateTime: parsed,
                captureDateSource: .createDate,
                cameraMake: tiffMake,
                cameraModel: cameraModel,
                cameraSerial: cameraSerial
            )
        }

        return PhotoMetadata(
            captureDateTime: nil,
            captureDateSource: .missing,
            cameraMake: tiffMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial
        )
    }

    private func extractSerial(exif: [String: String], tiff: [String: String], supplementalSerial: String?) -> String? {
        let serialKeys = [
            "BodySerialNumber",
            "SerialNumber",
            "CameraSerialNumber",
            "InternalSerialNumber",
        ]

        for key in serialKeys {
            if let value = sanitizeIdentifier(exif[key]) {
                return value
            }
        }

        if let tiffSerial = sanitizeIdentifier(tiff["SerialNumber"]) {
            return tiffSerial
        }

        return sanitizeIdentifier(supplementalSerial)
    }

    private func shouldReadSupplementalMetadata(forPrimaryModel model: String?) -> Bool {
        guard let model else {
            return true
        }

        return isOpaqueModelCode(model)
    }

    private func resolveCameraModel(primaryModel: String?, supplementalModel: String?) -> String? {
        guard let primaryModel else {
            return sanitizeIdentifier(supplementalModel)
        }

        guard let supplementalModel = sanitizeIdentifier(supplementalModel),
              shouldPreferSupplementalModel(primaryModel: primaryModel, supplementalModel: supplementalModel)
        else {
            return primaryModel
        }

        return supplementalModel
    }

    private func shouldPreferSupplementalModel(primaryModel: String, supplementalModel: String) -> Bool {
        if primaryModel.caseInsensitiveCompare(supplementalModel) == .orderedSame {
            return false
        }

        return isOpaqueModelCode(primaryModel) && !isOpaqueModelCode(supplementalModel)
    }

    private func isOpaqueModelCode(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(
            of: #"[^A-Za-z0-9]"#,
            with: "",
            options: [.regularExpression]
        )
        guard !compact.isEmpty else {
            return false
        }

        let range = NSRange(compact.startIndex..., in: compact)
        return Self.opaqueModelCodeRegex.firstMatch(in: compact, range: range) != nil
    }

    private func normalizeDictionary(_ value: Any?) -> [String: String]? {
        guard let dictionary = value as? [AnyHashable: Any] else {
            return nil
        }

        var normalized: [String: String] = [:]
        for (key, rawValue) in dictionary {
            guard let valueString = rawValue as? String
            else {
                continue
            }

            let keyString = String(describing: key)
            normalized[keyString] = valueString
        }

        return normalized
    }

    private func stringKey(_ key: CFString) -> String {
        key as String
    }

    private func sanitizeIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    private static let opaqueModelCodeRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z]{2,}[0-9]{3,}$"#
    )
}

struct EmbeddedPhotoMetadataSnapshot: Equatable, Sendable {
    let productName: String?
    let cameraSerial: String?

    static let empty = EmbeddedPhotoMetadataSnapshot(productName: nil, cameraSerial: nil)
}

struct EmbeddedPhotoMetadataTextParser {
    func extract(from fileURL: URL, byteCount: Int = 512 * 1024) -> EmbeddedPhotoMetadataSnapshot {
        guard let data = readSearchData(from: fileURL, byteCount: byteCount) else {
            return .empty
        }

        return parse(rawText: String(decoding: data, as: UTF8.self))
    }

    func parse(rawText: String) -> EmbeddedPhotoMetadataSnapshot {
        let productName = sanitize(firstMatch(in: rawText, regexes: Self.productNameRegexes))
        let cameraSerial = sanitize(firstMatch(in: rawText, regexes: Self.cameraSerialRegexes))
        return EmbeddedPhotoMetadataSnapshot(productName: productName, cameraSerial: cameraSerial)
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

        if fileSize <= byteCount {
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

    private static let productNameRegexes = compileRegexes(
        [
            #"(?:\b[\w-]+:)?ProductName\s*=\s*"([^"]+)""#,
            #"<(?:[\w-]+:)?ProductName>\s*([^<]+?)\s*</(?:[\w-]+:)?ProductName>"#,
        ],
        options: [.caseInsensitive]
    )

    private static let cameraSerialRegexes = compileRegexes(
        [
            #"(?:\b[\w-]+:)?CameraSerialNumber\s*=\s*"([^"]+)""#,
            #"<(?:[\w-]+:)?CameraSerialNumber>\s*([^<]+?)\s*</(?:[\w-]+:)?CameraSerialNumber>"#,
        ],
        options: [.caseInsensitive]
    )

    private static func compileRegexes(
        _ patterns: [String],
        options: NSRegularExpression.Options = []
    ) -> [NSRegularExpression] {
        patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: options)
        }
    }
}

public struct ExifDateParser {
    public init() {}

    public func parse(_ rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
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

    private static let formattersWithTimeZone: [DateFormatter] = [
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ssXXXXX", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ss XXX", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ssZ", timeZone: TimeZone(secondsFromGMT: 0)),
    ]

    private static let formattersWithoutTimeZone: [DateFormatter] = [
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ss", timeZone: .current),
    ]

    private static func buildDateFormatter(format: String, timeZone: TimeZone?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }
}
