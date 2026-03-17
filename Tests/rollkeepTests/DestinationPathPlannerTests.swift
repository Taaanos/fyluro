import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeep

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

    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-destination-planner-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
