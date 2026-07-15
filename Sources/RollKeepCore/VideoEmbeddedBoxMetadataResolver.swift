import Foundation

/// Decodes a single vendor's small metadata atom (already isolated by the box
/// walker) into make/model/serial. Registered by FourCC in
/// `VideoEmbeddedBoxMetadataResolver`'s decoder table -- adding a future
/// vendor format means writing one of these and adding one registry entry.
typealias VideoVendorAtomDecoder = (Data) -> (make: String?, model: String?, serial: String?)

/// Tier-3a: tries to resolve camera make/model/serial by walking the video's
/// ISO-BMFF box tree straight to `moov/udta`'s vendor atoms (GPMF, Xtra,
/// smta, ...) and the top-level `meta/xml ` box, reading only tens of KB
/// regardless of file size (mdat is never read). Falls through to the
/// existing blind head/tail text scan only for whatever this doesn't
/// resolve -- that scan is untouched and remains the safety net for unknown
/// vendors and brands without a decoder yet.
struct VideoEmbeddedBoxMetadataResolver {
    /// ISO-BMFF `FullBox` types (`meta`, and the `xml ` box within it) carry a
    /// 4-byte version+flags header before their real content.
    private static let fullBoxHeaderLength: UInt64 = 4
    private static let maxXMLPayloadReadLength: UInt64 = 1_000_000
    private static let maxUdtaFriendlierModelReadLength: UInt64 = 2_000_000

    private let boxWalker: ISOBMFFBoxWalker
    private let vendorAtomDecoders: [String: VideoVendorAtomDecoder]
    private let xmlDeviceParser: EmbeddedVideoMetadataTextParser
    private let textScanExtractor: (URL, VideoCreationDateParser, Int) -> VideoMetadataSnapshot

    init(
        boxWalker: ISOBMFFBoxWalker = ISOBMFFBoxWalker(),
        vendorAtomDecoders: [String: VideoVendorAtomDecoder] = [:],
        xmlDeviceParser: EmbeddedVideoMetadataTextParser = EmbeddedVideoMetadataTextParser(),
        textScanExtractor: @escaping (URL, VideoCreationDateParser, Int) -> VideoMetadataSnapshot = { fileURL, parser, byteCount in
            EmbeddedVideoMetadataTextParser().extract(from: fileURL, parser: parser, byteCount: byteCount)
        }
    ) {
        self.boxWalker = boxWalker
        self.vendorAtomDecoders = vendorAtomDecoders
        self.xmlDeviceParser = xmlDeviceParser
        self.textScanExtractor = textScanExtractor
    }

    func extract(from fileURL: URL, parser: VideoCreationDateParser, textScanByteCount: Int) -> VideoMetadataSnapshot {
        let boxSnapshot = resolveViaBoxWalk(fileURL: fileURL, parser: parser)

        guard Self.requiresTextScanFallback(boxSnapshot) else {
            return boxSnapshot
        }

        let textSnapshot = textScanExtractor(fileURL, parser, textScanByteCount)
        return Self.merge(primary: boxSnapshot, fallback: textSnapshot)
    }

    private func resolveViaBoxWalk(fileURL: URL, parser: VideoCreationDateParser) -> VideoMetadataSnapshot {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return Self.emptySnapshot
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else {
            return Self.emptySnapshot
        }

        let topLevelBoxes = boxWalker.readBoxes(in: handle, range: 0..<fileSize)

        let udtaSnapshot = resolveUdtaVendorAtom(topLevelBoxes: topLevelBoxes, handle: handle)
        let xmlSnapshot = resolveMetaXML(topLevelBoxes: topLevelBoxes, handle: handle, parser: parser)

        return Self.merge(primary: udtaSnapshot, fallback: xmlSnapshot)
    }

    private func resolveUdtaVendorAtom(topLevelBoxes: [ISOBMFFBox], handle: FileHandle) -> VideoMetadataSnapshot {
        guard !vendorAtomDecoders.isEmpty,
              let moov = boxWalker.firstChild(named: "moov", in: topLevelBoxes)
        else {
            return Self.emptySnapshot
        }

        let moovChildren = boxWalker.readBoxes(
            in: handle,
            range: moov.payloadOffset..<(moov.payloadOffset + moov.payloadSize)
        )
        guard let udta = boxWalker.firstChild(named: "udta", in: moovChildren) else {
            return Self.emptySnapshot
        }

        let udtaChildren = boxWalker.readBoxes(
            in: handle,
            range: udta.payloadOffset..<(udta.payloadOffset + udta.payloadSize)
        )

        for child in udtaChildren {
            guard let decoder = vendorAtomDecoders[child.type],
                  let payload = boxWalker.readPayload(of: child, from: handle)
            else {
                continue
            }

            let decoded = decoder(payload)
            guard decoded.make != nil || decoded.model != nil || decoded.serial != nil else {
                continue
            }

            let selectionRule = "embedded_box_metadata(\(child.type.lowercased()))"
            var resolvedModel = decoded.model
            var resolvedModelSelectionRule = selectionRule

            // Some vendor atoms store a bare internal SKU rather than the
            // retail product name (DJI's Xtra model_name is "AC006", not
            // "DJI Osmo Action 6"). Real product names always contain a
            // space; bare SKUs never do. When the decoder's own model looks
            // like a code, do one cheap, narrowly-scoped lookup (printable
            // strings + a single regex, not the ~20-pattern full text scan)
            // against udta's own bytes -- which we already have from this
            // same box walk -- for a friendlier name before settling.
            if let model = decoded.model, !model.contains(" "),
               let friendlierModel = friendlierModel(inUdta: udta, handle: handle)
            {
                resolvedModel = friendlierModel
                resolvedModelSelectionRule = "embedded_udta_printable_string_match"
            }

            return VideoMetadataSnapshot(
                captureDateTime: nil,
                cameraMake: decoded.make,
                cameraModel: resolvedModel,
                cameraSerial: decoded.serial,
                cameraMakeSource: decoded.make == nil ? nil : .embeddedMetadataMake,
                cameraModelSource: resolvedModel == nil ? nil : .embeddedMetadataModel,
                cameraSerialSource: decoded.serial == nil ? nil : .embeddedMetadataSerial,
                cameraMakeSelectionRule: selectionRule,
                cameraModelSelectionRule: resolvedModelSelectionRule,
                cameraSerialSelectionRule: selectionRule
            )
        }

        return Self.emptySnapshot
    }

