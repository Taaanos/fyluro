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

        let dateTimeOriginalRaw = exif[stringKey(kCGImagePropertyExifDateTimeOriginal)]
        let createDateRaw = exif[stringKey(kCGImagePropertyExifDateTimeDigitized)] ?? tiff[stringKey(kCGImagePropertyTIFFDateTime)]

        let parser = ExifDateParser()
        if let dateTimeOriginalRaw,
           let parsed = parser.parse(dateTimeOriginalRaw)
        {
            return PhotoMetadata(
                captureDateTime: parsed,
                captureDateSource: .dateTimeOriginal,
                cameraMake: sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFMake)]),
                cameraModel: sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFModel)]),
                cameraSerial: extractSerial(exif: exif, tiff: tiff)
            )
        }

        if let createDateRaw,
           let parsed = parser.parse(createDateRaw)
        {
            return PhotoMetadata(
                captureDateTime: parsed,
                captureDateSource: .createDate,
                cameraMake: sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFMake)]),
                cameraModel: sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFModel)]),
                cameraSerial: extractSerial(exif: exif, tiff: tiff)
            )
        }

        return PhotoMetadata(
            captureDateTime: nil,
            captureDateSource: .missing,
            cameraMake: sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFMake)]),
            cameraModel: sanitizeIdentifier(tiff[stringKey(kCGImagePropertyTIFFModel)]),
            cameraSerial: extractSerial(exif: exif, tiff: tiff)
        )
    }

    private func extractSerial(exif: [String: String], tiff: [String: String]) -> String? {
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

        return nil
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
