import Foundation

/// Decodes GoPro's `GPMF` atom (found at `moov/udta/GPMF`): a binary KLV
/// format, repeated entries of `[4-byte FourCC key][1-byte type][1-byte
/// element size][2-byte element count (big-endian)][size*count payload,
/// padded to 4-byte alignment]`. Type `0x00` marks a nested container whose
/// payload is itself another KLV sequence. Reference (read-only, not
/// vendored): https://github.com/gopro/gpmf-parser (MIT/Apache-2.0).
struct GoProGPMFMetadataDecoder {
    private static let headerLength = 8
    private static let maxDepth = 16
    private static let containerType: UInt8 = 0x00
    private static let stringType: UInt8 = UInt8(ascii: "c")
    private static let modelKey = "MINF"
    private static let serialKey = "CASN"

    func decode(_ payload: Data) -> (make: String?, model: String?, serial: String?) {
        var model: String?
        var serial: String?

        walk(payload, depth: 0) { key, type, entryPayload in
            guard type == Self.stringType else {
                return
            }
            if model == nil, key == Self.modelKey {
                model = string(from: entryPayload)
            }
            if serial == nil, key == Self.serialKey {
                serial = string(from: entryPayload)
            }
        }

        guard model != nil || serial != nil else {
            return (make: nil, model: nil, serial: nil)
        }
        return (make: "GoPro", model: model, serial: serial)
    }

    private func walk(_ data: Data, depth: Int, visit: (String, UInt8, Data) -> Void) {
        guard depth < Self.maxDepth else {
            return
        }

        var offset = data.startIndex
        while offset + Self.headerLength <= data.endIndex {
            let key = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let type = data[offset + 4]
            let elementSize = Int(data[offset + 5])
            let count = Int(data[offset + 6]) << 8 | Int(data[offset + 7])
            let payloadLength = elementSize * count

            let payloadStart = offset + Self.headerLength
            let payloadEnd = payloadStart + payloadLength
            guard payloadEnd >= payloadStart, payloadEnd <= data.endIndex else {
                break
            }

            let entryPayload = data[payloadStart..<payloadEnd]
            if type == Self.containerType {
                walk(entryPayload, depth: depth + 1, visit: visit)
            } else {
                visit(key, type, entryPayload)
            }

            let paddedLength = ((payloadLength + 3) / 4) * 4
            offset = payloadStart + paddedLength
        }
    }

    private func string(from data: Data) -> String? {
        let terminatorIndex = data.firstIndex(of: 0) ?? data.endIndex
        let trimmed = String(decoding: data[data.startIndex..<terminatorIndex], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