    private func friendlierModel(inUdta udta: ISOBMFFBox, handle: FileHandle) -> String? {
        guard let udtaPayload = boxWalker.readPayload(
            of: udta,
            from: handle,
            maxLength: Self.maxUdtaFriendlierModelReadLength
        ) else {
            return nil
        }
        return xmlDeviceParser.findFriendlierModel(in: udtaPayload)
    }

    /// `meta` is a sibling of `moov`, not nested inside it, and holds the Sony
    /// `NonRealTimeMeta` XML in a `meta/xml ` child. Both `meta` and `xml `
    /// are FullBoxes (4-byte version+flags prefix), so each is skipped once.
    /// The extracted XML text is handed to the *existing*
    /// `EmbeddedVideoMetadataTextParser` device-XML regex unchanged.
    private func resolveMetaXML(
        topLevelBoxes: [ISOBMFFBox],
        handle: FileHandle,
        parser: VideoCreationDateParser
    ) -> VideoMetadataSnapshot {
        guard let meta = boxWalker.firstChild(named: "meta", in: topLevelBoxes),
              meta.payloadSize > Self.fullBoxHeaderLength
        else {
            return Self.emptySnapshot
        }

        let metaChildren = boxWalker.readBoxes(
            in: handle,
            range: (meta.payloadOffset + Self.fullBoxHeaderLength)..<(meta.payloadOffset + meta.payloadSize)
        )
        guard let xmlBox = boxWalker.firstChild(named: "xml ", in: metaChildren),
              let xmlPayload = boxWalker.readPayload(of: xmlBox, from: handle, maxLength: Self.maxXMLPayloadReadLength),
              xmlPayload.count > Self.fullBoxHeaderLength
        else {
            return Self.emptySnapshot
        }

        let rawText = String(decoding: xmlPayload.dropFirst(Int(Self.fullBoxHeaderLength)), as: UTF8.self)
        let snapshot = xmlDeviceParser.parse(rawText: rawText, printableStrings: [], parser: parser)

        guard snapshot.cameraMake != nil || snapshot.cameraModel != nil || snapshot.captureDateTime != nil else {
            return Self.emptySnapshot
        }
        return snapshot
    }

    private static func requiresTextScanFallback(_ metadata: VideoMetadataSnapshot) -> Bool {
        metadata.cameraMake == nil && metadata.cameraModel == nil
    }

    private static func merge(primary: VideoMetadataSnapshot, fallback: VideoMetadataSnapshot) -> VideoMetadataSnapshot {
        VideoMetadataSnapshot(
            captureDateTime: primary.captureDateTime ?? fallback.captureDateTime,
            captureDateSource: primary.captureDateSource ?? fallback.captureDateSource,
            cameraMake: primary.cameraMake ?? fallback.cameraMake,
            cameraModel: primary.cameraModel ?? fallback.cameraModel,
            cameraSerial: primary.cameraSerial ?? fallback.cameraSerial,
            cameraMakeSource: primary.cameraMakeSource ?? fallback.cameraMakeSource,
            cameraModelSource: primary.cameraModelSource ?? fallback.cameraModelSource,
            cameraSerialSource: primary.cameraSerialSource ?? fallback.cameraSerialSource,
            cameraMakeSelectionRule: primary.cameraMake != nil ? primary.cameraMakeSelectionRule : fallback.cameraMakeSelectionRule,
            cameraModelSelectionRule: primary.cameraModel != nil ? primary.cameraModelSelectionRule : fallback.cameraModelSelectionRule,
            cameraSerialSelectionRule: primary.cameraSerial != nil ? primary.cameraSerialSelectionRule : fallback.cameraSerialSelectionRule
        )
    }

    private static var emptySnapshot: VideoMetadataSnapshot {
        VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
    }
}
