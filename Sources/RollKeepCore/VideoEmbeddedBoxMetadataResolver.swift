import Foundation

/// Decodes a single vendor's small metadata atom (already isolated by the box
/// walker) into make/model/serial. Registered by FourCC in
/// `VideoEmbeddedBoxMetadataResolver`'s decoder table -- adding a future
/// vendor format means writing one of these and adding one registry entry.
typealias VideoVendorAtomDecoder = (Data) -> (make: String?, model: String?, serial: String?)

/// A `VideoVendorAtomDecoder` scoped to a specific `uuid` box usertype GUID,
/// tried against `moov`- or `udta`-level uuid children (Canon's CR3/MP4
/// vendor uuid is a moov child; Garmin's is a udta child). `label` names the
/// vendor in the resulting evidence selection rule.
struct VideoUUIDVendorDecoder {
    let usertype: Data
    let label: String
    let decode: VideoVendorAtomDecoder
}

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
    /// Structured vendor atoms: the FourCC alone identifies the format
    /// unambiguously (GPMF, Xtra, smta, NCDT, PANA/LEIC, CNTH, TAGS, ...).
    private let vendorAtomDecoders: [String: VideoVendorAtomDecoder]
    /// Low-confidence single-string tags (©mak/©mod/manu/modl/...) that
    /// generic MOV writers and editing software can also emit. Consulted
    /// only for fields the structured/uuid tiers left empty.
    private let directTagDecoders: [String: VideoVendorAtomDecoder]
    /// uuid boxes that are direct children of `moov` (Canon CR3/MP4).
    private let moovUUIDDecoders: [VideoUUIDVendorDecoder]
    /// uuid boxes that are children of `udta` (Garmin).
    private let udtaUUIDDecoders: [VideoUUIDVendorDecoder]
    private let xmlDeviceParser: EmbeddedVideoMetadataTextParser
    private let textScanExtractor: (URL, VideoCreationDateParser, Int) -> VideoMetadataSnapshot

    init(
        boxWalker: ISOBMFFBoxWalker = ISOBMFFBoxWalker(),
        vendorAtomDecoders: [String: VideoVendorAtomDecoder] = [:],
        directTagDecoders: [String: VideoVendorAtomDecoder] = [:],
        moovUUIDDecoders: [VideoUUIDVendorDecoder] = [],
        udtaUUIDDecoders: [VideoUUIDVendorDecoder] = [],
        xmlDeviceParser: EmbeddedVideoMetadataTextParser = EmbeddedVideoMetadataTextParser(),
        textScanExtractor: @escaping (URL, VideoCreationDateParser, Int) -> VideoMetadataSnapshot = { fileURL, parser, byteCount in
            EmbeddedVideoMetadataTextParser().extract(from: fileURL, parser: parser, byteCount: byteCount)
        }
    ) {
        self.boxWalker = boxWalker
        self.vendorAtomDecoders = vendorAtomDecoders
        self.directTagDecoders = directTagDecoders
        self.moovUUIDDecoders = moovUUIDDecoders
        self.udtaUUIDDecoders = udtaUUIDDecoders
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

    /// Combines every `moov`/`udta` identity source in confidence order:
    /// structured vendor atoms (FourCC alone proves the format) and vendor
    /// uuid boxes rank above low-confidence direct string tags, which only
    /// fill fields the higher tiers left empty. Canon's uuid is a *moov*
    /// child (found even when there is no `udta` at all, e.g. some MP4
    /// compacts), so it is resolved before `udta` is required to exist.
    private func resolveUdtaVendorAtom(topLevelBoxes: [ISOBMFFBox], handle: FileHandle) -> VideoMetadataSnapshot {
        guard let moov = boxWalker.firstChild(named: "moov", in: topLevelBoxes) else {
            return Self.emptySnapshot
        }

        let moovChildren = boxWalker.readBoxes(
            in: handle,
            range: moov.payloadOffset..<(moov.payloadOffset + moov.payloadSize)
        )

        let moovUUIDSnapshot = resolveUUID(in: moovChildren, handle: handle, decoders: moovUUIDDecoders, level: "moov")

        guard let udta = boxWalker.firstChild(named: "udta", in: moovChildren) else {
            return moovUUIDSnapshot
        }

        let udtaChildren = boxWalker.readBoxes(
            in: handle,
            range: udta.payloadOffset..<(udta.payloadOffset + udta.payloadSize)
        )

        let structuredSnapshot = resolveStructuredUdtaAtom(udtaChildren: udtaChildren, udta: udta, handle: handle)
        let udtaUUIDSnapshot = resolveUUID(in: udtaChildren, handle: handle, decoders: udtaUUIDDecoders, level: "udta")
        let directTagSnapshot = resolveUdtaDirectTags(udtaChildren: udtaChildren, handle: handle)

        let vendorFormatSnapshot = Self.merge(
            primary: structuredSnapshot,
            fallback: Self.merge(primary: moovUUIDSnapshot, fallback: udtaUUIDSnapshot)
        )
        return Self.merge(primary: vendorFormatSnapshot, fallback: directTagSnapshot)
    }

    private func resolveStructuredUdtaAtom(
        udtaChildren: [ISOBMFFBox],
        udta: ISOBMFFBox,
        handle: FileHandle
    ) -> VideoMetadataSnapshot {
        guard !vendorAtomDecoders.isEmpty else {
            return Self.emptySnapshot
        }

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

    /// Tries each registered uuid decoder against whichever of `boxes`
    /// carries a matching usertype GUID. `level` ("moov" or "udta") only
    /// feeds the evidence selection rule, so a receipt can tell the two
    /// apart.
    private func resolveUUID(
        in boxes: [ISOBMFFBox],
        handle: FileHandle,
        decoders: [VideoUUIDVendorDecoder],
        level: String
    ) -> VideoMetadataSnapshot {
        guard !decoders.isEmpty else {
            return Self.emptySnapshot
        }

        for box in boxes where box.type == "uuid" {
            guard let usertype = box.uuidUsertype,
                  let matched = decoders.first(where: { $0.usertype == usertype }),
                  let content = boxWalker.readUUIDBoxContent(usertype: usertype, among: boxes, from: handle)
            else {
                continue
            }

            let decoded = matched.decode(content)
            guard decoded.make != nil || decoded.model != nil || decoded.serial != nil else {
                continue
            }

            let selectionRule = "embedded_box_metadata(\(level)_uuid_\(matched.label))"
            return VideoMetadataSnapshot(
                captureDateTime: nil,
                cameraMake: decoded.make,
                cameraModel: decoded.model,
                cameraSerial: decoded.serial,
                cameraMakeSource: decoded.make == nil ? nil : .embeddedMetadataMake,
                cameraModelSource: decoded.model == nil ? nil : .embeddedMetadataModel,
                cameraSerialSource: decoded.serial == nil ? nil : .embeddedMetadataSerial,
                cameraMakeSelectionRule: selectionRule,
                cameraModelSelectionRule: selectionRule,
                cameraSerialSelectionRule: selectionRule
            )
        }

        return Self.emptySnapshot
    }

    /// Accumulates across every direct-tag child (unlike the structured
    /// pass, which hands off entirely to the first matching atom): a file
    /// can carry make in one atom and model in a different one, and each
    /// decoder here only ever resolves a single field.
    private func resolveUdtaDirectTags(udtaChildren: [ISOBMFFBox], handle: FileHandle) -> VideoMetadataSnapshot {
        guard !directTagDecoders.isEmpty else {
            return Self.emptySnapshot
        }

        var make: String?
        var model: String?
        var serial: String?
        var makeRule = "unresolved"
        var modelRule = "unresolved"
        var serialRule = "unresolved"

        for child in udtaChildren {
            guard make == nil || model == nil || serial == nil else {
                break
            }
            guard let decoder = directTagDecoders[child.type],
                  let payload = boxWalker.readPayload(of: child, from: handle)
            else {
                continue
            }

            let decoded = decoder(payload)
            let selectionRule = "embedded_box_metadata(\(child.type.lowercased()))"
            if make == nil, let value = decoded.make {
                make = value
                makeRule = selectionRule
            }
            if model == nil, let value = decoded.model {
                model = value
                modelRule = selectionRule
            }
            if serial == nil, let value = decoded.serial {
                serial = value
                serialRule = selectionRule
            }
        }

        guard make != nil || model != nil || serial != nil else {
            return Self.emptySnapshot
        }
        return VideoMetadataSnapshot(
            captureDateTime: nil,
            cameraMake: make,
            cameraModel: model,
            cameraSerial: serial,
            cameraMakeSource: make == nil ? nil : .embeddedMetadataMake,
            cameraModelSource: model == nil ? nil : .embeddedMetadataModel,
            cameraSerialSource: serial == nil ? nil : .embeddedMetadataSerial,
            cameraMakeSelectionRule: makeRule,
            cameraModelSelectionRule: modelRule,
            cameraSerialSelectionRule: serialRule
        )
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
