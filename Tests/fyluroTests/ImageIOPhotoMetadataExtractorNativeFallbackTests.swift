import Foundation
import XCTest
@testable import FyluroCore

/// Integration coverage for the M2 native-fallback path added to
/// `ImageIOPhotoMetadataExtractor`: a bare TIFF-shaped byte blob is not a
/// file ImageIO can decode as an image (no pixel data at all), so
/// `CGImageSourceCreateWithURL`/`CGImageSourceCopyPropertiesAtIndex`
/// reliably fail on it in this environment, exercising the "ImageIO
/// couldn't open this at all" branch end-to-end -- including that the
/// resulting evidence correctly records the native-fallback source rather
/// than misattributing it to `.tiffMake`/`.tiffModel`.
final class ImageIOPhotoMetadataExtractorNativeFallbackTests: XCTestCase {
    private var tempDirectory: URL!
    private let extractor = ImageIOPhotoMetadataExtractor()

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imageio-native-fallback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testResolvesIdentityFromBareTIFFImageIOCannotDecodeAndRecordsNativeEvidenceSource() throws {
        let tiff = minimalTIFF(make: "NIKON CORPORATION", model: "NIKON D850", serial: "SN0099")
        let fileURL = try writeFile(Data(tiff), name: "sample.nef")

        let metadata = extractor.extract(from: fileURL)

        XCTAssertEqual(metadata.cameraMake, "NIKON CORPORATION")
        XCTAssertEqual(metadata.cameraModel, "NIKON D850")
        XCTAssertEqual(metadata.cameraSerial, "SN0099")
        XCTAssertEqual(metadata.cameraEvidence?.make.source, .embeddedExifMake)
        XCTAssertEqual(metadata.cameraEvidence?.model.source, .embeddedExifModel)
        XCTAssertEqual(metadata.cameraEvidence?.serial.source, .embeddedExifSerial)
        XCTAssertEqual(metadata.captureDateSource, .missing, "M2 is identity-only; native fallback does not invent a date")
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    private func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    /// Builds a minimal little-endian standard-magic TIFF with Make (0x010F),
    /// Model (0x0110), and BodySerialNumber (0xA431, via an ExifIFD pointed
    /// to by 0x8769) -- mirrors ExifIFDFieldReaderTests' builder pattern.
    private func minimalTIFF(make: String?, model: String?, serial: String?) -> [UInt8] {
        var ifd0Entries: [(tag: UInt16, value: [UInt8])] = []
        var tail: [UInt8] = []

        let hasExifIFD = serial != nil
        let entryCount = (make != nil ? 1 : 0) + (model != nil ? 1 : 0) + (hasExifIFD ? 1 : 0)
        var tailOffset = 8 + 2 + 12 * entryCount + 4

        if let make {
            let bytes = Array(make.utf8) + [0x00]
            ifd0Entries.append((0x010F, u16(0x010F) + u16(2) + u32(UInt32(bytes.count)) + u32(UInt32(tailOffset))))
            tail += bytes
            tailOffset += bytes.count
        }
        if let model {
            let bytes = Array(model.utf8) + [0x00]
            ifd0Entries.append((0x0110, u16(0x0110) + u16(2) + u32(UInt32(bytes.count)) + u32(UInt32(tailOffset))))
            tail += bytes
            tailOffset += bytes.count
        }

        var exifIFDBytes: [UInt8] = []
        if let serial {
            // ExifIFD sits right after ifd0's tail.
            let exifIFDOffset = tailOffset
            ifd0Entries.append((0x8769, u16(0x8769) + u16(4) + u32(1) + u32(UInt32(exifIFDOffset))))

            let serialBytes = Array(serial.utf8) + [0x00]
            let exifTailOffset = exifIFDOffset + 2 + 12 * 1 + 4
            exifIFDBytes = u16(1) + u16(0xA431) + u16(2) + u32(UInt32(serialBytes.count))
                + u32(UInt32(exifTailOffset)) + u32(0) + serialBytes
        }

        var bytes: [UInt8] = [0x49, 0x49] + u16(0x2A) + u32(8)
        bytes += u16(UInt16(entryCount))
        for entry in ifd0Entries { bytes += entry.value }
        bytes += u32(0)
        bytes += tail
        bytes += exifIFDBytes
        return bytes
    }

    private func writeFile(_ data: Data, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
