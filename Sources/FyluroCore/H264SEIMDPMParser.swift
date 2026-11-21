import Foundation

/// Extracts camera make/model from an H.264 Annex-B elementary-stream
/// buffer's SEI (Supplemental Enhancement Information) NAL units -- the
/// mechanism AVCHD camcorders use to embed "MDPM" (ModifiedDVPackMeta)
/// device-identity records directly in the video bitstream, since
/// MPEG-TS/M2TS containers have no `udta`-equivalent metadata box (ported
/// facts: exiftool H264.pm ParseH264Video/ProcessSEI + the MDPM/MakeModel
/// tag tables).
///
/// Layout, innermost first:
/// - MDPM entry: `[1-byte tag][4-byte big-endian value]`, 5 bytes each.
///   Tag 0xE0's value is itself two big-endian uint16 fields (Make code at
///   offset 0, an unused field at offset 2). Tag 0xE4 (Sony only) is a
///   3-entry run (0xE4/0xE5/0xE6) whose values concatenate into a single
///   12-byte ASCII Model string.
/// - SEI "unregistered user data" payload (type 5): a fixed 16-byte vendor
///   UUID (`17ee8c60-f84d-11d9-8cd6-0800200c9a66`) + ASCII "MDPM" + a
///   1-byte entry count, then that many MDPM entries.
/// - SEI RBSP: a sequence of `[type][size]` pairs, each field using a
///   "0xFF continuation" varint (keep reading and summing 0xFF bytes until
///   a byte less than 0xFF terminates it), followed by `size` bytes of
///   payload. We only care about type 5.
/// - NAL unit (type 0x06 = SEI): Annex-B `00 00 01`/`00 00 00 01` start
///   codes delimit NAL units in the outer elementary stream; a NAL unit's
///   own payload additionally escapes literal `00 00 03` to `00 00 03 XX`
///   (emulation prevention), which must be undone before SEI parsing.
struct H264SEIMDPMParser {
    /// exiftool H264.pm %convMake -- numeric device codes at MDPM tag 0xE0.
    private static let makeCodes: [UInt16: String] = [
        0x0103: "Panasonic",
        0x0108: "Sony",
        0x1011: "Canon",
        0x1104: "JVC",
    ]

    private static let mdpmUUIDAndMarker = Data([
        0x17, 0xEE, 0x8C, 0x60, 0xF8, 0x4D, 0x11, 0xD9,
        0x8C, 0xD6, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
    ]) + Data("MDPM".utf8)

    private static let tagMakeModel: UInt8 = 0xE0
    private static let tagModelStart: UInt8 = 0xE4
    private static let seiTypeUnregisteredUserData = 5
    private static let maxNALUnitLength = 4 * 1024 * 1024
    private static let maxMDPMEntries = 255 // the entry count field is one byte

    func parse(_ elementaryStream: Data) -> (make: String?, model: String?) {
        let bytes = elementaryStream.startIndex == 0 ? elementaryStream : Data(elementaryStream)

        for nalUnit in Self.nalUnits(in: bytes, type: 0x06) {
            if let result = parseSEI(Self.removeEmulationPrevention(nalUnit)), result.make != nil || result.model != nil {
                return result
            }
        }
        return (make: nil, model: nil)
    }

    /// Splits `bytes` on `00 00 01`/`00 00 00 01` start codes and yields the
    /// payload of every NAL unit whose type (low 5 bits of the first byte,
    /// after the forbidden-zero-bit check) matches `type`. Payloads are
    /// capped so a corrupt/hostile stream with no further start code can't
    /// force an unbounded read (RT-P0-12).
    private static func nalUnits(in bytes: Data, type: UInt8) -> [Data] {
        var results: [Data] = []
        var searchStart = bytes.startIndex

        while let startCodeRange = findStartCode(in: bytes, from: searchStart) {
            let nalStart = startCodeRange.upperBound
            guard nalStart < bytes.endIndex else {
                break
            }
            let header = bytes[nalStart]
            searchStart = nalStart
            guard header & 0x80 == 0 else {
                continue // forbidden_zero_bit set: not a real NAL header, keep scanning
            }
            let nalUnitType = header & 0x1F

            let nextStartCodeRange = findStartCode(in: bytes, from: bytes.index(after: nalStart))
            let nalEnd = nextStartCodeRange?.lowerBound ?? bytes.endIndex

            if nalUnitType == type, nalEnd > nalStart {
                let cappedEnd = bytes.index(nalStart, offsetBy: min(nalEnd - nalStart, maxNALUnitLength))
                // Skip the 1-byte NAL header itself; RBSP payload starts after it.
                let payloadStart = bytes.index(after: nalStart)
                if cappedEnd > payloadStart {
                    results.append(bytes.subdata(in: payloadStart..<cappedEnd))
                }
            }
        }
        return results
    }

