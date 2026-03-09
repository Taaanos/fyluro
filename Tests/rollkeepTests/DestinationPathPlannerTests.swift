import Foundation
import XCTest
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
        XCTAssertEqual(plan.files[0].finalPath, "/dest/2024/022024/iphone-15-pro/Photos/IMG_0001.JPG")
        XCTAssertEqual(plan.files[0].stagingPath, "/dest/_ingest_staging/session-123/2024/022024/iphone-15-pro/Photos/IMG_0001.JPG")
        XCTAssertEqual(plan.files[1].finalPath, "/dest/2024/032024/gopro-hero-12/Videos/GX010001.MP4")
        XCTAssertEqual(plan.files[1].stagingPath, "/dest/_ingest_staging/session-123/2024/032024/gopro-hero-12/Videos/GX010001.MP4")
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
            "/dest/2024/022024/sony-a7/Photos/IMG_2000.JPG": "existing-base-hash",
            "/dest/2024/022024/sony-a7/Photos/IMG_2000-1.JPG": "existing-one-hash",
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
        XCTAssertEqual(item?.finalPath, "/dest/2024/022024/sony-a7/Photos/IMG_2000-2.JPG")
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
                "/dest/2024/022024/canon-r5/Photos/IMG_3000.JPG": "same-hash",
            ]
        )

        let item = try? XCTUnwrap(plan.files.first)
        XCTAssertEqual(item?.disposition, .duplicateNotCopied)
        XCTAssertNil(item?.stagingPath)
        XCTAssertEqual(item?.duplicateOfPath, "/dest/2024/022024/canon-r5/Photos/IMG_3000.JPG")
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
            "/dest/2024/022024/fuji-x100v/Photos",
            "/dest/_ingest_staging/session-222/2024/022024/fuji-x100v/Photos",
        ])
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
}
