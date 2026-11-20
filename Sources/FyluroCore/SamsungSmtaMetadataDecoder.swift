import Foundation

/// Decodes Samsung's `smta` atom (found at `moov/udta/smta`): a small
/// FullBox (4-byte version+flags prefix, value 0) followed by standard
/// nested `[4-byte size][4-byte FourCC][size-8 bytes value]` sub-entries
/// (`saut`, `mdln`, ...). The `mdln` entry holds the model string, e.g.
/// "SM-A546B". Confirmed byte-for-byte against a real fixture; this reads
/// like the same box-header shape `ISOBMFFBoxWalker` understands, but the
/// payload is already fully in memory here (a few dozen bytes) so it's
/// walked directly rather than round-tripping through a `FileHandle`.
struct SamsungSmtaMetadataDecoder {
    private static let fullBoxHeaderLength = 4
    private static let entryHeaderLength = 8
    private static let modelKey = "mdln"

    func decode(_ payload: Data) -> (make: String?, model: String?, serial: String?) {
        guard payload.count > Self.fullBoxHeaderLength else {
            return (make: nil, model: nil, serial: nil)
        }

        var offset = payload.startIndex + Self.fullBoxHeaderLength
        while offset + Self.entryHeaderLength <= payload.endIndex {
            let declaredSize = Int(bigEndianUInt32: payload[offset..<(offset + 4)])
            let key = String(decoding: payload[(offset + 4)..<(offset + 8)], as: UTF8.self)

            guard declaredSize >= Self.entryHeaderLength else {
                break
            }
            let entryEnd = offset + declaredSize
            guard entryEnd >= offset, entryEnd <= payload.endIndex else {
                break
            }

            if key == Self.modelKey {
                let value = payload[(offset + Self.entryHeaderLength)..<entryEnd]
                let model = String(decoding: value, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !model.isEmpty {
                    return (make: "Samsung", model: model, serial: nil)
                }
            }

            offset = entryEnd
        }

        return (make: nil, model: nil, serial: nil)
    }
}

private extension Int {
    init(bigEndianUInt32 data: Data) {
        self = data.reduce(0) { ($0 << 8) | Int($1) }
    }
}
