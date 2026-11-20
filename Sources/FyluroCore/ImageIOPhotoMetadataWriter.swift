import Foundation
import ImageIO

public enum ImageIOPhotoMetadataWriterError: Error, Equatable {
    case unreadableSource
    case unsupportedImageType(String)
    case destinationCreationFailed
    case finalizeFailed
}

/// Writes film-mode override metadata (declared month/year, camera, and a
/// set of optional descriptive fields) into a photo's EXIF/TIFF properties.
/// Only ever called on a staged copy — never the original source file.
public struct ImageIOPhotoMetadataWriter {
    private static let writableUTIs: Set<String> = [
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.png",
    ]

    public init() {}

    public func write(override: FilmModeOverride, to fileURL: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw ImageIOPhotoMetadataWriterError.unreadableSource
        }
        guard let uti = CGImageSourceGetType(imageSource) as String?,
              Self.writableUTIs.contains(uti)
        else {
            let uti = (CGImageSourceGetType(imageSource) as String?) ?? "unknown"
            throw ImageIOPhotoMetadataWriterError.unsupportedImageType(uti)
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]) ?? [:]
        var tiffDictionary = (properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        var exifDictionary = (properties[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]

        // EXIF DateTimeOriginal has no timezone; readers assume local wall-clock
        // time. Format the declared year/month directly rather than round-tripping
        // through a Date/timezone conversion, so every reader recovers the same
        // year and month regardless of its own timezone.
        let dateString = String(format: "%04d:%02d:01 00:00:00", override.year, override.month)
        // Empty (not removed) so it overrides the digitizing camera's Make that
        // CGImageDestinationAddImageFromSource would otherwise carry forward.
        tiffDictionary[kCGImagePropertyTIFFMake as String] = ""
        tiffDictionary[kCGImagePropertyTIFFModel as String] = override.camera
        tiffDictionary[kCGImagePropertyTIFFDateTime as String] = dateString
        exifDictionary[kCGImagePropertyExifDateTimeOriginal as String] = dateString
        exifDictionary[kCGImagePropertyExifDateTimeDigitized as String] = dateString
        if let filmStock = override.filmStock {
            exifDictionary[kCGImagePropertyExifUserComment as String] = filmStock
        }
        if let iso = override.iso {
            exifDictionary[kCGImagePropertyExifISOSpeedRatings as String] = [iso]
        }
        if let lens = override.lens {
            exifDictionary[kCGImagePropertyExifLensModel as String] = lens
        }
        if let shotAtISO = override.shotAtISO {
            exifDictionary[kCGImagePropertyExifExposureIndex as String] = Double(shotAtISO)
        }
        if let developmentNotes = override.developmentNotes {
            tiffDictionary[kCGImagePropertyTIFFImageDescription as String] = developmentNotes
        }
        if let scannerSetup = override.scannerSetup {
            tiffDictionary[kCGImagePropertyTIFFSoftware as String] = scannerSetup
        }
        if let creator = override.creator {
            tiffDictionary[kCGImagePropertyTIFFArtist as String] = creator
        }
        if let copyright = override.copyright {
            tiffDictionary[kCGImagePropertyTIFFCopyright as String] = copyright
        }

        properties[kCGImagePropertyTIFFDictionary as String] = tiffDictionary
        properties[kCGImagePropertyExifDictionary as String] = exifDictionary

        let tempURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).filmmode-tmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, uti as CFString, 1, nil) else {
            throw ImageIOPhotoMetadataWriterError.destinationCreationFailed
        }

        CGImageDestinationAddImageFromSource(destination, imageSource, 0, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageIOPhotoMetadataWriterError.finalizeFailed
        }

        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }
}
