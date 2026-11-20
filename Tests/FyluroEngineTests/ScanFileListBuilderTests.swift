import Foundation
import XCTest
@testable import FyluroCore
@testable import FyluroEngine

final class ScanFileListBuilderTests: RuntimeFixtureTestCase {
    func testBuildScanFileListEntriesIncludesCameraEvidenceAndLegacyCameraFields() throws {
        let photoURL = try createBinaryFile(path: "source/DCIM/100MEDIA/DJI_0001.JPG", bytes: 128)
        let sidecarURL = try createBinaryFile(path: "source/DCIM/100MEDIA/DJI_0001.XMP", bytes: 32)
        let captureDate = Date(timeIntervalSince1970: 1_731_000_000)

        let sidecar = MediaSidecar(
            absolutePath: sidecarURL.path,
            relativePath: "DCIM/100MEDIA/DJI_0001.XMP",
            sizeBytes: 32,
            mtime: captureDate,
            creationDate: nil,
            fileExtension: "xmp"
        )

        let candidate = MediaCandidate(
            absolutePath: photoURL.path,
            relativePath: "DCIM/100MEDIA/DJI_0001.JPG",
            mediaType: .photo,
            sizeBytes: 128,
            mtime: captureDate,
            photoMetadata: PhotoMetadata(
                captureDateTime: captureDate,
                captureDateSource: .dateTimeOriginal,
                cameraMake: "DJI",
                cameraModel: "Mini4 Pro",
                cameraSerial: "SN-123"
            ),
            sidecars: [sidecar]
        )

        let summary = ScanSummary(
            candidates: [candidate],
            photoCount: 1,
            videoCount: 0,
            photoBytes: 128,
            videoBytes: 0,
            filesInTypicalLocations: 1,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: tempRoot,
            sessionID: "scan-file-list-mini4",
            files: [
                .init(candidate: candidate, cameraLabel: "mini4-pro", sourceHash: "photo-hash"),
            ]
        )

        let inferenceByPath = [
            candidate.absolutePath: CameraInference(
                cameraLabel: "mini4-pro",
                make: "DJI",
                model: "Mini4 Pro",
                serial: "SN-123"
            ),
        ]

        let evidence = CameraIdentityResolver().resolveResolvedIdentity(
            make: "DJI",
            makeSource: .tiffMake,
            makeSelectionRule: "custom_make_rule",
            model: "Mini4 Pro",
            modelSource: .xmpProductName,
            modelSelectionRule: "custom_model_rule",
            serial: "SN-123",
            serialSource: .exifBodySerial,
            serialSelectionRule: "custom_serial_rule"
        ).evidence

        let preparation = IngestPreparation(
            scanSummary: summary,
            cameraInferenceByPath: inferenceByPath,
            plan: plan,
            cameraEvidenceByPath: [candidate.absolutePath: evidence]
        )

        let entries = buildScanFileListEntries(
            summary: summary,
            plan: plan,
            cameraInferenceByPath: inferenceByPath,
            preparation: preparation,
            isoFormatter: ISO8601DateFormatter()
        )

        XCTAssertEqual(entries.count, 1)
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first["camera_label"] as? String, "mini4-pro")
        XCTAssertEqual(first["camera_make"] as? String, "DJI")
        XCTAssertEqual(first["camera_model"] as? String, "Mini4 Pro")
        XCTAssertEqual(first["camera_serial"] as? String, "SN-123")
        XCTAssertEqual(first["sidecar_count"] as? Int, 1)

        let evidencePayload = try XCTUnwrap(first["camera_evidence"] as? [String: Any])
        let make = try XCTUnwrap(evidencePayload["make"] as? [String: String])
        let model = try XCTUnwrap(evidencePayload["model"] as? [String: String])
        let serial = try XCTUnwrap(evidencePayload["serial"] as? [String: String])

        XCTAssertEqual(make["source"], "tiff_make")
        XCTAssertEqual(make["selection_rule"], "custom_make_rule")
        XCTAssertEqual(model["source"], "xmp_product_name")
        XCTAssertEqual(model["selection_rule"], "custom_model_rule")
        XCTAssertEqual(serial["source"], "exif_body_serial")
        XCTAssertEqual(serial["selection_rule"], "custom_serial_rule")
    }

    func testBuildScanFileListEntriesKeepsScanCandidateOrder() throws {
        let firstURL = try createBinaryFile(path: "source/DCIM/100MEDIA/B.JPG", bytes: 64)
        let secondURL = try createBinaryFile(path: "source/DCIM/100MEDIA/A.JPG", bytes: 64)
        let captureDate = Date(timeIntervalSince1970: 1_731_100_000)

        let first = MediaCandidate(
            absolutePath: firstURL.path,
            relativePath: "DCIM/100MEDIA/B.JPG",
            mediaType: .photo,
            sizeBytes: 64,
            mtime: captureDate,
            photoMetadata: PhotoMetadata(
                captureDateTime: captureDate,
                captureDateSource: .dateTimeOriginal,
                cameraMake: "Canon",
                cameraModel: "EOS R5",
                cameraSerial: nil
            )
        )

        let second = MediaCandidate(
            absolutePath: secondURL.path,
            relativePath: "DCIM/100MEDIA/A.JPG",
            mediaType: .photo,
            sizeBytes: 64,
            mtime: captureDate,
            photoMetadata: PhotoMetadata(
                captureDateTime: captureDate,
                captureDateSource: .dateTimeOriginal,
                cameraMake: "Canon",
                cameraModel: "EOS R5",
                cameraSerial: nil
            )
        )

        let summary = ScanSummary(
            candidates: [first, second],
            photoCount: 2,
            videoCount: 0,
            photoBytes: 128,
            videoBytes: 0,
            filesInTypicalLocations: 2,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        let plan = DestinationPathPlanner().plan(
            destRoot: tempRoot,
            sessionID: "scan-file-list-order",
            files: [
                .init(candidate: first, cameraLabel: "eos-r5", sourceHash: "hash-b"),
                .init(candidate: second, cameraLabel: "eos-r5", sourceHash: "hash-a"),
            ]
        )

        let inferenceByPath: [String: CameraInference] = [
            first.absolutePath: CameraInference(cameraLabel: "eos-r5", make: "Canon", model: "EOS R5", serial: nil),
            second.absolutePath: CameraInference(cameraLabel: "eos-r5", make: "Canon", model: "EOS R5", serial: nil),
        ]

        let preparation = IngestPreparation(
            scanSummary: summary,
            cameraInferenceByPath: inferenceByPath,
            plan: plan
        )

        let entries = buildScanFileListEntries(
            summary: summary,
            plan: plan,
            cameraInferenceByPath: inferenceByPath,
            preparation: preparation,
            isoFormatter: ISO8601DateFormatter()
        )

        XCTAssertEqual(entries.map { $0["path"] as? String }, [
            "DCIM/100MEDIA/B.JPG",
            "DCIM/100MEDIA/A.JPG",
        ])
    }
}
