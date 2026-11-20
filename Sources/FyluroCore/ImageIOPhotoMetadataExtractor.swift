import Foundation
import ImageIO

public struct ImageIOPhotoMetadataExtractor: PhotoMetadataExtracting {
    private let cameraIdentityResolver = CameraIdentityResolver()
    private let nativeFallbackReader = NativeRAWIdentityFallbackReader()

    public init() {}

    public func extract(from fileURL: URL) -> PhotoMetadata {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [AnyHashable: Any]
        else {
            // ImageIO couldn't open this at all -- typically a RAW format
            // (or a stripped/synthetic test file) it doesn't decode. Try
            // native byte-level identity parsing before giving up.
            let nativeFields = nativeFallbackReader.identity(for: fileURL)
            let resolvedIdentity = cameraIdentityResolver.resolvePhotoIdentity(
                tiffMake: nil,
                tiffModel: nil,
                supplementalModel: nil,
                serialCandidates: nativeSerialCandidates(nativeFields),
                supplementalSerial: nil,
                nativeFallbackMake: nativeFields?.make,
                nativeFallbackModel: nativeFields?.model ?? nativeFields?.uniqueCameraModel
            )
            return PhotoMetadata(
                captureDateTime: nil,
                captureDateSource: .missing,
                cameraMake: resolvedIdentity.make,
                cameraModel: resolvedIdentity.model,
                cameraSerial: resolvedIdentity.serial,
                cameraEvidence: resolvedIdentity.evidence
            )
        }

        let exif = normalizeDictionary(imageProperties[kCGImagePropertyExifDictionary]) ?? [:]
        let tiff = normalizeDictionary(imageProperties[kCGImagePropertyTIFFDictionary]) ?? [:]
        let tiffMake = sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFMake)])
        let tiffModel = sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFModel)])
        let supplementalMetadata = shouldReadSupplementalMetadata(forPrimaryModel: tiffModel)
            ? EmbeddedPhotoMetadataTextParser().extract(from: fileURL)
            : .empty
        // ImageIO opened the file but its TIFF dictionary is empty (some RAW
        // decoders return a valid CGImageSource with no metadata for formats
        // they only partially support) -- try the native fallback here too.
        let nativeFields = (tiffMake == nil && tiffModel == nil) ? nativeFallbackReader.identity(for: fileURL) : nil
        let resolvedIdentity = cameraIdentityResolver.resolvePhotoIdentity(
            tiffMake: tiffMake,
            tiffModel: tiffModel,
            supplementalModel: sanitizeIdentifier(supplementalMetadata.productName),
            serialCandidates: serialCandidates(exif: exif, tiff: tiff) + nativeSerialCandidates(nativeFields),
            supplementalSerial: sanitizeIdentifier(supplementalMetadata.cameraSerial),
            nativeFallbackMake: nativeFields?.make,
            nativeFallbackModel: nativeFields?.model ?? nativeFields?.uniqueCameraModel
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
                cameraMake: resolvedIdentity.make,
                cameraModel: resolvedIdentity.model,
                cameraSerial: resolvedIdentity.serial,
                cameraEvidence: resolvedIdentity.evidence
            )
        }

        if let createDateRaw,
           let parsed = parser.parse(createDateRaw)
        {
            return PhotoMetadata(
                captureDateTime: parsed,
                captureDateSource: .createDate,
                cameraMake: resolvedIdentity.make,
                cameraModel: resolvedIdentity.model,
                cameraSerial: resolvedIdentity.serial,
                cameraEvidence: resolvedIdentity.evidence
            )
        }

        return PhotoMetadata(
            captureDateTime: nil,
            captureDateSource: .missing,
            cameraMake: resolvedIdentity.make,
            cameraModel: resolvedIdentity.model,
            cameraSerial: resolvedIdentity.serial,
            cameraEvidence: resolvedIdentity.evidence
        )
    }

    private func serialCandidates(exif: [String: String], tiff: [String: String]) -> [CameraIdentityCandidate] {
        [
            CameraIdentityCandidate(
                value: sanitizeIdentifier(exif["BodySerialNumber"]),
                source: .exifBodySerial
            ),
            CameraIdentityCandidate(
                value: sanitizeIdentifier(exif["SerialNumber"]),
                source: .exifSerial
            ),
            CameraIdentityCandidate(
                value: sanitizeIdentifier(exif["CameraSerialNumber"]),
                source: .exifCameraSerial
            ),
            CameraIdentityCandidate(
                value: sanitizeIdentifier(exif["InternalSerialNumber"]),
                source: .exifInternalSerial
            ),
            CameraIdentityCandidate(
                value: sanitizeIdentifier(tiff["SerialNumber"]),
                source: .tiffSerial
            ),
        ]
    }

    private func nativeSerialCandidates(_ fields: ExifIFDFields?) -> [CameraIdentityCandidate] {
        [CameraIdentityCandidate(value: sanitizeIdentifier(fields?.serial), source: .embeddedExifSerial)]
    }

    private func shouldReadSupplementalMetadata(forPrimaryModel model: String?) -> Bool {
        guard let model else {
            return true
        }

        return isOpaqueModelCode(model)
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
    private let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

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

        return parseDateTimeWithoutTimeZone(value)
    }

    private func parseDateTimeWithoutTimeZone(_ value: String) -> Date? {
        // Parse "yyyy:MM:dd HH:mm:ss" by components instead of DateFormatter so
        // local clock times inside DST spring-forward gaps still resolve.
        let bytes = Array(value.utf8)
        guard bytes.count == 19,
              bytes[4] == 0x3A,
              bytes[7] == 0x3A,
              bytes[10] == 0x20,
              bytes[13] == 0x3A,
              bytes[16] == 0x3A else {
            return nil
        }

        guard let year = parseASCIIInt(bytes[0..<4]),
              let month = parseASCIIInt(bytes[5..<7]),
              let day = parseASCIIInt(bytes[8..<10]),
              let hour = parseASCIIInt(bytes[11..<13]),
              let minute = parseASCIIInt(bytes[14..<16]),
              let second = parseASCIIInt(bytes[17..<19]) else {
            return nil
        }

        guard year >= 1,
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        guard isValidCalendarDay(year: year, month: month, day: day) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let components = DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        return calendar.date(from: components)
    }

    private func parseASCIIInt(_ slice: ArraySlice<UInt8>) -> Int? {
        var result = 0
        for byte in slice {
            guard byte >= 0x30, byte <= 0x39 else {
                return nil
            }
            result = result * 10 + Int(byte - 0x30)
        }
        return result
    }

    private func isValidCalendarDay(year: Int, month: Int, day: Int) -> Bool {
        let monthStartComponents = DateComponents(year: year, month: month, day: 1, hour: 12)
        guard let firstOfMonth = Self.utcGregorianCalendar.date(from: monthStartComponents),
              let validDayRange = Self.utcGregorianCalendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return false
        }
        return validDayRange.contains(day)
    }

    private static let utcGregorianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let formattersWithTimeZone: [DateFormatter] = [
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ssXXXXX", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ss XXX", timeZone: TimeZone(secondsFromGMT: 0)),
        buildDateFormatter(format: "yyyy:MM:dd HH:mm:ssZ", timeZone: TimeZone(secondsFromGMT: 0)),
    ]

    private static func buildDateFormatter(format: String, timeZone: TimeZone?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }
}
