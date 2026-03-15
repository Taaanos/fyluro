import Foundation
import XCTest
@testable import RollKeepCore

final class SourceScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testScanExcludesHiddenAndSystemEntriesAndCountsMedia() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/clip001.MOV", bytes: 20)
        try createFile(path: ".Trashes/hidden.jpg", bytes: 30)
        try createFile(path: "System Volume Information/sys.mp4", bytes: 40)
        try createFile(path: "docs/readme.txt", bytes: 50)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.photoCount, 1)
        XCTAssertEqual(summary.videoCount, 1)
        XCTAssertEqual(summary.photoBytes, 10)
        XCTAssertEqual(summary.videoBytes, 20)
        XCTAssertEqual(summary.candidates.count, 2)

        let orderedRelativePaths = summary.candidates.map(\.relativePath)
        XCTAssertEqual(orderedRelativePaths, ["DCIM/100MEDIA/clip001.MOV", "DCIM/100MEDIA/IMG_0001.JPG"])
    }

    func testScanProducesDeterministicOrder() throws {
        try createFile(path: "DCIM/B/IMG_10.JPG", bytes: 1)
        try createFile(path: "DCIM/A/IMG_2.JPG", bytes: 1)
        try createFile(path: "DCIM/A/IMG_1.JPG", bytes: 1)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.candidates.map(\.relativePath), [
            "DCIM/A/IMG_1.JPG",
            "DCIM/A/IMG_2.JPG",
            "DCIM/B/IMG_10.JPG",
        ])
    }

    func testScanCollectsMtimeAndSize() throws {
        let fileURL = try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let explicitMtime = Date(timeIntervalSince1970: 1_704_067_200)
        try FileManager.default.setAttributes([.modificationDate: explicitMtime], ofItemAtPath: fileURL.path)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)
        let item = try XCTUnwrap(summary.candidates.first)

        XCTAssertEqual(item.relativePath, "PRIVATE/clip.MP4")
        XCTAssertEqual(item.mediaType, .video)
        XCTAssertEqual(item.sizeBytes, 123)
        XCTAssertEqual(item.mtime.timeIntervalSince1970, explicitMtime.timeIntervalSince1970, accuracy: 1)
    }

    func testScanCapturesVideoCreationTimeFromMetadataExtractor() throws {
        try createFile(path: "PRIVATE/clip.MP4", bytes: 123)
        let creationDate = Date(timeIntervalSince1970: 1_704_100_000)

        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: StubVideoMetadataExtractor(
                metadataByFilename: [
                    "clip.MP4": VideoMetadata(
                        captureDateTime: creationDate,
                        captureDateSource: .creationTime,
                        usedFallback: false
                    ),
                ]
            )
        )

        let summary = try scanner.scan(sourceRoot: tempRoot)
        let item = try XCTUnwrap(summary.candidates.first)
        let metadata = try XCTUnwrap(item.videoMetadata)

        XCTAssertEqual(metadata.captureDateTime, creationDate)
        XCTAssertEqual(metadata.captureDateSource, .creationTime)
        XCTAssertFalse(metadata.usedFallback)
    }

    func testPreviewScanSkipsVideoMetadataExtractorAndUsesMtimeFallback() throws {
        let fileURL = try createFile(path: "PRIVATE/clip.MP4", bytes: 123)
        let explicitMtime = Date(timeIntervalSince1970: 1_704_200_000)
        try FileManager.default.setAttributes([.modificationDate: explicitMtime], ofItemAtPath: fileURL.path)

        let videoExtractor = CountingVideoMetadataExtractor()
        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: videoExtractor
        )

        let summary = try scanner.scan(sourceRoot: tempRoot, mode: .preview)
        let item = try XCTUnwrap(summary.candidates.first)
        let metadata = try XCTUnwrap(item.videoMetadata)

        XCTAssertEqual(videoExtractor.callCount, 0)
        XCTAssertEqual(metadata.captureDateSource, .mtimeFallback)
        XCTAssertTrue(metadata.usedFallback)
        XCTAssertEqual(metadata.captureDateTime.timeIntervalSince1970, explicitMtime.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(metadata.cameraMake)
        XCTAssertNil(metadata.cameraModel)
        XCTAssertNil(metadata.cameraSerial)
    }

    func testDeepScanUsesVideoMetadataExtractor() throws {
        try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let videoExtractor = CountingVideoMetadataExtractor()
        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: videoExtractor
        )

        _ = try scanner.scan(sourceRoot: tempRoot, mode: .deep)
        XCTAssertEqual(videoExtractor.callCount, 1)
    }

    func testScanMarksVideoFallbackWhenCreationTimeMissing() throws {
        let fileURL = try createFile(path: "PRIVATE/clip.MP4", bytes: 123)
        let explicitMtime = Date(timeIntervalSince1970: 1_704_067_200)
        try FileManager.default.setAttributes([.modificationDate: explicitMtime], ofItemAtPath: fileURL.path)

        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: StubVideoMetadataExtractor(metadataByFilename: [:])
        )

        let summary = try scanner.scan(sourceRoot: tempRoot)
        let item = try XCTUnwrap(summary.candidates.first)
        let metadata = try XCTUnwrap(item.videoMetadata)

        XCTAssertEqual(metadata.captureDateSource, .mtimeFallback)
        XCTAssertTrue(metadata.usedFallback)
        XCTAssertEqual(metadata.captureDateTime.timeIntervalSince1970, explicitMtime.timeIntervalSince1970, accuracy: 1)
    }

    func testUnreadableSourceRootFails() throws {
        let fileURL = try createFile(path: "not-a-directory", bytes: 1)

        XCTAssertThrowsError(try SourceScanner().scan(sourceRoot: fileURL)) { error in
            guard case SourceScannerError.unreadableSourceRoot = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testScanFailsWhenEncounteringSymbolicLinkedFile() throws {
        let outsideFile = try createFile(path: "outside/secret.JPG", bytes: 16)
        let symlinkURL = tempRoot.appendingPathComponent("DCIM/100MEDIA/escape.JPG", isDirectory: false)
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: outsideFile.path
        )

        XCTAssertThrowsError(try SourceScanner().scan(sourceRoot: tempRoot)) { error in
            guard case .symbolicLinkDetected(let path) = error as? SourceScannerError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(
                URL(fileURLWithPath: path).standardizedFileURL.path,
                symlinkURL.standardizedFileURL.path
            )
        }
    }

    func testScanFailsWhenEncounteringSymbolicLinkedDirectory() throws {
        let outsideDir = tempRoot.appendingPathComponent("outside-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try createFile(path: "outside-dir/secret.JPG", bytes: 12)

        let symlinkURL = tempRoot.appendingPathComponent("DCIM/linkdir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: outsideDir.path
        )

        XCTAssertThrowsError(try SourceScanner().scan(sourceRoot: tempRoot)) { error in
            guard case .symbolicLinkDetected(let path) = error as? SourceScannerError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(
                URL(fileURLWithPath: path).standardizedFileURL.path,
                symlinkURL.standardizedFileURL.path
            )
        }
    }

    func testScanCapturesPhotoMetadataAndDateSourcePriority() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0100.JPG", bytes: 10)

        let exifDate = Date(timeIntervalSince1970: 1_735_600_000)
        let scanner = SourceScanner(photoMetadataExtractor: StubPhotoMetadataExtractor(
            metadataByFilename: [
                "IMG_0100.JPG": PhotoMetadata(
                    captureDateTime: exifDate,
                    captureDateSource: .dateTimeOriginal,
                    cameraMake: "Canon",
                    cameraModel: "EOS R5",
                    cameraSerial: "0920001234"
                ),
            ]
        ))

        let summary = try scanner.scan(sourceRoot: tempRoot)
        let photo = try XCTUnwrap(summary.candidates.first)
        let metadata = try XCTUnwrap(photo.photoMetadata)

        XCTAssertEqual(metadata.captureDateTime, exifDate)
        XCTAssertEqual(metadata.captureDateSource, .dateTimeOriginal)
        XCTAssertEqual(metadata.cameraMake, "Canon")
        XCTAssertEqual(metadata.cameraModel, "EOS R5")
        XCTAssertEqual(metadata.cameraSerial, "0920001234")
        XCTAssertEqual(metadata.planBucket, "dated")
    }

    func testScanFallsBackToMtimeWhenExifIsMissing() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0200.JPG", bytes: 10)
        let fileURL = tempRoot.appendingPathComponent("DCIM/100MEDIA/IMG_0200.JPG", isDirectory: false)
        let explicitMtime = Date(timeIntervalSince1970: 1_704_300_000)
        try FileManager.default.setAttributes([.modificationDate: explicitMtime], ofItemAtPath: fileURL.path)

        let scanner = SourceScanner(photoMetadataExtractor: StubPhotoMetadataExtractor(
            metadataByFilename: [
                "IMG_0200.JPG": PhotoMetadata(
                    captureDateTime: nil,
                    captureDateSource: .missing,
                    cameraMake: "Fujifilm",
                    cameraModel: "X100V",
                    cameraSerial: nil
                ),
            ]
        ))

        let summary = try scanner.scan(sourceRoot: tempRoot)
        let photo = try XCTUnwrap(summary.candidates.first)
        let metadata = try XCTUnwrap(photo.photoMetadata)
        let captureDateTime = try XCTUnwrap(metadata.captureDateTime)

        XCTAssertEqual(metadata.captureDateSource, .mtimeFallback)
        XCTAssertEqual(captureDateTime.timeIntervalSince1970, explicitMtime.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(metadata.planBucket, "dated")
        XCTAssertEqual(photo.mtime.timeIntervalSince1970, explicitMtime.timeIntervalSince1970, accuracy: 1)
    }

    func testScanReportsProgressSnapshotsAndFinalCameraAssessment() throws {
        var metadataByFilename: [String: PhotoMetadata] = [:]

        for index in 0..<10 {
            let filename = String(format: "IMG_%04d.JPG", index)
            try createFile(path: "DCIM/100MEDIA/\(filename)", bytes: 10 + index)
            metadataByFilename[filename] = PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_735_600_000 + Double(index)),
                captureDateSource: .dateTimeOriginal,
                cameraMake: "Canon",
                cameraModel: "EOS R5",
                cameraSerial: "11110000"
            )
        }

        for index in 10..<12 {
            let filename = String(format: "IMG_%04d.JPG", index)
            try createFile(path: "DCIM/100MEDIA/\(filename)", bytes: 10 + index)
        }

        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: metadataByFilename),
            videoMetadataExtractor: StubVideoMetadataExtractor(metadataByFilename: [:])
        )

        let recorder = SnapshotRecorder()
        let summary = try scanner.scan(sourceRoot: tempRoot) { recorder.append($0) }
        let snapshots = recorder.values

        XCTAssertEqual(snapshots.map(\.itemCount), [1, 10, 12])
        XCTAssertEqual(snapshots.map(\.photoCount), [1, 10, 12])
        XCTAssertEqual(snapshots.map(\.videoCount), [0, 0, 0])
        XCTAssertEqual(snapshots.last?.cameraAssessment, summary.cameraAssessment)
        XCTAssertEqual(summary.cameraAssessment.distribution.map(\.cameraLabel), [
            "eos-r5-sn-11110000",
            CameraLabeler.unknownLabel,
        ])
        XCTAssertEqual(summary.cameraAssessment.distribution.map(\.fileCount), [10, 2])
    }

    @discardableResult
    private func createFile(path: String, bytes: Int) throws -> URL {
        let fileURL = tempRoot.appendingPathComponent(path, isDirectory: false)
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let data = Data(repeating: 0x41, count: bytes)
        FileManager.default.createFile(atPath: fileURL.path, contents: data)
        return fileURL
    }
}

private struct StubPhotoMetadataExtractor: PhotoMetadataExtracting {
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

private struct StubVideoMetadataExtractor: VideoMetadataExtracting {
    let metadataByFilename: [String: VideoMetadata]

    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        metadataByFilename[fileURL.lastPathComponent] ?? VideoMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            usedFallback: true
        )
    }
}

private final class CountingVideoMetadataExtractor: VideoMetadataExtracting {
    private(set) var callCount = 0

    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        callCount += 1
        return VideoMetadata(
            captureDateTime: fallbackMtime.addingTimeInterval(10),
            captureDateSource: .creationTime,
            usedFallback: false,
            cameraMake: "Sony",
            cameraModel: "FX3",
            cameraSerial: "12345678"
        )
    }
}

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [ScanProgressSnapshot] = []

    func append(_ snapshot: ScanProgressSnapshot) {
        lock.lock()
        values.append(snapshot)
        lock.unlock()
    }
}
