import Foundation

/// Decodes DJI's `Xtra` atom (found at `moov/udta/Xtra`): a small
/// WM-attribute-like blob -- not byte-identical to the Microsoft ASF spec,
/// so this deliberately avoids parsing exact preceding field offsets and
/// instead does a robust marker search. Its value is a semicolon-delimited
/// pseudo key=value string, UTF-16LE encoded, e.g.
/// "pb_file:...;model_name:AC006;pb_version:...;pb_lib_version:...;".
/// Verified byte-for-byte identical across four DJI product lines (action
/// cameras, drones, and a gimbal): action-4 (AC003), action-6 (AC006),
/// mini-4-pro (FC8482), pocket-3 (PP-101).
struct DJIXtraMetadataDecoder {
    private static let maxModelCodeUnits = 128
    private static let modelNameMarker: Data = utf16LEBytes(of: "model_name:")

    func decode(_ payload: Data) -> (make: String?, model: String?, serial: String?) {
        guard let markerRange = payload.range(of: Self.modelNameMarker) else {
            return (make: nil, model: nil, serial: nil)
        }

        var offset = markerRange.upperBound
        var codeUnits: [UInt16] = []

        while offset + 1 < payload.endIndex, codeUnits.count < Self.maxModelCodeUnits {
            let unit = UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
            if unit == 0 || unit == UInt16(UnicodeScalar(";").value) {
                break
            }
            codeUnits.append(unit)
            offset += 2
        }

        let model = String(decoding: codeUnits, as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return (make: nil, model: nil, serial: nil)
        }

        return (make: "DJI", model: model, serial: nil)
    }

    private static func utf16LEBytes(of string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }
}
