import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RollKeepCore

final class ImageIOPhotoMetadataExtractorTests: XCTestCase {
    private let extractor = ImageIOPhotoMetadataExtractor()

    func testExtractPrefersSupplementalProductNameForOpaquePrimaryModelCode() throws {
        let fileURL = try makeTestJPEG(
            tiffModel: "FC8482",
            exifBodySerial: "TESTSERIAL0001",
            supplementalXMP: """
            <rdf:Description xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/" drone-dji:ProductName="Mini4 Pro" drone-dji:CameraSerialNumber="TESTSERIAL0001" />
            """
        )

        let metadata = extractor.extract(from: fileURL)

        XCTAssertEqual(metadata.cameraMake, "DJI")
        XCTAssertEqual(metadata.cameraModel, "Mini4 Pro")
        XCTAssertEqual(metadata.cameraSerial, "TESTSERIAL0001")
        XCTAssertEqual(metadata.cameraEvidence?.model.source, .xmpProductName)
        XCTAssertEqual(metadata.cameraEvidence?.serial.source, .exifBodySerial)
    }

    func testExtractKeepsPrimaryModelWhenItIsAlreadyDescriptive() throws {
        let fileURL = try makeTestJPEG(
            tiffModel: "EOS R5",
            exifBodySerial: "ABC12345",
            supplementalXMP: """
            <rdf:Description xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/" drone-dji:ProductName="Mini4 Pro" />
            """
        )

        let metadata = extractor.extract(from: fileURL)

        XCTAssertEqual(metadata.cameraModel, "EOS R5")
        XCTAssertEqual(metadata.cameraSerial, "ABC12345")
    }

    func testExtractFallsBackToSupplementalSerialWhenExifSerialMissing() throws {
        let fileURL = try makeTestJPEG(
            tiffModel: "FC8482",
            exifBodySerial: nil,
            supplementalXMP: """
            <rdf:Description xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/" drone-dji:ProductName="Mini4 Pro" drone-dji:CameraSerialNumber="TESTSERIAL0001" />
            """
        )

        let metadata = extractor.extract(from: fileURL)

        XCTAssertEqual(metadata.cameraModel, "Mini4 Pro")
        XCTAssertEqual(metadata.cameraSerial, "TESTSERIAL0001")
    }

    private func makeTestJPEG(
        tiffModel: String,
        exifBodySerial: String?,
        supplementalXMP: String?
    ) throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-imageio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("sample.jpg", isDirectory: false)
        try writeTinyJPEG(to: fileURL, tiffModel: tiffModel, exifBodySerial: exifBodySerial)

        if let supplementalXMP {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                XCTFail("Unable to open test JPEG for writing supplemental metadata.")
                return fileURL
            }
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(Data(supplementalXMP.utf8))
        }

        return fileURL
    }

    private func writeTinyJPEG(to fileURL: URL, tiffModel: String, exifBodySerial: String?) throws {
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
            throw NSError(domain: "ImageIOPhotoMetadataExtractorTests", code: 1)
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ImageIOPhotoMetadataExtractorTests", code: 2)
        }

        let exifDictionary: [String: Any?] = [
            kCGImagePropertyExifDateTimeOriginal as String: "2025:03:09 13:13:11",
            kCGImagePropertyExifBodySerialNumber as String: exifBodySerial,
        ]
        .compactMapValues { $0 }

        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "DJI",
                kCGImagePropertyTIFFModel as String: tiffModel,
                kCGImagePropertyTIFFDateTime as String: "2025:03:09 16:43:06",
            ],
            kCGImagePropertyExifDictionary as String: exifDictionary,
        ]

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ImageIOPhotoMetadataExtractorTests", code: 3)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageIOPhotoMetadataExtractorTests", code: 4)
        }
    }
}