    /// A start code is `00 00 01`, optionally preceded by one more `00`
    /// (`00 00 00 01`); returns the range of the code itself (not the
    /// optional leading zero), so callers can treat both forms uniformly.
    private static func findStartCode(in bytes: Data, from start: Data.Index) -> Range<Data.Index>? {
        var index = start
        while index + 3 <= bytes.endIndex {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                return index..<(index + 3)
            }
            index += 1
        }
        return nil
    }

    /// Undoes H.264's emulation-prevention byte stuffing: `00 00 03` inside
    /// a NAL payload means "the two zero bytes were real, insert-and-ignore
    /// this 0x03" -- replace each such run with just the two zero bytes.
    private static func removeEmulationPrevention(_ nalPayload: Data) -> Data {
        let bytes = nalPayload.startIndex == 0 ? nalPayload : Data(nalPayload)
        var result = Data(capacity: bytes.count)
        var zeroRun = 0

        for byte in bytes {
            if zeroRun >= 2, byte == 0x03 {
                zeroRun = 0
                continue
            }
            result.append(byte)
            zeroRun = (byte == 0) ? zeroRun + 1 : 0
        }
        return result
    }

    private func parseSEI(_ sei: Data) -> (make: String?, model: String?)? {
        let bytes = sei.startIndex == 0 ? sei : Data(sei)
        var pos = bytes.startIndex

        while pos < bytes.endIndex {
            guard let (payloadType, afterType) = Self.readContinuationValue(bytes, from: pos) else {
                return nil
            }
            guard payloadType != 0x80 else {
                return nil // terminator/alignment bits
            }
            guard let (payloadSize, afterSize) = Self.readContinuationValue(bytes, from: afterType) else {
                return nil
            }
            guard bytes.endIndex - afterSize >= payloadSize else {
                return nil
            }

            if payloadType == Self.seiTypeUnregisteredUserData {
                return parseUnregisteredUserData(bytes, at: afterSize, size: payloadSize)
            }
            pos = bytes.index(afterSize, offsetBy: payloadSize)
        }
        return nil
    }

    /// Reads exiftool's "sum of 0xFF bytes plus one terminating byte < 0xFF"
    /// varint encoding used for both the SEI payload type and size fields.
    private static func readContinuationValue(_ bytes: Data, from start: Data.Index) -> (value: Int, next: Data.Index)? {
        var value = 0
        var index = start
        while true {
            guard index < bytes.endIndex else {
                return nil
            }
            let byte = bytes[index]
            index += 1
            value += Int(byte)
            if byte != 0xFF {
                break
            }
        }
        return (value, index)
    }

    private func parseUnregisteredUserData(_ bytes: Data, at start: Data.Index, size: Int) -> (make: String?, model: String?)? {
        guard size > Self.mdpmUUIDAndMarker.count,
              bytes[start..<(start + Self.mdpmUUIDAndMarker.count)] == Self.mdpmUUIDAndMarker
        else {
            return nil
        }

        let end = bytes.index(start, offsetBy: size)
        var pos = bytes.index(start, offsetBy: Self.mdpmUUIDAndMarker.count)
        guard pos < end else {
            return nil
        }
        let entryCount = Int(bytes[pos])
        pos = bytes.index(after: pos)

        var make: String?
        var modelBytes = Data()
        var lastTag: UInt8 = 0
        var nextExpectedModelTag = Self.tagModelStart

        for _ in 0..<min(entryCount, Self.maxMDPMEntries) {
            guard bytes.index(pos, offsetBy: 5) <= end else {
                break
            }
            let tag = bytes[pos]
            guard tag > lastTag else {
                break // exiftool: entries must be in strictly increasing tag order
            }
            lastTag = tag
            let valueStart = bytes.index(after: pos)
            let value = bytes[valueStart..<bytes.index(valueStart, offsetBy: 4)]

            if tag == Self.tagMakeModel {
                let makeCode = UInt16(value[value.startIndex]) << 8 | UInt16(value[value.startIndex + 1])
                make = Self.makeCodes[makeCode]
            } else if tag == nextExpectedModelTag, nextExpectedModelTag < Self.tagModelStart + 3 {
                modelBytes.append(contentsOf: value)
                nextExpectedModelTag += 1
            }

            pos = bytes.index(pos, offsetBy: 5)
        }

        let model = Self.trimmedASCIIString(modelBytes)
        guard make != nil || model != nil else {
            return nil
        }
        return (make: make, model: model)
    }

    private static func trimmedASCIIString(_ data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }
        let trimmed = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
