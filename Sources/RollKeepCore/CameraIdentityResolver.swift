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
    /// Native TIFF/EXIF byte parsing used only when ImageIO could not decode
    /// the file (new/unsupported RAW formats) or returned an empty TIFF
    /// dictionary -- CR3 (BMFF + Canon uuid), RAF (embedded JPEG preview),
    /// MRW (embedded TTW TIFF block), and the generic TIFF-variant-magic
    /// sniff (RW2, ORF, and standard-magic formats ImageIO happened to
    /// reject). 
    case embeddedExifMake = "embedded_exif_make"
    case embeddedExifModel = "embedded_exif_model"
    case embeddedExifSerial = "embedded_exif_serial"
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
        supplementalSerial: String?,
        nativeFallbackMake: String? = nil,
        nativeFallbackModel: String? = nil
    ) -> CameraIdentityResolution {
        let makeField = firstNonEmptyField(
            candidates: [
                CameraIdentityCandidate(value: tiffMake, source: .tiffMake),
                CameraIdentityCandidate(value: nativeFallbackMake, source: .embeddedExifMake),
            ],
            selectionRule: "first_non_empty_by_priority"
        )

        let modelField = resolvePhotoModel(
            primaryModel: tiffModel,
            supplementalModel: supplementalModel,
            nativeFallbackModel: nativeFallbackModel
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

    private func resolvePhotoModel(
        primaryModel: String?,
        supplementalModel: String?,
        nativeFallbackModel: String? = nil
    ) -> CameraIdentityEvidenceField {
        let normalizedPrimary = normalize(primaryModel)
        let normalizedSupplemental = normalize(supplementalModel)
        let normalizedNativeFallback = normalize(nativeFallbackModel)
        let selectionRule = "prefer_supplemental_for_opaque_primary_model_code"

        guard let normalizedPrimary else {
            // No ImageIO/TIFF model at all: the XMP-ish supplemental
            // text-scan result outranks the native fallback (it was already
            // the established behavior before native fallback existed);
            // native fallback is a new, lower rung, not a reordering.
            if let normalizedSupplemental {
                return CameraIdentityEvidenceField(
                    value: normalizedSupplemental,
                    source: .xmpProductName,
                    selectionRule: selectionRule
                )
            }
            return CameraIdentityEvidenceField(
                value: normalizedNativeFallback,
                source: normalizedNativeFallback == nil ? nil : .embeddedExifModel,
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
