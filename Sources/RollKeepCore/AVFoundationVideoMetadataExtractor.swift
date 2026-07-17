import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct AVFoundationVideoMetadataExtractor: VideoMetadataExtracting {
    public enum EmbeddedFallbackMode: Sendable {
        /// Box-walk vendor-atom decoding, then the blind head/tail text
        /// scan for whatever it doesn't resolve. Used for the real ingest
        /// scan, where full accuracy is worth the (now much smaller) cost.
        case full
        /// Box-walk vendor-atom decoding only -- reads a handful of box
        /// headers plus tens of KB at most, independent of file size -- with
        /// the blind text scan never attempted. Used for the fast preview
        /// scan: strictly more accurate than `disabled` for the vendors with
        /// a decoder, at negligible added cost (single-digit milliseconds
        /// even on a multi-hundred-MB file; see
        /// VideoEmbeddedBoxMetadataResolverBenchmarkTests).
        case structuredOnly
        /// No embedded fallback of any kind; only AVFoundation's primary
        /// metadata and sidecar files are consulted.
        case disabled
    }

    private let parser = VideoCreationDateParser()
    private let embeddedMetadataExtractor: @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    private let sidecarMetadataExtractor: @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    private let embeddedFallbackMode: EmbeddedFallbackMode
    private let cameraIdentityResolver = CameraIdentityResolver()
    private static let embeddedFallbackSearchByteCount = 2 * 1024 * 1024
    /// FourCC-keyed *structured* vendor atom decoders tried by the box
    /// walker before falling back to the blind text scan -- the FourCC alone
    /// proves the format, so these outrank direct string tags and uuid
    /// boxes. Add a future vendor format by writing a `VideoVendorAtomDecoder`
    /// and registering it here. Exposed at internal access (not private) so
    /// `CameraMetadataFixtureRegressionTests` can exercise the exact
    /// production registry instead of a hand-maintained duplicate.
    static let vendorAtomDecoders: [String: VideoVendorAtomDecoder] = [
        "GPMF": GoProGPMFMetadataDecoder().decode,
        "Xtra": DJIXtraMetadataDecoder().decode,
        "smta": SamsungSmtaMetadataDecoder().decode,
        "NCDT": NikonNCDTMetadataDecoder().decode,
        "PANA": PanasonicPANAMetadataDecoder().decode,
        "LEIC": PanasonicPANAMetadataDecoder().decode,
        "CNTH": CanonCNTHMetadataDecoder().decode,
        "TAGS": VendorSignatureTagsDecoder().decode,
    ]

    /// Low-confidence direct string tags -- see `UdtaDirectTagDecoders`'s
    /// own doc comment for why these rank below the structured registry.
    static let directTagDecoders: [String: VideoVendorAtomDecoder] = UdtaDirectTagDecoders.registryEntries

    static let moovUUIDDecoders: [VideoUUIDVendorDecoder] = [
        VideoUUIDVendorDecoder(
            usertype: CanonVideoMetadata.movieUuidUsertype,
            label: "canon",
            decode: CanonMovieUuidDecoder().decode
        ),
    ]

    static let udtaUUIDDecoders: [VideoUUIDVendorDecoder] = [
        VideoUUIDVendorDecoder(
            usertype: GarminUdtaUuidDecoder.usertype,
            label: "garmin",
            decode: GarminUdtaUuidDecoder().decode
        ),
    ]

    public init(embeddedFallbackMode: EmbeddedFallbackMode = .full) {
        self.embeddedFallbackMode = embeddedFallbackMode
        self.sidecarMetadataExtractor = { fileURL, parser in
            VideoSidecarMetadataExtractor().extract(for: fileURL, parser: parser)
        }
        let textScanExtractor: @Sendable (URL, VideoCreationDateParser, Int) -> VideoMetadataSnapshot
        if embeddedFallbackMode == .full {
            textScanExtractor = { fileURL, parser, byteCount in
                EmbeddedVideoMetadataTextParser().extract(from: fileURL, parser: parser, byteCount: byteCount)
            }
        } else {
            textScanExtractor = { _, _, _ in
                VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
            }
        }
        self.embeddedMetadataExtractor = { fileURL, parser in
            VideoEmbeddedBoxMetadataResolver(
                vendorAtomDecoders: Self.vendorAtomDecoders,
                directTagDecoders: Self.directTagDecoders,
                moovUUIDDecoders: Self.moovUUIDDecoders,
                udtaUUIDDecoders: Self.udtaUUIDDecoders,
                textScanExtractor: textScanExtractor
            ).extract(
                from: fileURL,
                parser: parser,
                textScanByteCount: Self.embeddedFallbackSearchByteCount
            )
        }
    }

    init(
        embeddedFallbackMode: EmbeddedFallbackMode = .full,
        sidecarMetadataExtractor: @escaping @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot = { fileURL, parser in
            VideoSidecarMetadataExtractor().extract(for: fileURL, parser: parser)
        },
        embeddedMetadataExtractor: @escaping @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    ) {
        self.embeddedFallbackMode = embeddedFallbackMode
        self.sidecarMetadataExtractor = sidecarMetadataExtractor
        self.embeddedMetadataExtractor = embeddedMetadataExtractor
    }

    public func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        let metadata = extractMetadata(from: fileURL)
        let identity = cameraIdentityResolver.resolveResolvedIdentity(
            make: metadata.cameraMake,
            makeSource: metadata.cameraMakeSource,
            makeSelectionRule: metadata.cameraMakeSelectionRule,
            model: metadata.cameraModel,
            modelSource: metadata.cameraModelSource,
            modelSelectionRule: metadata.cameraModelSelectionRule,
            serial: metadata.cameraSerial,
            serialSource: metadata.cameraSerialSource,
            serialSelectionRule: metadata.cameraSerialSelectionRule
        )
        if let captureDateTime = metadata.captureDateTime {
            let source = metadata.captureDateSource ?? .creationTime
            return VideoMetadata(
                captureDateTime: captureDateTime,
                captureDateSource: source,
                usedFallback: source == .mtimeFallback,
                cameraMake: identity.make,
                cameraModel: identity.model,
                cameraSerial: identity.serial,
                cameraEvidence: identity.evidence
            )
        }

        return VideoMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            usedFallback: true,
            cameraMake: identity.make,
            cameraModel: identity.model,
            cameraSerial: identity.serial,
            cameraEvidence: identity.evidence
        )
    }

    func resolveSidecarFallbackIfNeeded(primary: VideoMetadataSnapshot, fileURL: URL) -> VideoMetadataSnapshot {
        fallbackResolver().resolveSidecarFallbackIfNeeded(primary: primary, fileURL: fileURL)
    }

    func resolveEmbeddedFallbackIfNeeded(primary: VideoMetadataSnapshot, fileURL: URL) -> VideoMetadataSnapshot {
        fallbackResolver().resolveEmbeddedFallbackIfNeeded(primary: primary, fileURL: fileURL)
    }

    static func requiresSidecarFallback(_ metadata: VideoMetadataSnapshot) -> Bool {
        VideoMetadataFallbackResolver.requiresSidecarFallback(metadata)
    }

    static func requiresEmbeddedFallback(_ metadata: VideoMetadataSnapshot) -> Bool {
        VideoMetadataFallbackResolver.requiresEmbeddedFallback(metadata)
    }

    private func fallbackResolver() -> VideoMetadataFallbackResolver {
        VideoMetadataFallbackResolver(
            embeddedFallbackMode: embeddedFallbackMode,
            parser: parser,
            sidecarMetadataExtractor: sidecarMetadataExtractor,
            embeddedMetadataExtractor: embeddedMetadataExtractor
        )
    }

    private func extractMetadata(from fileURL: URL) -> VideoMetadataSnapshot {
        #if canImport(AVFoundation)
            let asset = AVURLAsset(url: fileURL)
            var captureDateTime: Date?
            var cameraMake: String?
            var cameraModel: String?
            var cameraSerial: String?

            consumeMetadataItems(
                asset.commonMetadata,
                captureDateTime: &captureDateTime,
                cameraMake: &cameraMake,
                cameraModel: &cameraModel,
                cameraSerial: &cameraSerial
            )

            for format in asset.availableMetadataFormats {
                consumeMetadataItems(
                    asset.metadata(forFormat: format),
                    captureDateTime: &captureDateTime,
                    cameraMake: &cameraMake,
                    cameraModel: &cameraModel,
                    cameraSerial: &cameraSerial
                )
            }

            let primarySnapshot = VideoMetadataSnapshot(
                captureDateTime: captureDateTime,
                captureDateSource: captureDateTime == nil ? nil : .creationTime,
                cameraMake: cameraMake,
                cameraModel: cameraModel,
                cameraSerial: cameraSerial,
                cameraMakeSource: cameraMake == nil ? nil : .avMetadataMake,
                cameraModelSource: cameraModel == nil ? nil : .avMetadataModel,
                cameraSerialSource: cameraSerial == nil ? nil : .avMetadataSerial,
                cameraMakeSelectionRule: "av_metadata_direct",
                cameraModelSelectionRule: "av_metadata_direct",
                cameraSerialSelectionRule: "av_metadata_direct"
            )
            let sidecarResolvedSnapshot = resolveSidecarFallbackIfNeeded(primary: primarySnapshot, fileURL: fileURL)
            return resolveEmbeddedFallbackIfNeeded(primary: sidecarResolvedSnapshot, fileURL: fileURL)
        #else
            return resolveSidecarFallbackIfNeeded(
                primary: VideoMetadataSnapshot(
                    captureDateTime: nil,
                    captureDateSource: nil,
                    cameraMake: nil,
                    cameraModel: nil,
                    cameraSerial: nil
                ),
                fileURL: fileURL
            )
        #endif
    }

    #if canImport(AVFoundation)
    private func consumeMetadataItems(
        _ items: [AVMetadataItem],
        captureDateTime: inout Date?,
        cameraMake: inout String?,
        cameraModel: inout String?,
        cameraSerial: inout String?
    ) {
        for item in items {
            if captureDateTime == nil, isCreationDateItem(item), let date = dateValue(from: item) {
                captureDateTime = date
            }
            if cameraMake == nil, isMakeItem(item) {
                cameraMake = sanitize(item.stringValue)
            }
            if cameraModel == nil, isModelItem(item) {
                cameraModel = sanitize(item.stringValue)
            }
            if cameraSerial == nil, isSerialItem(item) {
                cameraSerial = sanitize(item.stringValue)
            }
        }
    }

    private func isCreationDateItem(_ item: AVMetadataItem) -> Bool {
        if item.commonKey?.rawValue.lowercased() == "creationdate" {
            return true
        }

        if let identifier = item.identifier?.rawValue.lowercased(),
           identifier.contains("creationdate") || identifier.contains("creation_time")
        {
            return true
        }

        if let key = item.key as? String {
            let normalized = key.lowercased()
            return normalized.contains("creationdate") || normalized.contains("creation_time")
        }

        return false
    }

    private func isMakeItem(_ item: AVMetadataItem) -> Bool {
        if let commonKey = item.commonKey?.rawValue.lowercased(), commonKey == "make" {
            return true
        }

        return keyContainsAny(item, fragments: ["make", "manufacturer"])
    }

    private func isModelItem(_ item: AVMetadataItem) -> Bool {
        if let commonKey = item.commonKey?.rawValue.lowercased(), commonKey == "model" {
            return true
        }

        return keyContainsAny(item, fragments: ["model"])
    }

    private func isSerialItem(_ item: AVMetadataItem) -> Bool {
        keyContainsAny(item, fragments: ["serial"])
    }

    private func keyContainsAny(_ item: AVMetadataItem, fragments: [String]) -> Bool {
        if let identifier = item.identifier?.rawValue.lowercased(),
           fragments.contains(where: { identifier.contains($0) }) {
            return true
        }

        if let key = item.key as? String {
            let normalized = key.lowercased()
            return fragments.contains(where: { normalized.contains($0) })
        }

        return false
    }

    private func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func dateValue(from item: AVMetadataItem) -> Date? {
        if let date = item.dateValue {
            return date
        }

        if let raw = item.stringValue {
            return parser.parse(raw)
        }

        return nil
    }
    #endif
}
