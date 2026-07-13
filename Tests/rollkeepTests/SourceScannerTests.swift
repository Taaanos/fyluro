import Foundation
import XCTest
@testable import RollKeepCore

final class SourceScannerTests: XCTestCase {
    private var tempRoot: URL!
    private var externalDirectories: [URL] = []

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
        for external in externalDirectories {
            try? FileManager.default.removeItem(at: external)
        }
        externalDirectories = []
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

    func testScanIgnoresUnknownPhotoExtensions() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/IMG_0002.RAWX", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/IMG_0003.UNKNOWN", bytes: 10)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.candidates.count, 1)
        XCTAssertEqual(summary.candidates.first?.relativePath, "DCIM/100MEDIA/IMG_0001.JPG")
    }

    func testScanTreatsCinemaVideoExtensionsAsVideos() throws {
        try createFile(path: "PRIVATE/A001_0001.R3D", bytes: 10)
        try createFile(path: "PRIVATE/B001_0001.BRAW", bytes: 10)
        try createFile(path: "PRIVATE/C001_0001.CRM", bytes: 10)
        try createFile(path: "PRIVATE/D001_0001.ARI", bytes: 10)
        try createFile(path: "PRIVATE/E001_0001.CINE", bytes: 10)
        try createFile(path: "PRIVATE/F001_0001.TS", bytes: 10)
        try createFile(path: "PRIVATE/G001_0001.WEBM", bytes: 10)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.candidates.count, 7)
        XCTAssertEqual(summary.videoCount, 7)
        XCTAssertEqual(summary.photoCount, 0)
        XCTAssertTrue(summary.warnings.isEmpty)
    }

    func testScanIncludesMediaInsidePackageDirectories() throws {
        let packageURL = tempRoot.appendingPathComponent("PRIVATE/AVCHD", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.extensionHidden: true], ofItemAtPath: packageURL.path)
        try createFile(path: "PRIVATE/AVCHD/BDMV/STREAM/00000.MTS", bytes: 42)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.videoCount, 1)
        XCTAssertEqual(summary.photoCount, 0)
        XCTAssertEqual(summary.candidates.count, 1)
        XCTAssertEqual(summary.candidates.first?.relativePath, "PRIVATE/AVCHD/BDMV/STREAM/00000.MTS")
    }

    func testScanWarnsForLargeUnknownExtensionInTypicalMediaLocation() throws {
        try createFile(path: "PRIVATE/CLIP_0001.MYSTERY", bytes: 2_048)

        let summary = try SourceScanner(unknownLargeFileWarningThresholdBytes: 1_024).scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.candidates.count, 0)
        XCTAssertEqual(summary.warnings.count, 1)
        XCTAssertEqual(summary.warnings.first?.path, "PRIVATE/CLIP_0001.MYSTERY")
        XCTAssertEqual(summary.warnings.first?.fileExtension, "mystery")
        XCTAssertEqual(summary.warnings.first?.sizeBytes, 2_048)
    }

    func testScanDoesNotWarnForUnknownExtensionOutsideTypicalMediaLocation() throws {
        try createFile(path: "docs/CLIP_0001.MYSTERY", bytes: 2_048)

        let summary = try SourceScanner(unknownLargeFileWarningThresholdBytes: 1_024).scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.candidates.count, 0)
        XCTAssertTrue(summary.warnings.isEmpty)
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

    func testScanDiscoversSupportedSidecarsByBasename() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.CR2", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/IMG_0001.XMP", bytes: 11)
        try createFile(path: "DCIM/100MEDIA/IMG_0001.AAE", bytes: 12)
        try createFile(path: "DCIM/100MEDIA/IMG_0001_IGNORED.JSON", bytes: 13)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)
        let candidate = try XCTUnwrap(summary.candidates.first { $0.relativePath == "DCIM/100MEDIA/IMG_0001.CR2" })

        XCTAssertEqual(candidate.sidecars.map(\.relativePath), [
            "DCIM/100MEDIA/IMG_0001.XMP",
            "DCIM/100MEDIA/IMG_0001.AAE",
        ])
    }

    func testScanDiscoversSonyXMLSidecarVariantWithMIndexSuffix() throws {
        try createFile(path: "DCIM/100MEDIA/20251219_C3501.MP4", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/20251219_C3501M01.XML", bytes: 11)
        try createFile(path: "DCIM/100MEDIA/20251219_C3501A01.XML", bytes: 12)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)
        let candidate = try XCTUnwrap(summary.candidates.first {
            $0.relativePath == "DCIM/100MEDIA/20251219_C3501.MP4"
        })

        XCTAssertEqual(candidate.sidecars.map(\.relativePath), [
            "DCIM/100MEDIA/20251219_C3501M01.XML",
        ])
    }

    func testPreviewScanUsesPreviewVideoMetadataExtractor() throws {
        let fileURL = try createFile(path: "PRIVATE/clip.MP4", bytes: 123)
        let explicitMtime = Date(timeIntervalSince1970: 1_704_200_000)
        try FileManager.default.setAttributes([.modificationDate: explicitMtime], ofItemAtPath: fileURL.path)

        let deepExtractor = CountingVideoMetadataExtractor()
        let previewExtractor = CountingVideoMetadataExtractor()
        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: deepExtractor,
            previewVideoMetadataExtractor: previewExtractor
        )

        let summary = try scanner.scan(sourceRoot: tempRoot, mode: .preview)
        let item = try XCTUnwrap(summary.candidates.first)
        let metadata = try XCTUnwrap(item.videoMetadata)

        XCTAssertEqual(deepExtractor.callCount, 0)
        XCTAssertEqual(previewExtractor.callCount, 1)
        XCTAssertEqual(metadata.captureDateSource, .creationTime)
        XCTAssertFalse(metadata.usedFallback)
        XCTAssertEqual(metadata.captureDateTime.timeIntervalSince1970, explicitMtime.timeIntervalSince1970 + 10, accuracy: 1)
        XCTAssertEqual(metadata.cameraMake, "Sony")
        XCTAssertEqual(metadata.cameraModel, "FX3")
        XCTAssertEqual(metadata.cameraSerial, "12345678")
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

    func testScanRecordsUnreadableFileAsErrorAndStillScansOtherFiles() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)
        let unreadableURL = try createFile(path: "DCIM/100MEDIA/IMG_0002.JPG", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/IMG_0003.JPG", bytes: 10)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path)
        }

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(
            summary.candidates.map(\.relativePath).sorted(),
            ["DCIM/100MEDIA/IMG_0001.JPG", "DCIM/100MEDIA/IMG_0003.JPG"]
        )
        XCTAssertEqual(summary.errors.count, 1)
        XCTAssertEqual(summary.errors.first?.path.hasSuffix("DCIM/100MEDIA/IMG_0002.JPG"), true)
        XCTAssertEqual(summary.errors.first?.message, "File is not readable")
    }

    func testScanSkipsSymbolicLinkedFileAndWarnsWithoutFollowingTarget() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)

        // The link target lives entirely outside the source root, so importing
        // it would be a source-boundary escape.
        let externalRoot = try makeExternalDirectory()
        let outsideFile = externalRoot.appendingPathComponent("secret.JPG", isDirectory: false)
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data(repeating: 0x41, count: 16))

        let symlinkURL = tempRoot.appendingPathComponent("DCIM/100MEDIA/escape.JPG", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: outsideFile.path
        )

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        // The real media file is still imported; the symlink is not a candidate
        // and its out-of-bound target is never followed.
        XCTAssertEqual(summary.candidates.map(\.relativePath), ["DCIM/100MEDIA/IMG_0001.JPG"])
        XCTAssertFalse(summary.candidates.contains { $0.relativePath.hasSuffix("escape.JPG") })
        XCTAssertFalse(summary.candidates.contains { $0.absolutePath == outsideFile.standardizedFileURL.path })
        XCTAssertTrue(summary.errors.isEmpty)

        let symlinkWarnings = summary.warnings.filter { $0.category == .symbolicLinkSkipped }
        XCTAssertEqual(symlinkWarnings.map(\.path), ["DCIM/100MEDIA/escape.JPG"])
    }

    func testScanSkipsSymbolicLinkedDirectoryWithoutDescendingIntoTarget() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)

        let externalRoot = try makeExternalDirectory()
        let outsideDir = externalRoot.appendingPathComponent("outside-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: outsideDir.appendingPathComponent("secret.JPG").path,
            contents: Data(repeating: 0x41, count: 12)
        )

        let symlinkURL = tempRoot.appendingPathComponent("DCIM/linkdir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: outsideDir.path
        )

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        // The scanner never descends into the symlinked directory, so the
        // out-of-bound secret.JPG is not imported.
        XCTAssertEqual(summary.candidates.map(\.relativePath), ["DCIM/100MEDIA/IMG_0001.JPG"])
        XCTAssertFalse(summary.candidates.contains { $0.relativePath.contains("linkdir") })
        XCTAssertFalse(summary.candidates.contains { $0.absolutePath.contains("outside-dir") })
        XCTAssertTrue(summary.errors.isEmpty)

        let symlinkWarnings = summary.warnings.filter { $0.category == .symbolicLinkSkipped }
        XCTAssertEqual(symlinkWarnings.map(\.path), ["DCIM/linkdir"])
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

    func testScanCanForceMissingCaptureDateForSelectedRelativePaths() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_FORCE.JPG", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/IMG_KEEP.JPG", bytes: 10)
        try createFile(path: "PRIVATE/FORCE.MP4", bytes: 10)

        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(
                metadataByFilename: [
                    "IMG_FORCE.JPG": PhotoMetadata(
                        captureDateTime: Date(timeIntervalSince1970: 1_700_000_000),
                        captureDateSource: .dateTimeOriginal,
                        cameraMake: "Canon",
                        cameraModel: "EOS R5",
                        cameraSerial: "111"
                    ),
                    "IMG_KEEP.JPG": PhotoMetadata(
                        captureDateTime: Date(timeIntervalSince1970: 1_701_000_000),
                        captureDateSource: .dateTimeOriginal,
                        cameraMake: "Sony",
                        cameraModel: "A7IV",
                        cameraSerial: "222"
                    ),
                ]
            ),
            videoMetadataExtractor: StubVideoMetadataExtractor(
                metadataByFilename: [
                    "FORCE.MP4": VideoMetadata(
                        captureDateTime: Date(timeIntervalSince1970: 1_702_000_000),
                        captureDateSource: .creationTime,
                        usedFallback: false,
                        cameraMake: "Sony",
                        cameraModel: "FX3",
                        cameraSerial: "333"
                    ),
                ]
            ),
            forcedMissingCaptureDateRelativePaths: [
                "DCIM/100MEDIA/IMG_FORCE.JPG",
                "PRIVATE/FORCE.MP4",
            ]
        )

        let summary = try scanner.scan(sourceRoot: tempRoot)
        let candidatesByPath = Dictionary(uniqueKeysWithValues: summary.candidates.map { ($0.relativePath, $0) })

        let forcedPhoto = try XCTUnwrap(candidatesByPath["DCIM/100MEDIA/IMG_FORCE.JPG"])
        let forcedPhotoMetadata = try XCTUnwrap(forcedPhoto.photoMetadata)
        XCTAssertNil(forcedPhotoMetadata.captureDateTime)
        XCTAssertEqual(forcedPhotoMetadata.captureDateSource, .missing)
        XCTAssertEqual(forcedPhotoMetadata.planBucket, "_unsorted")

        let forcedVideo = try XCTUnwrap(candidatesByPath["PRIVATE/FORCE.MP4"])
        XCTAssertNil(forcedVideo.videoMetadata)

        let keptPhoto = try XCTUnwrap(candidatesByPath["DCIM/100MEDIA/IMG_KEEP.JPG"])
        let keptPhotoMetadata = try XCTUnwrap(keptPhoto.photoMetadata)
        XCTAssertEqual(keptPhotoMetadata.captureDateSource, .dateTimeOriginal)
        XCTAssertEqual(keptPhotoMetadata.planBucket, "dated")
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
        XCTAssertEqual(snapshots.map(\.filesChecked), [1, 10, 12])
        let checkedBytes = snapshots.map(\.bytesChecked)
        let photoBytes = snapshots.map(\.photoBytes)
        XCTAssertTrue(zip(checkedBytes, checkedBytes.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
        XCTAssertTrue(zip(photoBytes, photoBytes.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
        XCTAssertEqual(checkedBytes.last, summary.photoBytes + summary.videoBytes)
        XCTAssertEqual(photoBytes.last, summary.photoBytes)
        XCTAssertEqual(snapshots.map(\.videoBytes), [0, 0, 0])
        XCTAssertTrue(snapshots.allSatisfy { ($0.currentRelativePath?.isEmpty == false) })
        XCTAssertTrue(snapshots.allSatisfy { ($0.currentRelativePath?.hasPrefix("/") ?? false) == false })
        XCTAssertEqual(snapshots.last?.cameraAssessment, summary.cameraAssessment)
        XCTAssertEqual(summary.cameraAssessment.distribution.map(\.cameraLabel), [
            "eos-r5",
            CameraLabeler.unknownLabel,
        ])
        XCTAssertEqual(summary.cameraAssessment.distribution.map(\.fileCount), [10, 2])
    }

    func testScanEmitsPeriodicProgressForLargeNonMediaTrees() throws {
        let fileCount = 220
        for index in 0..<fileCount {
            try createFile(path: "docs/\(index).txt", bytes: 5)
        }

        let recorder = SnapshotRecorder()
        let summary = try SourceScanner().scan(sourceRoot: tempRoot) { recorder.append($0) }
        let snapshots = recorder.values

        XCTAssertEqual(summary.candidates.count, 0)
        XCTAssertGreaterThanOrEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.first?.filesChecked, 1)
        XCTAssertTrue(snapshots.contains { $0.filesChecked >= 100 })
        XCTAssertTrue(snapshots.contains { $0.filesChecked >= 200 })
        XCTAssertEqual(snapshots.last?.filesChecked, fileCount)
        XCTAssertEqual(snapshots.last?.bytesChecked, Int64(fileCount * 5))
        XCTAssertEqual(snapshots.last?.itemCount, 0)
    }

    /// Creates a directory outside the source root (`tempRoot`) and registers it
    /// for teardown, for exercising source-boundary-escape scenarios.
    private func makeExternalDirectory() throws -> URL {
        let external = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-tests-external-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        externalDirectories.append(external)
        return external
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
