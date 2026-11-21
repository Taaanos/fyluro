import XCTest
@testable import FyluroCore

final class CameraIdentityResolverTests: XCTestCase {
    private let resolver = CameraIdentityResolver()

    func testResolvePhotoIdentityPrefersSupplementalForOpaquePrimaryModel() {
        let resolution = resolver.resolvePhotoIdentity(
            tiffMake: "DJI",
            tiffModel: "FC8482",
            supplementalModel: "Mini4 Pro",
            serialCandidates: [
                CameraIdentityCandidate(value: "TESTSERIAL0001", source: .exifBodySerial),
            ],
            supplementalSerial: "TESTSERIAL0001"
        )

        XCTAssertEqual(resolution.make, "DJI")
        XCTAssertEqual(resolution.model, "Mini4 Pro")
        XCTAssertEqual(resolution.serial, "TESTSERIAL0001")
        XCTAssertEqual(resolution.evidence.model.source, .xmpProductName)
        XCTAssertEqual(resolution.evidence.model.selectionRule, "prefer_supplemental_for_opaque_primary_model_code")
    }

    func testResolvePhotoIdentityKeepsDescriptivePrimaryModel() {
        let resolution = resolver.resolvePhotoIdentity(
            tiffMake: "Canon",
            tiffModel: "EOS R5",
            supplementalModel: "Mini4 Pro",
            serialCandidates: [
                CameraIdentityCandidate(value: "ABC12345", source: .exifBodySerial),
            ],
            supplementalSerial: nil
        )

        XCTAssertEqual(resolution.model, "EOS R5")
        XCTAssertEqual(resolution.evidence.model.source, .tiffModel)
    }

    func testResolvePhotoIdentityUsesSerialPriority() {
        let resolution = resolver.resolvePhotoIdentity(
            tiffMake: "DJI",
            tiffModel: "FC8482",
            supplementalModel: "Mini4 Pro",
            serialCandidates: [
                CameraIdentityCandidate(value: nil, source: .exifBodySerial),
                CameraIdentityCandidate(value: "EXIF-SERIAL", source: .exifSerial),
                CameraIdentityCandidate(value: "EXIF-CAMERA", source: .exifCameraSerial),
                CameraIdentityCandidate(value: "EXIF-INTERNAL", source: .exifInternalSerial),
                CameraIdentityCandidate(value: "TIFF-SERIAL", source: .tiffSerial),
            ],
            supplementalSerial: "XMP-SERIAL"
        )

        XCTAssertEqual(resolution.serial, "EXIF-SERIAL")
        XCTAssertEqual(resolution.evidence.serial.source, .exifSerial)
        XCTAssertEqual(resolution.evidence.serial.selectionRule, "first_non_empty_by_priority")
    }

    func testResolvePhotoIdentityUsesNativeFallbackOnlyWhenTiffFieldsMissing() {
        let resolution = resolver.resolvePhotoIdentity(
            tiffMake: nil,
            tiffModel: nil,
            supplementalModel: nil,
            serialCandidates: [],
            supplementalSerial: nil,
            nativeFallbackMake: "NIKON CORPORATION",
            nativeFallbackModel: "NIKON D850"
        )

        XCTAssertEqual(resolution.make, "NIKON CORPORATION")
        XCTAssertEqual(resolution.model, "NIKON D850")
        XCTAssertEqual(resolution.evidence.make.source, .embeddedExifMake)
        XCTAssertEqual(resolution.evidence.model.source, .embeddedExifModel)
    }

    func testResolvePhotoIdentityPrefersTiffFieldsOverNativeFallback() {
        let resolution = resolver.resolvePhotoIdentity(
            tiffMake: "Canon",
            tiffModel: "EOS R5",
            supplementalModel: nil,
            serialCandidates: [],
            supplementalSerial: nil,
            nativeFallbackMake: "WrongMake",
            nativeFallbackModel: "WrongModel"
        )

        XCTAssertEqual(resolution.make, "Canon")
        XCTAssertEqual(resolution.model, "EOS R5")
        XCTAssertEqual(resolution.evidence.make.source, .tiffMake)
        XCTAssertEqual(resolution.evidence.model.source, .tiffModel)
    }

    func testResolvePhotoIdentityPrefersSupplementalModelOverNativeFallback() {
        let resolution = resolver.resolvePhotoIdentity(
            tiffMake: nil,
            tiffModel: nil,
            supplementalModel: "Mini4 Pro",
            serialCandidates: [],
            supplementalSerial: nil,
            nativeFallbackMake: nil,
            nativeFallbackModel: "SomeNativeModel"
        )

        XCTAssertEqual(resolution.model, "Mini4 Pro")
        XCTAssertEqual(resolution.evidence.model.source, .xmpProductName)
    }

    func testResolveResolvedIdentityPreservesProvidedSources() {
        let resolution = resolver.resolveResolvedIdentity(
            make: "Sony",
            makeSource: .avMetadataMake,
            makeSelectionRule: "first_non_empty_by_source_priority(primary,sidecar,embedded)",
            model: "FX3",
            modelSource: .sidecarMetadataModel,
            modelSelectionRule: "first_non_empty_by_source_priority(primary,sidecar,embedded)",
            serial: "12345678",
            serialSource: .embeddedMetadataSerial,
            serialSelectionRule: "first_non_empty_by_source_priority(primary,sidecar,embedded)"
        )

        XCTAssertEqual(resolution.make, "Sony")
        XCTAssertEqual(resolution.model, "FX3")
        XCTAssertEqual(resolution.serial, "12345678")
        XCTAssertEqual(resolution.evidence.make.source, .avMetadataMake)
        XCTAssertEqual(resolution.evidence.model.source, .sidecarMetadataModel)
        XCTAssertEqual(resolution.evidence.serial.source, .embeddedMetadataSerial)
    }
}
