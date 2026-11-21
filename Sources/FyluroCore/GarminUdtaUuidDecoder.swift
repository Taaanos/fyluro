import Foundation

/// Decodes the Garmin `moov/udta` uuid box's "GarminModel" content (usertype
/// already stripped by the caller) -- ported facts: exiftool QuickTime.pm
/// %UserData uuid dispatch, Garmin section. Layout after the 16-byte vendor
/// GUID usertype: 8 bytes unknown, 1-byte model-string length, then the
/// model string itself (not NUL-terminated -- the length is exact).
///
/// A matching GUID is proprietary to Garmin, so -- mirroring
/// `GoProGPMFMetadataDecoder`'s "the format itself proves the vendor"
/// reasoning -- a successful decode also asserts `make: "Garmin"`.
struct GarminUdtaUuidDecoder {
    static let usertype = Data([
        0xF7, 0x6C, 0xD7, 0x6A, 0x07, 0x5B, 0x4A, 0x1E,
        0xB3, 0x1C, 0x0E, 0x7F, 0xAB, 0x7E, 0x09, 0xD4,
    ])

    private static let lengthOffset = 8
    private static let modelOffset = 9

    func decode(_ content: Data) -> (make: String?, model: String?, serial: String?) {
        let bytes = content.startIndex == 0 ? content : Data(content)
        guard bytes.count > Self.modelOffset else {
            return (make: nil, model: nil, serial: nil)
        }

        let length = Int(bytes[Self.lengthOffset])
        guard length > 0, bytes.count >= Self.modelOffset + length else {
            return (make: nil, model: nil, serial: nil)
        }

        let raw = bytes.subdata(in: Self.modelOffset..<(Self.modelOffset + length))
        let trimmed = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (make: nil, model: nil, serial: nil)
        }
        return (make: "Garmin", model: trimmed, serial: nil)
    }
}
