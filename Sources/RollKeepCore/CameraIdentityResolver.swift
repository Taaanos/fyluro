import Foundation

enum CameraIdentityEvidenceSource: String, Sendable {
    case tiffMake = "tiff_make"
    case tiffModel = "tiff_model"
    case exifBodySerial = "exif_body_serial"
    case exifSerial = "exif_serial"
    case exifCameraSerial = "exif_camera_serial"
    case exifInternalSerial = "exif_internal_serial"
    case tiffSerial = "tiff_serial"
    case xmpProductName = "xmp_product_name"
    case xmpCameraSerial = "xmp_camera_serial"
    case avMetadataMake = "av_metadata_make"
    case avMetadataModel = "av_metadata_model"
    case avMetadataSerial = "av_metadata_serial"
    case sidecarMetadataMake = "sidecar_metadata_make"
    case sidecarMetadataModel = "sidecar_metadata_model"
    case sidecarMetadataSerial = "sidecar_metadata_serial"
    case embeddedMetadataMake = "embedded_metadata_make"
    case embeddedMetadataModel = "embedded_metadata_model"
    case embeddedMetadataSerial = "embedded_metadata_serial"
    case unresolved = "unresolved"
}

struct CameraIdentityCandidate: Equatable, Sendable {
    let value: String?
    let source: CameraIdentityEvidenceSource
}

struct CameraIdentityEvidenceField: Equatable, Sendable {
    let value: String?
    let source: CameraIdentityEvidenceSource?
    let selectionRule: String

    var receiptPayload: [String: Any] {
        [
            "value": value ?? "missing",
            "source": source?.rawValue ?? "missing",
            "selection_rule": selectionRule,
        ]
    }
}

struct CameraIdentityEvidence: Equatable, Sendable {
    let make: CameraIdentityEvidenceField
    let model: CameraIdentityEvidenceField
    let serial: CameraIdentityEvidenceField

    static func unresolved() -> CameraIdentityEvidence {
        CameraIdentityEvidence(
            make: CameraIdentityEvidenceField(
                value: nil,
                source: nil,
                selectionRule: "unresolved"
            ),
            model: CameraIdentityEvidenceField(
                value: nil,
                source: nil,
                selectionRule: "unresolved"
            ),
            serial: CameraIdentityEvidenceField(
                value: nil,
                source: nil,
                selectionRule: "unresolved"
            )
        )
    }

    func receiptPayload() -> [String: Any] {
        [
            "make": make.receiptPayload,
            "model": model.receiptPayload,
            "serial": serial.receiptPayload,
        ]
    }
}

struct CameraIdentityResolution: Equatable, Sendable {
    let make: String?
    let model: String?
    let serial: String?
    let evidence: CameraIdentityEvidence
}

struct CameraIdentityResolver {
    func resolvePhotoIdentity(
        tiffMake: String?,
        tiffModel: String?,
        supplementalModel: String?,
        serialCandidates: [CameraIdentityCandidate],
        supplementalSerial: String?
    ) -> CameraIdentityResolution {
        let makeField = firstNonEmptyField(
            candidates: [CameraIdentityCandidate(value: tiffMake, source: .tiffMake)],
            selectionRule: "first_non_empty_by_priority"
        )

        let modelField = resolvePhotoModel(
            primaryModel: tiffModel,
            supplementalModel: supplementalModel
        )

        var resolvedSerialCandidates = serialCandidates
        resolvedSerialCandidates.append(CameraIdentityCandidate(
            value: supplementalSerial,
            source: .xmpCameraSerial
        ))
        let serialField = firstNonEmptyField(
            candidates: resolvedSerialCandidates,
            selectionRule: "first_non_empty_by_priority"
        )

        return CameraIdentityResolution(
            make: makeField.value,
            model: modelField.value,
            serial: serialField.value,
            evidence: CameraIdentityEvidence(
                make: makeField,
                model: modelField,
                serial: serialField
            )
        )
    }

    func resolveResolvedIdentity(
        make: String?,
        makeSource: CameraIdentityEvidenceSource?,
        makeSelectionRule: String,
        model: String?,
        modelSource: CameraIdentityEvidenceSource?,
        modelSelectionRule: String,
        serial: String?,
        serialSource: CameraIdentityEvidenceSource?,
        serialSelectionRule: String
    ) -> CameraIdentityResolution {
        let makeField = CameraIdentityEvidenceField(
            value: normalize(make),
            source: makeSource,
            selectionRule: makeSelectionRule
        )
        let modelField = CameraIdentityEvidenceField(
            value: normalize(model),
            source: modelSource,
            selectionRule: modelSelectionRule
        )
        let serialField = CameraIdentityEvidenceField(
            value: normalize(serial),
            source: serialSource,
            selectionRule: serialSelectionRule
        )

        return CameraIdentityResolution(
            make: makeField.value,
            model: modelField.value,
            serial: serialField.value,
            evidence: CameraIdentityEvidence(
                make: makeField,
                model: modelField,
                serial: serialField
            )
        )
    }

    private func resolvePhotoModel(primaryModel: String?, supplementalModel: String?) -> CameraIdentityEvidenceField {
        let normalizedPrimary = normalize(primaryModel)
        let normalizedSupplemental = normalize(supplementalModel)
        let selectionRule = "prefer_supplemental_for_opaque_primary_model_code"

        guard let normalizedPrimary else {
            return CameraIdentityEvidenceField(
                value: normalizedSupplemental,
                source: normalizedSupplemental == nil ? nil : .xmpProductName,
                selectionRule: selectionRule
            )
        }

        guard let normalizedSupplemental,
              shouldPreferSupplementalModel(primaryModel: normalizedPrimary, supplementalModel: normalizedSupplemental)
        else {
            return CameraIdentityEvidenceField(
                value: normalizedPrimary,
                source: .tiffModel,
                selectionRule: selectionRule
            )
        }

        return CameraIdentityEvidenceField(
            value: normalizedSupplemental,
            source: .xmpProductName,
            selectionRule: selectionRule
        )
    }

    private func firstNonEmptyField(
        candidates: [CameraIdentityCandidate],
        selectionRule: String
    ) -> CameraIdentityEvidenceField {
        for candidate in candidates {
            guard let value = normalize(candidate.value) else {
                continue
            }

            return CameraIdentityEvidenceField(
                value: value,
                source: candidate.source,
                selectionRule: selectionRule
            )
        }

        return CameraIdentityEvidenceField(
            value: nil,
            source: nil,
            selectionRule: selectionRule
        )
    }

    private func shouldPreferSupplementalModel(primaryModel: String, supplementalModel: String) -> Bool {
        if primaryModel.caseInsensitiveCompare(supplementalModel) == .orderedSame {
            return false
        }

        return isOpaqueModelCode(primaryModel) && !isOpaqueModelCode(supplementalModel)
    }

    private func isOpaqueModelCode(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(
            of: #"[^A-Za-z0-9]"#,
            with: "",
            options: [.regularExpression]
        )
        guard !compact.isEmpty else {
            return false
        }

        let range = NSRange(compact.startIndex..., in: compact)
        return Self.opaqueModelCodeRegex.firstMatch(in: compact, range: range) != nil
    }

    private func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    private static let opaqueModelCodeRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z]{2,}[0-9]{3,}$"#
    )
}
