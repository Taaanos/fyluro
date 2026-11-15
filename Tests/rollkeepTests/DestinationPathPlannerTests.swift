import Foundation
import XCTest
@testable import RollKeepCore

final class DestinationPathPlannerTests: XCTestCase {
    func testPlanUsesDatedFolderSchemaForPhotosAndVideos() {
        let photo = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_0001.JPG",
            relativePath: "DCIM/100/IMG_0001.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800) // 2024-02-20T08:00:00Z
        )
        let video = makeVideoCandidate(
            absolutePath: "/source/PRIVATE/GX010001.MP4",
            relativePath: "PRIVATE/GX010001.MP4",
            captureDate: Date(timeIntervalSince1970: 1_709_467_200) // 2024-03-02T08:00:00Z
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-123",
            files: [
                .init(candidate: photo, cameraLabel: "iPhone 15 Pro", sourceHash: "photo-hash"),
                .init(candidate: video, cameraLabel: "GoPro HERO 12", sourceHash: "video-hash"),
            ]
        )

        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(plan.files[0].finalPath, "/dest/2024/202402/iphone-15-pro/Photos/IMG_0001.JPG")
        XCTAssertEqual(plan.files[0].stagingPath, "/dest/_ingest_staging/session-123/2024/202402/iphone-15-pro/Photos/IMG_0001.JPG")
        XCTAssertEqual(plan.files[1].finalPath, "/dest/2024/202403/gopro-hero-12/Videos/GX010001.MP4")
        XCTAssertEqual(plan.files[1].stagingPath, "/dest/_ingest_staging/session-123/2024/202403/gopro-hero-12/Videos/GX010001.MP4")
    }

    func testPlanRoutesMissingMetadataToUnsorted() {
        let photo = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_1000.JPG",
            relativePath: "DCIM/100/IMG_1000.JPG",
            filenameDate: nil
        )
        let video = MediaCandidate(
            absolutePath: "/source/PRIVATE/CLIP_0001.MP4",
            relativePath: "PRIVATE/CLIP_0001.MP4",
            mediaType: .video,
            sizeBytes: 456,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: nil,
            videoMetadata: nil
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-456",
            files: [
                .init(candidate: photo, cameraLabel: ""),
                .init(candidate: video, cameraLabel: " "),
            ]
        )

        XCTAssertEqual(plan.files[0].finalPath, "/dest/_unsorted/unknown-camera/Photos/IMG_1000.JPG")
        XCTAssertEqual(plan.files[1].finalPath, "/dest/_unsorted/unknown-camera/Videos/CLIP_0001.MP4")
    }

    func testPlanUsesFlatAudioBucketIgnoringCameraLabelAndMediaTypeFolder() {
        let audio = makeAudioCandidate(
            absolutePath: "/source/DCIM/iphone recording.m4a",
            relativePath: "DCIM/iphone recording.m4a",
            captureDate: Date(timeIntervalSince1970: 1_708_516_800) // 2024-02-20T08:00:00Z
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-audio",
            files: [
                // cameraLabel is set (as CameraLabeler would for an audio
                // candidate) but must not appear in the final path -- audio's
                // v1 flat bucket is a fixed "audio" folder, not <camera>/<media>.
                .init(candidate: audio, cameraLabel: "audio", sourceHash: "audio-hash"),
            ]
        )

        let item = try? XCTUnwrap(plan.files.first)
        XCTAssertEqual(item?.finalPath, "/dest/2024/202402/audio/iphone recording.m4a")
        XCTAssertEqual(item?.stagingPath, "/dest/_ingest_staging/session-audio/2024/202402/audio/iphone recording.m4a")
    }

    func testPlanRoutesAudioWithoutCaptureDateToUnsortedFlatBucket() {
        let audio = makeAudioCandidate(
            absolutePath: "/source/DCIM/orphan-recording.wav",
            relativePath: "DCIM/orphan-recording.wav",
            captureDate: nil
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-audio-unsorted",
            files: [
                .init(candidate: audio, cameraLabel: "audio"),
            ]
        )

        XCTAssertEqual(plan.files.first?.finalPath, "/dest/_unsorted/audio/orphan-recording.wav")
    }

    func testPlanUsesSequentialCollisionSuffixes() {
        let candidate = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_2000.JPG",
            relativePath: "DCIM/100/IMG_2000.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800)
        )

        let existingFinalFiles: [String: String?] = [
            "/dest/2024/202402/sony-a7/Photos/IMG_2000.JPG": "existing-base-hash",
            "/dest/2024/202402/sony-a7/Photos/IMG_2000-1.JPG": "existing-one-hash",
        ]

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-789",
            files: [
                .init(candidate: candidate, cameraLabel: "Sony A7", sourceHash: "incoming-hash"),
            ],
            existingFinalFiles: existingFinalFiles
        )

        let item = try? XCTUnwrap(plan.files.first)
        XCTAssertEqual(item?.finalPath, "/dest/2024/202402/sony-a7/Photos/IMG_2000-2.JPG")
        XCTAssertEqual(item?.collisionSuffix, 2)
        XCTAssertTrue(item?.collisionResolved ?? false)
    }

    func testPlanSkipsDuplicateWhenExistingHashMatches() {
        let candidate = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_3000.JPG",
            relativePath: "DCIM/100/IMG_3000.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800)
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-111",
            files: [
                .init(candidate: candidate, cameraLabel: "Canon R5", sourceHash: "same-hash"),
            ],
            existingFinalFiles: [
                "/dest/2024/202402/canon-r5/Photos/IMG_3000.JPG": "same-hash",
            ]
        )

        let item = try? XCTUnwrap(plan.files.first)
        XCTAssertEqual(item?.disposition, .duplicateNotCopied)
        XCTAssertNil(item?.stagingPath)
        XCTAssertEqual(item?.duplicateOfPath, "/dest/2024/202402/canon-r5/Photos/IMG_3000.JPG")
        XCTAssertEqual(plan.duplicatesSkipped, 1)
        XCTAssertEqual(plan.directoriesToCreate, [])
    }

    func testPlanProducesUniqueDirectoriesToCreate() {
        let first = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_4000.JPG",
            relativePath: "DCIM/100/IMG_4000.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800)
        )
        let second = makePhotoCandidate(
            absolutePath: "/source/DCIM/101/IMG_4001.JPG",
            relativePath: "DCIM/101/IMG_4001.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_801)
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-222",
            files: [
                .init(candidate: first, cameraLabel: "Fuji X100V", sourceHash: "hash-1"),
                .init(candidate: second, cameraLabel: "Fuji X100V", sourceHash: "hash-2"),
            ]
        )

        XCTAssertEqual(plan.directoriesToCreate, [
            "/dest/2024/202402/fuji-x100v/Photos",
            "/dest/_ingest_staging/session-222/2024/202402/fuji-x100v/Photos",
        ])
    }

    func testPlanResolvesCaseOnlyFilenameCollisionsDeterministically() {
        let first = makePhotoCandidate(
            absolutePath: "/source/dir1/IMG_6481.jpg",
            relativePath: "dir1/IMG_6481.jpg",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800)
        )
        let second = makePhotoCandidate(
            absolutePath: "/source/dir2/IMG_6481.JPG",
            relativePath: "dir2/IMG_6481.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_801)
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-case-collision",
            files: [
                .init(candidate: first, cameraLabel: "unknown-camera", sourceHash: "hash-1"),
                .init(candidate: second, cameraLabel: "unknown-camera", sourceHash: "hash-2"),
            ]
        )

        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(plan.files[0].finalPath, "/dest/2024/202402/unknown-camera/Photos/IMG_6481.jpg")
        XCTAssertEqual(plan.files[0].stagingPath, "/dest/_ingest_staging/session-case-collision/2024/202402/unknown-camera/Photos/IMG_6481.jpg")
        XCTAssertEqual(plan.files[0].collisionSuffix, nil)

        XCTAssertEqual(plan.files[1].finalPath, "/dest/2024/202402/unknown-camera/Photos/IMG_6481-1.JPG")
        XCTAssertEqual(plan.files[1].stagingPath, "/dest/_ingest_staging/session-case-collision/2024/202402/unknown-camera/Photos/IMG_6481-1.JPG")
        XCTAssertEqual(plan.files[1].collisionSuffix, 1)
        XCTAssertTrue(plan.files[1].collisionResolved)
    }

    func testPlanReusesExistingLowercaseMediaDirectories() throws {
        let tempRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("2024/202402/sony-a7/photos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("2024/202403/gopro-hero-12/videos", isDirectory: true),
            withIntermediateDirectories: true
        )

        let photo = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_5000.JPG",
            relativePath: "DCIM/100/IMG_5000.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800)
        )
        let video = makeVideoCandidate(
            absolutePath: "/source/PRIVATE/GX010050.MP4",
            relativePath: "PRIVATE/GX010050.MP4",
            captureDate: Date(timeIntervalSince1970: 1_709_467_200)
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: tempRoot,
            sessionID: "session-lowercase",
            files: [
                .init(candidate: photo, cameraLabel: "Sony A7", sourceHash: "photo-hash"),
                .init(candidate: video, cameraLabel: "GoPro HERO 12", sourceHash: "video-hash"),
            ]
        )

        XCTAssertEqual(
            plan.files[0].finalPath,
            tempRoot.appendingPathComponent("2024/202402/sony-a7/photos/IMG_5000.JPG", isDirectory: false).path
        )
        XCTAssertEqual(
            plan.files[0].stagingPath,
            tempRoot.appendingPathComponent(
                "_ingest_staging/session-lowercase/2024/202402/sony-a7/photos/IMG_5000.JPG",
                isDirectory: false
            ).path
        )
        XCTAssertEqual(
            plan.files[1].finalPath,
            tempRoot.appendingPathComponent("2024/202403/gopro-hero-12/videos/GX010050.MP4", isDirectory: false).path
        )
        XCTAssertEqual(
            plan.files[1].stagingPath,
            tempRoot.appendingPathComponent(
                "_ingest_staging/session-lowercase/2024/202403/gopro-hero-12/videos/GX010050.MP4",
                isDirectory: false
            ).path
        )
    }

    func testPlanReusesExistingDirectoryNameConsistentlyAcrossManyFilesInBucket() throws {
        let tempRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // A single pre-existing lowercase `photos` dir for one date/camera bucket.
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("2024/202402/sony-a7/photos", isDirectory: true),
            withIntermediateDirectories: true
        )

        let captureDate = Date(timeIntervalSince1970: 1_708_516_800) // 2024-02-21 UTC
        let files = (0..<12).map { index -> DestinationPathPlanner.SourceFile in
            let name = String(format: "IMG_%04d.JPG", index)
            let candidate = makePhotoCandidate(
                absolutePath: "/source/DCIM/100/\(name)",
                relativePath: "DCIM/100/\(name)",
                filenameDate: captureDate
            )
            return .init(candidate: candidate, cameraLabel: "Sony A7", sourceHash: "hash-\(index)")
        }

        let plan = DestinationPathPlanner().plan(
            destRoot: tempRoot,
            sessionID: "session-bucket",
            files: files
        )

        // Every file in the bucket must reuse the same lowercase `photos` segment
        // that was resolved for the first file — the memoized value has to apply
        // consistently to files 2..N, not just file 1.
        XCTAssertEqual(plan.files.count, files.count)
        for (index, planned) in plan.files.enumerated() {
            let name = String(format: "IMG_%04d.JPG", index)
            XCTAssertEqual(
                planned.finalPath,
                tempRoot.appendingPathComponent("2024/202402/sony-a7/photos/\(name)", isDirectory: false).path
            )
        }
    }

    func testPlanSupportsAllChronologyCameraAndCompressionCombinations() {
        let photo = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_0001.ARW",
            relativePath: "DCIM/100/IMG_0001.ARW",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800)
        )
        let video = makeVideoCandidate(
            absolutePath: "/source/PRIVATE/GX010001.MP4",
            relativePath: "PRIVATE/GX010001.MP4",
            captureDate: Date(timeIntervalSince1970: 1_708_516_800)
        )

        let chronologicalLayouts: [PathChronologicalLayout] = [.yearYearMonthCompact, .yearMonthNested]
        let cameraGroupingOptions = [true, false]
        let splitCompressionOptions = [true, false]

        for chronologicalLayout in chronologicalLayouts {
            for includeCameraFolder in cameraGroupingOptions {
                for splitPhotoCompression in splitCompressionOptions {
                    let planner = DestinationPathPlanner(pathScheme: ImportPathScheme(
                        chronologicalLayout: chronologicalLayout,
                        includeCameraFolder: includeCameraFolder,
                        splitPhotoCompression: splitPhotoCompression
                    ))
                    let plan = planner.plan(
                        destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
                        sessionID: "session-matrix",
                        files: [
                            .init(candidate: photo, cameraLabel: "Sony A7IV", sourceHash: "photo-hash"),
                            .init(candidate: video, cameraLabel: "GoPro HERO 12", sourceHash: "video-hash"),
                        ]
                    )

                    XCTAssertEqual(plan.files.count, 2)
                    let expectedChronologyComponents = chronologicalLayout == .yearYearMonthCompact
                        ? ["2024", "202402"]
                        : ["2024", "02"]

                    var expectedPhotoPathComponents = ["/dest"] + expectedChronologyComponents
                    if includeCameraFolder {
                        expectedPhotoPathComponents.append("sony-a7iv")
                    }
                    expectedPhotoPathComponents.append("Photos")
                    if splitPhotoCompression {
                        expectedPhotoPathComponents.append("RAW")
                    }
                    expectedPhotoPathComponents.append("IMG_0001.ARW")

                    var expectedVideoPathComponents = ["/dest"] + expectedChronologyComponents
                    if includeCameraFolder {
                        expectedVideoPathComponents.append("gopro-hero-12")
                    }
                    expectedVideoPathComponents.append("Videos")
                    expectedVideoPathComponents.append("GX010001.MP4")

                    XCTAssertEqual(plan.files[0].finalPath, expectedPhotoPathComponents.joined(separator: "/"))
                    XCTAssertEqual(plan.files[1].finalPath, expectedVideoPathComponents.joined(separator: "/"))
                }
            }
        }
    }

    func testPlanUsesUnsortedWithSamePathSchemeToggles() {
        let photo = makePhotoCandidate(
            absolutePath: "/source/DCIM/100/IMG_1000.JPG",
            relativePath: "DCIM/100/IMG_1000.JPG",
            filenameDate: nil
        )
        let video = MediaCandidate(
            absolutePath: "/source/PRIVATE/CLIP_0001.MP4",
            relativePath: "PRIVATE/CLIP_0001.MP4",
            mediaType: .video,
            sizeBytes: 456,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: nil,
            videoMetadata: nil
        )

        let plan = DestinationPathPlanner(pathScheme: ImportPathScheme(
            chronologicalLayout: .yearMonthNested,
            includeCameraFolder: false,
            splitPhotoCompression: true
        )).plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-unsorted-toggles",
            files: [
                .init(candidate: photo, cameraLabel: "camera-a", sourceHash: "photo-hash"),
                .init(candidate: video, cameraLabel: "camera-b", sourceHash: "video-hash"),
            ]
        )

        XCTAssertEqual(plan.files[0].finalPath, "/dest/_unsorted/Photos/Non-RAW/IMG_1000.JPG")
        XCTAssertEqual(plan.files[1].finalPath, "/dest/_unsorted/Videos/CLIP_0001.MP4")
    }

    func testPlanAppliesCollisionSuffixWhenCameraGroupingDisabled() {
        let first = makePhotoCandidate(
            absolutePath: "/source/DCIM/A/IMG_0001.JPG",
            relativePath: "DCIM/A/IMG_0001.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_800)
        )
        let second = makePhotoCandidate(
            absolutePath: "/source/DCIM/B/IMG_0001.JPG",
            relativePath: "DCIM/B/IMG_0001.JPG",
            filenameDate: Date(timeIntervalSince1970: 1_708_516_801)
        )

        let plan = DestinationPathPlanner(pathScheme: ImportPathScheme(
            chronologicalLayout: .yearYearMonthCompact,
            includeCameraFolder: false,
            splitPhotoCompression: false
        )).plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-no-camera-collision",
            files: [
                .init(candidate: first, cameraLabel: "canon-r5", sourceHash: "hash-1"),
                .init(candidate: second, cameraLabel: "sony-a7iv", sourceHash: "hash-2"),
            ]
        )

        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(plan.files[0].finalPath, "/dest/2024/202402/Photos/IMG_0001.JPG")
        XCTAssertEqual(plan.files[1].finalPath, "/dest/2024/202402/Photos/IMG_0001-1.JPG")
        XCTAssertTrue(plan.files[1].collisionResolved)
        XCTAssertEqual(plan.files[1].collisionSuffix, 1)
    }

    func testPlanTruncatesStemFor254And255ByteASCIIAndMultibyteCollisions() {
        let captureDate = Date(timeIntervalSince1970: 1_707_100_000)

        // 255-byte ASCII filename: 251-byte stem + ".JPG" (4 bytes)
        let ascii255Stem = String(repeating: "a", count: 251)
        let ascii255Filename = "\(ascii255Stem).JPG"
        XCTAssertEqual(ascii255Filename.utf8.count, 255)

        // 254-byte ASCII filename: 250-byte stem + ".JPG" (4 bytes)
        let ascii254Stem = String(repeating: "b", count: 250)
        let ascii254Filename = "\(ascii254Stem).JPG"
        XCTAssertEqual(ascii254Filename.utf8.count, 254)

        // 255-byte multi-byte UTF-8 filename using 4-byte emoji + combining grapheme cluster ("e\u{0301}" = 3 UTF-8 bytes)
        let grapheme = "e\u{0301}" // 1 Character, 3 UTF-8 bytes
        let emoji = "📷"            // 1 Character, 4 UTF-8 bytes
        // 62 * 4 = 248 bytes (emojis) + 3 bytes (e\u{0301}) + 4 bytes (".JPG") = 255 UTF-8 bytes
        let utf8_255Stem = String(repeating: emoji, count: 62) + grapheme
        let utf8_255Filename = "\(utf8_255Stem).JPG"
        XCTAssertEqual(utf8_255Filename.utf8.count, 255)

        // 254-byte multi-byte UTF-8 filename: 62 * 4 = 248 bytes + 2 bytes ("ü") + 4 bytes (".JPG") = 254 UTF-8 bytes
        let altEmoji = "🎉"        // 1 Character, 4 UTF-8 bytes
        let utf8_254Stem = String(repeating: altEmoji, count: 62) + "ü"
        let utf8_254Filename = "\(utf8_254Stem).JPG"
        XCTAssertEqual(utf8_254Filename.utf8.count, 254)

        var entries: [DestinationPathPlanner.SourceFile] = []
        for idx in 1...3 {
            entries.append(.init(
                candidate: makePhotoCandidate(absolutePath: "/card/DCIM/100/\(idx)_\(ascii255Filename)", relativePath: "DCIM/100/\(ascii255Filename)", filenameDate: captureDate),
                cameraLabel: "cam",
                sourceHash: "h-a255-\(idx)"
            ))
        }
        for idx in 1...2 {
            entries.append(.init(
                candidate: makePhotoCandidate(absolutePath: "/card/DCIM/101/\(idx)_\(ascii254Filename)", relativePath: "DCIM/101/\(ascii254Filename)", filenameDate: captureDate),
                cameraLabel: "cam",
                sourceHash: "h-a254-\(idx)"
            ))
        }
        for idx in 1...2 {
            entries.append(.init(
                candidate: makePhotoCandidate(absolutePath: "/card/DCIM/102/\(idx)_\(utf8_255Filename)", relativePath: "DCIM/102/\(utf8_255Filename)", filenameDate: captureDate),
                cameraLabel: "cam",
                sourceHash: "h-u255-\(idx)"
            ))
        }
        for idx in 1...2 {
            entries.append(.init(
                candidate: makePhotoCandidate(absolutePath: "/card/DCIM/103/\(idx)_\(utf8_254Filename)", relativePath: "DCIM/103/\(utf8_254Filename)", filenameDate: captureDate),
                cameraLabel: "cam",
                sourceHash: "h-u254-\(idx)"
            ))
        }

        let plan = DestinationPathPlanner().plan(
            destRoot: URL(fileURLWithPath: "/dest", isDirectory: true),
            sessionID: "session-long-collision",
            files: entries
        )

        XCTAssertEqual(plan.files.count, 9)
        for planned in plan.files {
            let filename = (planned.finalPath as NSString).lastPathComponent
            XCTAssertLessThanOrEqual(filename.utf8.count, 255, "Filename exceeded 255 UTF-8 bytes: \(filename)")
            XCTAssertTrue(filename.hasSuffix(".JPG"))
        }

        // First 255-byte ASCII keeps full stem; collisions get -1 and -2 with trimmed stems
        XCTAssertEqual((plan.files[0].finalPath as NSString).lastPathComponent, ascii255Filename)
        XCTAssertEqual((plan.files[1].finalPath as NSString).lastPathComponent, "\(String(repeating: "a", count: 249))-1.JPG")
        XCTAssertEqual((plan.files[2].finalPath as NSString).lastPathComponent, "\(String(repeating: "a", count: 249))-2.JPG")
        XCTAssertEqual(plan.files[1].collisionSuffix, 1)
        XCTAssertEqual(plan.files[2].collisionSuffix, 2)

        // 254-byte ASCII collision needs 249-byte stem + "-1" (2) + ".JPG" (4) = 255 bytes
        XCTAssertEqual((plan.files[3].finalPath as NSString).lastPathComponent, ascii254Filename)
        XCTAssertEqual((plan.files[4].finalPath as NSString).lastPathComponent, "\(String(repeating: "b", count: 249))-1.JPG")

        // 255-byte UTF-8 collision drops the entire trailing "e\u{0301}" grapheme cluster instead of splitting combining mark
        let utf8_255CollisionName = (plan.files[6].finalPath as NSString).lastPathComponent
        XCTAssertEqual(utf8_255CollisionName, "\(String(repeating: emoji, count: 62))-1.JPG")
        XCTAssertEqual(utf8_255CollisionName.utf8.count, 254)

        // 254-byte UTF-8 collision drops the entire 2-byte "ü" character so emoji sequence stays intact
        let utf8_254CollisionName = (plan.files[8].finalPath as NSString).lastPathComponent
        XCTAssertEqual(utf8_254CollisionName, "\(String(repeating: altEmoji, count: 62))-1.JPG")
        XCTAssertEqual(utf8_254CollisionName.utf8.count, 254)

        // Direct suffix-10 check ensures multi-digit suffix trims cleanly without double suffixing
        let suffix10 = CollisionFilenameBuilder.filenameByAppendingCollisionSuffix(to: ascii255Filename, suffix: 10)
        XCTAssertEqual(suffix10.utf8.count, 255)
        XCTAssertEqual(suffix10, "\(String(repeating: "a", count: 248))-10.JPG")
    }

    private func makePhotoCandidate(
        absolutePath: String,
        relativePath: String,
        filenameDate: Date?
    ) -> MediaCandidate {
        MediaCandidate(
            absolutePath: absolutePath,
            relativePath: relativePath,
            mediaType: .photo,
            sizeBytes: 123,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: PhotoMetadata(
                captureDateTime: filenameDate,
                captureDateSource: filenameDate == nil ? .missing : .dateTimeOriginal,
                cameraMake: "Test",
                cameraModel: "Model",
                cameraSerial: nil
            ),
            videoMetadata: nil
        )
    }

    private func makeVideoCandidate(
        absolutePath: String,
        relativePath: String,
        captureDate: Date
    ) -> MediaCandidate {
        MediaCandidate(
            absolutePath: absolutePath,
            relativePath: relativePath,
            mediaType: .video,
            sizeBytes: 456,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: nil,
            videoMetadata: VideoMetadata(
                captureDateTime: captureDate,
                captureDateSource: .creationTime,
                usedFallback: false,
                cameraMake: "GoPro",
                cameraModel: "HERO12",
                cameraSerial: nil
            )
        )
    }

    private func makeAudioCandidate(
        absolutePath: String,
        relativePath: String,
        captureDate: Date?
    ) -> MediaCandidate {
        MediaCandidate(
            absolutePath: absolutePath,
            relativePath: relativePath,
            mediaType: .audio,
            sizeBytes: 35_455,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            audioMetadata: captureDate.map {
                AudioMetadata(captureDateTime: $0, captureDateSource: .creationTime, usedFallback: false)
            }
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-destination-planner-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
