import Foundation

/// Decodes Nikon's `moov/udta/NCDT` atom: a MOV-style container whose NCTG
/// child holds proprietary records of [4-byte tag][2-byte EXIF format code]
/// [2-byte count][value], big-endian (ported facts: exiftool Nikon.pm
/// %NCDT/%NCTG + ProcessNikonMOV). Camera identity: tag 0x01 = Make,
/// 0x02 = Model, 0x110A431 = the NCTG mirror of EXIF BodySerialNumber.
struct NikonNCDTMetadataDecoder {
    private static let tagMake: UInt32 = 0x01
    private static let tagModel: UInt32 = 0x02
    private static let tagBodySerial: UInt32 = 0x110_A431
    private static let asciiFormat = 2
    private static let maxRecords = 4096
    /// EXIF value sizes indexed by format code 1-12.
    private static let formatSizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]

    func decode(_ payload: Data) -> (make: String?, model: String?, serial: String?) {
        for child in ISOBMFFBoxWalker.childBoxes(in: payload) where child.type == "NCTG" {
            return Self.parseNCTG(child.payload)
        }
        return (make: nil, model: nil, serial: nil)
    }

    private static func parseNCTG(_ data: Data) -> (make: String?, model: String?, serial: String?) {
        let bytes = data.startIndex == 0 ? data : Data(data)
        var make: String?
        var model: String?
        var serial: String?
        var offset = 0
        var records = 0

        while bytes.count - offset >= 8, records < maxRecords {
            records += 1
            let tag = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            let format = Int(bytes[offset + 4]) << 8 | Int(bytes[offset + 5])
            let count = Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
            offset += 8

            // Same stop rule as exiftool: an unknown format code means we've
            // lost the record framing.
            guard format >= 1, format < formatSizes.count else {
                break
            }
            let size = count * formatSizes[format] // both <= 0xFFFF; cannot overflow Int
            guard bytes.count - offset >= size else {
                break
            }

            if format == asciiFormat, size > 0 {
                switch tag {
                case tagMake: make = make ?? asciiValue(bytes, offset, size)
                case tagModel: model = model ?? asciiValue(bytes, offset, size)
                case tagBodySerial: serial = serial ?? asciiValue(bytes, offset, size)
                default: break
                }
            }

            offset += size
            if make != nil, model != nil, serial != nil {
                break
            }
        }

        return (make: make, model: model, serial: serial)
    }

    private static func asciiValue(_ bytes: Data, _ offset: Int, _ size: Int) -> String? {
        let raw = bytes.subdata(in: offset..<(offset + size))
        let trimmed = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
