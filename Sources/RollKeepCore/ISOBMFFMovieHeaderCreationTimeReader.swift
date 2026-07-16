import Foundation

/// Reads the mandatory `creation_time` field straight out of an ISO-BMFF
/// file's `moov/mvhd` box header (ISO/IEC 14496-12 §8.2.2) -- a structural
/// field every valid MP4/MOV/M4A carries, distinct from the optional
/// `udta`/`meta` metadata tags `VideoEmbeddedBoxMetadataResolver` decodes.
/// Uses the same bounded, seek-past-payload box walker, so cost stays
/// proportional to box-header count, not file size. Non-ISO-BMFF containers
/// (e.g. RIFF `.WAV`) simply yield no `moov` box and this returns `nil`.
struct ISOBMFFMovieHeaderCreationTimeReader {
    /// Seconds between the QuickTime/Mac epoch (1904-01-01T00:00:00Z) and
    /// the Unix epoch (1970-01-01T00:00:00Z).
    private static let macToUnixEpochOffsetSeconds: TimeInterval = 2_082_844_800

    private let boxWalker: ISOBMFFBoxWalker

    init(boxWalker: ISOBMFFBoxWalker = ISOBMFFBoxWalker()) {
        self.boxWalker = boxWalker
    }

    func creationDate(fileURL: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else {
            return nil
        }

        let topLevelBoxes = boxWalker.readBoxes(in: handle, range: 0..<fileSize)
        guard let moov = boxWalker.firstChild(named: "moov", in: topLevelBoxes) else {
            return nil
        }

        let moovChildren = boxWalker.readBoxes(
            in: handle,
            range: moov.payloadOffset..<(moov.payloadOffset + moov.payloadSize)
        )
        guard let mvhd = boxWalker.firstChild(named: "mvhd", in: moovChildren),
              let payload = boxWalker.readPayload(of: mvhd, from: handle)
        else {
            return nil
        }

        return Self.parseCreationTime(fromMvhdPayload: payload)
    }

    private static func parseCreationTime(fromMvhdPayload payload: Data) -> Date? {
        guard let version = payload.first else {
            return nil
        }

        // version(1) + flags(3) precede the timed fields.
        let fieldsOffset = 4
        let macSeconds: UInt64
        switch version {
        case 0:
            guard payload.count >= fieldsOffset + 4 else {
                return nil
            }
            macSeconds = UInt64(payload.bigEndianUInt32(at: fieldsOffset))
        case 1:
            guard payload.count >= fieldsOffset + 8 else {
                return nil
            }
            macSeconds = payload.bigEndianUInt64(at: fieldsOffset)
        default:
            return nil
        }

        // A zero creation_time means "not set" (common in synthetic/edited
        // files), not a real 1904 timestamp -- treat as absent.
        guard macSeconds > 0 else {
            return nil
        }

        let unixSeconds = TimeInterval(macSeconds) - macToUnixEpochOffsetSeconds
        return Date(timeIntervalSince1970: unixSeconds)
    }
}

private extension Data {
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let bytes = self.subdata(in: (startIndex + offset)..<(startIndex + offset + 4))
        return bytes.reduce(UInt32(0)) { result, byte in (result << 8) | UInt32(byte) }
    }

    func bigEndianUInt64(at offset: Int) -> UInt64 {
        let bytes = self.subdata(in: (startIndex + offset)..<(startIndex + offset + 8))
        return bytes.reduce(UInt64(0)) { result, byte in (result << 8) | UInt64(byte) }
    }
}
