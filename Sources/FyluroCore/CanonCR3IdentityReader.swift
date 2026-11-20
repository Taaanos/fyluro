import Foundation

/// Reads camera identity from a Canon CR3 (or MP4-container Canon still)
/// file: CR3 is not a TIFF -- it's an ISO-BMFF/MP4-style container, with
/// identity in the same moov-level Canon uuid box (85c0b687...) that MOV/MP4
/// videos carry, holding CMT1 (IFD0)/CMT2 (ExifIFD) as full embedded TIFFs
/// (ported facts: exiftool Canon.pm %uuid; see M1's `CanonMovieUuidDecoder`,
/// which this reuses unchanged for the box's content). Header-only reads via
/// `ISOBMFFBoxWalker`, matching the rest of this codebase's I/O budget.
struct CanonCR3IdentityReader {
    private let boxWalker: ISOBMFFBoxWalker
    private let decoder: CanonMovieUuidDecoder

    init(boxWalker: ISOBMFFBoxWalker = ISOBMFFBoxWalker(), decoder: CanonMovieUuidDecoder = CanonMovieUuidDecoder()) {
        self.boxWalker = boxWalker
        self.decoder = decoder
    }

    func identity(for fileURL: URL) -> (make: String?, model: String?, serial: String?)? {
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
        guard let content = boxWalker.readUUIDBoxContent(
            usertype: CanonVideoMetadata.movieUuidUsertype,
            among: moovChildren,
            from: handle
        ) else {
            return nil
        }

        let decoded = decoder.decode(content)
        guard decoded.make != nil || decoded.model != nil || decoded.serial != nil else {
            return nil
        }
        return decoded
    }
}
