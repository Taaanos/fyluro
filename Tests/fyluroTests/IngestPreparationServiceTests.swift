import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FyluroCore

final class IngestPreparationServiceTests: RuntimeFixtureTestCase {
    override class func setUp() {
        super.setUp()
        CameraCatalogTestIsolation.useEmptyCatalog()
    }

    func testPrepareUsesXMLSidecarFallbackAndPlansCompanionTransfer() throws {
        let videoURL = try createBinaryFile(path: "PRIVATE/20251219_C3501.MP4", bytes: 256)
        try createTextFile(
            path: "PRIVATE/20251219_C3501M01.XML",
            contents: """
            <NonRealTimeMeta>
            <CreationDate value=\"2024-06-21T22:05:01+01:00\"/>
            <Device manufacturer=\"Sony\" modelName=\"ILCE-7CM2\" serialNo=\"4294967295\"/>
            </NonRealTimeMeta>
            """
        )
        try setModificationDate(Date(timeIntervalSince1970: 1_719_009_900), for: videoURL)

        let preparation = try IngestPreparationService().prepare(
            sourceRoot: tempRoot,
            destRoot: tempRoot,
            sessionID: "session-video-sidecar-xml"
        )

        let candidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "PRIVATE/20251219_C3501.MP4"
        })
        let metadata = try XCTUnwrap(candidate.videoMetadata)
        XCTAssertEqual(metadata.captureDateSource, .sidecarMetadata)
        XCTAssertEqual(preparation.cameraInference(for: candidate).cameraLabel, "ilce-7cm2")
        XCTAssertEqual(candidate.sidecars.map(\.relativePath), ["PRIVATE/20251219_C3501M01.XML"])

        let plannedByPath = Dictionary(uniqueKeysWithValues: (preparation.plan?.files ?? []).map { ($0.candidate.relativePath, $0) })
        XCTAssertEqual(plannedByPath.count, 2)
        XCTAssertEqual(plannedByPath["PRIVATE/20251219_C3501.MP4"]?.cameraLabel, "ilce-7cm2")
        XCTAssertEqual(plannedByPath["PRIVATE/20251219_C3501M01.XML"]?.cameraLabel, "ilce-7cm2")
        XCTAssertTrue(plannedByPath["PRIVATE/20251219_C3501M01.XML"]?.finalPath.hasSuffix("/Videos/20251219_C3501M01.XML") ?? false)
    }

    func testPreparePlansPhotoSidecarsIntoMatchingCompressionBucketsAndKeepsVideoUnsplit() throws {
        let rawPhoto = try createBinaryFile(path: "DCIM/IMG_RAW.CR3", bytes: 64)
        _ = try createBinaryFile(path: "DCIM/IMG_RAW.XMP", bytes: 16)

        let standardPhoto = try createBinaryFile(path: "DCIM/IMG_STD.JPG", bytes: 64)
        _ = try createBinaryFile(path: "DCIM/IMG_STD.XMP", bytes: 16)

        let video = try createBinaryFile(path: "PRIVATE/VID_0001.MP4", bytes: 64)
        _ = try createBinaryFile(path: "PRIVATE/VID_0001.XML", bytes: 16)

        let captureDate = Date(timeIntervalSince1970: 1_708_516_800)
        try setModificationDate(captureDate, for: rawPhoto)
        try setModificationDate(captureDate, for: standardPhoto)
        try setModificationDate(captureDate, for: video)

        let preparation = try IngestPreparationService(
            destinationPathPlanner: DestinationPathPlanner(pathScheme: ImportPathScheme(
                chronologicalLayout: .yearYearMonthCompact,
                includeCameraFolder: true,
                splitPhotoCompression: true
            ))
        ).prepare(
            sourceRoot: tempRoot,
            destRoot: tempRoot,
            sessionID: "session-compression-sidecars"
        )

        let plannedByPath = Dictionary(uniqueKeysWithValues: (preparation.plan?.files ?? []).map { ($0.candidate.relativePath, $0) })

        XCTAssertTrue(plannedByPath["DCIM/IMG_RAW.CR3"]?.finalPath.contains("/Photos/RAW/") ?? false)
        XCTAssertTrue(plannedByPath["DCIM/IMG_RAW.XMP"]?.finalPath.contains("/Photos/RAW/") ?? false)

        XCTAssertTrue(plannedByPath["DCIM/IMG_STD.JPG"]?.finalPath.contains("/Photos/Non-RAW/") ?? false)
        XCTAssertTrue(plannedByPath["DCIM/IMG_STD.XMP"]?.finalPath.contains("/Photos/Non-RAW/") ?? false)

        XCTAssertTrue(plannedByPath["PRIVATE/VID_0001.MP4"]?.finalPath.contains("/Videos/VID_0001.MP4") ?? false)
        XCTAssertTrue(plannedByPath["PRIVATE/VID_0001.XML"]?.finalPath.contains("/Videos/VID_0001.XML") ?? false)
        XCTAssertFalse(plannedByPath["PRIVATE/VID_0001.XML"]?.finalPath.contains("/RAW/") ?? true)
        XCTAssertFalse(plannedByPath["PRIVATE/VID_0001.XML"]?.finalPath.contains("/Non-RAW/") ?? true)
    }

    func testPrepareResolvesSameBasenameAcrossDifferentDirsWithDeterministicSuffix() throws {
        let first = try createBinaryFile(path: "dir1/IMG_6481.jpg", bytes: 100)
        let second = try createBinaryFile(path: "dir2/IMG_6481.JPG", bytes: 120)
        let captureDate = Date(timeIntervalSince1970: 1_528_255_200)
        try setModificationDate(captureDate, for: first)
        try setModificationDate(captureDate, for: second)

        let preparation = try IngestPreparationService(
            sourceScanner: SourceScanner(
                photoMetadataExtractor: FilenamePhotoMetadataExtractor(
                    metadataByFilename: [
                        "IMG_6481.jpg": PhotoMetadata(
                            captureDateTime: captureDate,
                            captureDateSource: .dateTimeOriginal,
                            cameraMake: "Apple",
                            cameraModel: "iPhone 7 Plus",
                            cameraSerial: nil
                        ),
                        "IMG_6481.JPG": PhotoMetadata(
                            captureDateTime: captureDate,
                            captureDateSource: .dateTimeOriginal,
                            cameraMake: "Apple",
                            cameraModel: "iPhone 7 Plus",
                            cameraSerial: nil
                        ),
                    ]
                ),
                videoMetadataExtractor: FilenameVideoMetadataExtractor(metadataByFilename: [:])
            )
        ).prepare(
            sourceRoot: tempRoot,
            destRoot: tempRoot,
            sessionID: "session-case-collision"
        )

        let planned = preparation.plan?.files ?? []
        XCTAssertEqual(planned.count, 2)
        XCTAssertEqual(planned.filter { $0.disposition == .duplicateNotCopied }.count, 0)
        XCTAssertEqual(planned.filter(\.collisionResolved).count, 1)

        let finalPaths = Set(planned.map(\.finalPath))
        XCTAssertEqual(finalPaths.count, 2)
        XCTAssertTrue(finalPaths.contains { $0.hasSuffix("/2018/201806/iphone-7-plus/Photos/IMG_6481.jpg") })
        XCTAssertTrue(finalPaths.contains { $0.hasSuffix("/2018/201806/iphone-7-plus/Photos/IMG_6481-1.JPG") })
    }

    func testFilmModeOverrideReplacesPhotoMetadataAndDrivesFolderPlacement() throws {
        let photoURL = tempRoot.appendingPathComponent("DCIM/IMG_9001.JPG", isDirectory: false)
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTinyJPEG(to: photoURL, tiffModel: "Canon EOS 5D Mark IV", exifBodySerial: "DSLR123")

        let override = FilmModeOverride(year: 1998, month: 7, camera: "Pentax K1000", filmStock: "Kodak Gold 200", iso: 200, creator: nil, copyright: nil)

        let preparation = try IngestPreparationService().prepare(
            sourceRoot: tempRoot,
            destRoot: tempRoot,
            sessionID: "session-film-mode",
            filmModeOverride: override
        )

        let candidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "DCIM/IMG_9001.JPG"
        })
        let metadata = try XCTUnwrap(candidate.photoMetadata)
        XCTAssertEqual(metadata.captureDateSource, .filmModeOverride)
        XCTAssertNil(metadata.cameraMake)
        XCTAssertEqual(metadata.cameraModel, "Pentax K1000")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: try XCTUnwrap(metadata.captureDateTime)
        )
        XCTAssertEqual(components.year, 1998)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 1)

        let planned = try XCTUnwrap(preparation.plan?.files.first {
            $0.candidate.relativePath == "DCIM/IMG_9001.JPG"
        })
        XCTAssertEqual(planned.cameraLabel, "pentax-k1000")
        XCTAssertTrue(planned.finalPath.contains("/1998/199807/"))
        XCTAssertTrue(planned.finalPath.contains("/pentax-k1000/"))
        XCTAssertEqual(preparation.cameraInference(for: candidate).cameraLabel, "pentax-k1000")
    }

    func testFilmModeOverrideLeavesVideoCandidatesUntouched() throws {
        let photoURL = tempRoot.appendingPathComponent("DCIM/IMG_9002.JPG", isDirectory: false)
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTinyJPEG(to: photoURL, tiffModel: "Canon EOS 5D Mark IV", exifBodySerial: "DSLR123")

        let videoURL = try createBinaryFile(path: "PRIVATE/CLIP_0001.MOV", bytes: 64)
        let videoDate = Date(timeIntervalSince1970: 1_708_516_800)
        try setModificationDate(videoDate, for: videoURL)

        let override = FilmModeOverride(year: 1998, month: 7, camera: "Pentax K1000", filmStock: nil, iso: nil, creator: nil, copyright: nil)

        let preparation = try IngestPreparationService(
            sourceScanner: SourceScanner(
                photoMetadataExtractor: ImageIOPhotoMetadataExtractor(),
                videoMetadataExtractor: FilenameVideoMetadataExtractor(
                    metadataByFilename: [
                        "CLIP_0001.MOV": VideoMetadata(
                            captureDateTime: videoDate,
                            captureDateSource: .creationTime,
                            usedFallback: false,
                            cameraMake: "Sony",
                            cameraModel: "FX3",
                            cameraSerial: nil
                        ),
                    ]
                )
            )
        ).prepare(
            sourceRoot: tempRoot,
            destRoot: tempRoot,
            sessionID: "session-film-mode-video-untouched",
            filmModeOverride: override
        )

        let videoCandidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "PRIVATE/CLIP_0001.MOV"
        })
        XCTAssertEqual(videoCandidate.videoMetadata?.cameraModel, "FX3")
        XCTAssertEqual(preparation.cameraInference(for: videoCandidate).cameraLabel, "fx3")

        let photoCandidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "DCIM/IMG_9002.JPG"
        })
        XCTAssertEqual(photoCandidate.photoMetadata?.cameraModel, "Pentax K1000")
    }

    func testFilmModeOverrideAppliesToPhotoSidecars() throws {
        let photoURL = tempRoot.appendingPathComponent("DCIM/IMG_9003.JPG", isDirectory: false)
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTinyJPEG(to: photoURL, tiffModel: "Canon EOS 5D Mark IV", exifBodySerial: "DSLR123")
        _ = try createBinaryFile(path: "DCIM/IMG_9003.XMP", bytes: 16)

        let override = FilmModeOverride(year: 2001, month: 3, camera: "Nikon FM2", filmStock: "Fuji Superia 400", iso: 400, creator: nil, copyright: nil)

        let preparation = try IngestPreparationService().prepare(
            sourceRoot: tempRoot,
            destRoot: tempRoot,
            sessionID: "session-film-mode-sidecar",
            filmModeOverride: override
        )

        let plannedByPath = Dictionary(
            uniqueKeysWithValues: (preparation.plan?.files ?? []).map { ($0.candidate.relativePath, $0) }
        )
        XCTAssertEqual(plannedByPath["DCIM/IMG_9003.JPG"]?.cameraLabel, "nikon-fm2")
        XCTAssertEqual(plannedByPath["DCIM/IMG_9003.XMP"]?.cameraLabel, "nikon-fm2")
        XCTAssertTrue(plannedByPath["DCIM/IMG_9003.JPG"]?.finalPath.contains("/2001/200103/") ?? false)
        XCTAssertTrue(plannedByPath["DCIM/IMG_9003.XMP"]?.finalPath.contains("/2001/200103/") ?? false)
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
            throw NSError(domain: "IngestPreparationServiceTests", code: 1)
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else {
            throw NSError(domain: "IngestPreparationServiceTests", code: 2)
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
            throw NSError(domain: "IngestPreparationServiceTests", code: 3)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "IngestPreparationServiceTests", code: 4)
        }
    }
}

private struct FilenamePhotoMetadataExtractor: PhotoMetadataExtracting {
    let metadataByFilename: [String: PhotoMetadata]

    func extract(from fileURL: URL) -> PhotoMetadata {
        metadataByFilename[fileURL.lastPathComponent] ?? PhotoMetadata(
            captureDateTime: nil,
            captureDateSource: .missing,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
    }
}

private struct FilenameVideoMetadataExtractor: VideoMetadataExtracting {
    let metadataByFilename: [String: VideoMetadata]

    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        metadataByFilename[fileURL.lastPathComponent] ?? VideoMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            usedFallback: true,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
    }
}
