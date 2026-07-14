import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RollKeepCore

final class ImageIOPhotoMetadataWriterTests: RuntimeFixtureTestCase {
    func testWriteRoundTripsMakeModelDateFilmStockAndISO() throws {
        let photoURL = tempRoot.appendingPathComponent("roll/photo.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTinyImage(to: photoURL, utType: .jpeg, tiffMake: "Canon", tiffModel: "EOS 5D Mark IV")

        let override = FilmModeOverride(year: 1998, month: 7, camera: "Pentax K1000", filmStock: "Kodak Gold 200", iso: 200)
        try ImageIOPhotoMetadataWriter().write(override: override, to: photoURL)

        let metadata = ImageIOPhotoMetadataExtractor().extract(from: photoURL)
        XCTAssertNil(metadata.cameraMake)
        XCTAssertEqual(metadata.cameraModel, "Pentax K1000")
        XCTAssertEqual(metadata.captureDateSource, .dateTimeOriginal)

        // EXIF DateTimeOriginal carries no timezone; ImageIOPhotoMetadataExtractor's
        // ExifDateParser assumes local wall-clock time when parsing it back, so
        // decode using the same convention here rather than UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: try XCTUnwrap(metadata.captureDateTime)
        )
        XCTAssertEqual(components.year, 1998)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 1)

        guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        else {
            XCTFail("Expected an EXIF dictionary to be present after writing")
            return
        }
        XCTAssertEqual(exif[kCGImagePropertyExifUserComment as String] as? String, "Kodak Gold 200")
        XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [200])
    }

    func testWriteOmitsOptionalFieldsWhenNotProvided() throws {
        let photoURL = tempRoot.appendingPathComponent("roll/photo-no-extras.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTinyImage(to: photoURL, utType: .jpeg, tiffMake: "Canon", tiffModel: "EOS 5D Mark IV")

        let override = FilmModeOverride(year: 2005, month: 11, camera: "Contax T2", filmStock: nil, iso: nil)
        try ImageIOPhotoMetadataWriter().write(override: override, to: photoURL)

        let metadata = ImageIOPhotoMetadataExtractor().extract(from: photoURL)
        XCTAssertEqual(metadata.cameraModel, "Contax T2")
    }

    func testWriteThrowsForUnsupportedImageTypeAndLeavesFileUntouched() throws {
        let fileURL = tempRoot.appendingPathComponent("roll/photo.gif", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTinyImage(to: fileURL, utType: .gif, tiffMake: nil, tiffModel: nil)
        let originalData = try Data(contentsOf: fileURL)

        let override = FilmModeOverride(year: 2000, month: 1, camera: "Test Camera", filmStock: nil, iso: nil)
        XCTAssertThrowsError(try ImageIOPhotoMetadataWriter().write(override: override, to: fileURL)) { error in
            guard case ImageIOPhotoMetadataWriterError.unsupportedImageType = error else {
                XCTFail("Expected unsupportedImageType, got \(error)")
                return
            }
        }

        let afterData = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalData, afterData)
    }

    func testWriteThrowsForUnreadableSourceAndLeavesFileUntouched() throws {
        let fileURL = tempRoot.appendingPathComponent("roll/not-an-image.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x00, count: 32).write(to: fileURL)
        let originalData = try Data(contentsOf: fileURL)

        let override = FilmModeOverride(year: 2000, month: 1, camera: "Test Camera", filmStock: nil, iso: nil)
        // ImageIO may treat this as either an unrecognized container (unreadableSource)
        // or a recognized-but-unsupported one (unsupportedImageType) depending on how
        // lazily it inspects the bytes; either way it must reject, not crash or write.
        XCTAssertThrowsError(try ImageIOPhotoMetadataWriter().write(override: override, to: fileURL)) { error in
            switch error {
            case ImageIOPhotoMetadataWriterError.unreadableSource, ImageIOPhotoMetadataWriterError.unsupportedImageType:
                break
            default:
                XCTFail("Expected unreadableSource or unsupportedImageType, got \(error)")
            }
        }

        let afterData = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalData, afterData)
    }

    private func writeTinyImage(
        to fileURL: URL,
        utType: UTType,
        tiffMake: String?,
        tiffModel: String?
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "ImageIOPhotoMetadataWriterTests", code: 1)
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ImageIOPhotoMetadataWriterTests", code: 2)
        }

        var tiffDictionary: [String: Any] = [:]
        if let tiffMake {
            tiffDictionary[kCGImagePropertyTIFFMake as String] = tiffMake
        }
        if let tiffModel {
            tiffDictionary[kCGImagePropertyTIFFModel as String] = tiffModel
        }

        var properties: [String: Any] = [:]
        if utType == .jpeg {
            properties[kCGImagePropertyExifDictionary as String] = [
                kCGImagePropertyExifDateTimeOriginal as String: "2025:03:09 13:13:11",
            ]
        }
        if !tiffDictionary.isEmpty {
            properties[kCGImagePropertyTIFFDictionary as String] = tiffDictionary
        }

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            utType.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ImageIOPhotoMetadataWriterTests", code: 3)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageIOPhotoMetadataWriterTests", code: 4)
        }
    }
}
