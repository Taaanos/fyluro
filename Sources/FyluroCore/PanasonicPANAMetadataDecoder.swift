import Foundation

/// Decodes the Panasonic/Leica `moov/udta/PANA` (and `LEIC`) atom: a fixed
/// binary block (ported facts: exiftool Panasonic.pm %PANA). Leica payloads
/// start with the make string ("LEICA...") at 0x00 with the model at 0x16;
/// Panasonic payloads carry no make string -- the atom itself is the vendor
/// evidence -- with the model at 0x04, or at 0x0C on models like the FZ1000.
struct PanasonicPANAMetadataDecoder {
    private static let leicaMakeOffset = 0
    private static let leicaMakeMaxLength = 22
    private static let leicaModelOffset = 0x16
    private static let leicaModelMaxLength = 30
    private static let panasonicModelOffsets = [0x04, 0x0C]
    private static let panasonicModelMaxLength = 16
    /// exiftool requires 6 leading non-NUL bytes before trusting a model
    /// field; mirror that so structured garbage doesn't become a label.
    private static let minimumModelLength = 6

    func decode(_ payload: Data) -> (make: String?, model: String?, serial: String?) {
        let bytes = payload.startIndex == 0 ? payload : Data(payload)

        if bytes.starts(with: Data("LEICA".utf8)) {
            let make = Self.printableRun(in: bytes, from: Self.leicaMakeOffset, maxLength: Self.leicaMakeMaxLength)
            let model = Self.printableRun(in: bytes, from: Self.leicaModelOffset, maxLength: Self.leicaModelMaxLength)
            return (make: make, model: model, serial: nil)
        }

        for offset in Self.panasonicModelOffsets {
            if let model = Self.printableRun(in: bytes, from: offset, maxLength: Self.panasonicModelMaxLength),
               model.count >= Self.minimumModelLength
            {
                return (make: "Panasonic", model: model, serial: nil)
            }
        }

        return (make: nil, model: nil, serial: nil)
    }

    private static func printableRun(in bytes: Data, from offset: Int, maxLength: Int) -> String? {
        guard offset >= 0, offset < bytes.count, maxLength > 0 else {
            return nil
        }
        var run: [UInt8] = []
        for index in offset..<min(offset + maxLength, bytes.count) {
            let byte = bytes[index]
            guard byte >= 0x20, byte <= 0x7E else {
                break
            }
            run.append(byte)
        }
        let trimmed = String(decoding: run, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
