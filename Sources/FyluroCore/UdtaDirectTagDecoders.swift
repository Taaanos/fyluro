import Foundation

/// Decoders for `moov/udta` atoms that carry a single camera-identity string
/// directly (ported facts: exiftool QuickTime.pm %UserData -- ©mak/©mod,
/// Ricoh's @-variants, Canon CNMN/manu/modl, DJI ©mdl, serial atoms).
///
/// These are lower-confidence than the structured vendor decoders (several
/// are also written by phones and editing software), so
/// `VideoEmbeddedBoxMetadataResolver` applies them only to fields the
/// structured pass left empty.
enum UdtaDirectTagDecoders {
    static var fourCCs: Set<String> { Set(entries.keys) }

    static var registryEntries: [String: VideoVendorAtomDecoder] { entries }

    private static let entries: [String: VideoVendorAtomDecoder] = [
        "\u{A9}mak": { (make: internationalText($0), model: nil, serial: nil) },
        "\u{A9}mod": { (make: nil, model: internationalText($0), serial: nil) },
        // DJI writes ©mdl without the standard size/language header.
        "\u{A9}mdl": { (make: nil, model: rawText($0), serial: nil) },
        // Ricoh Theta models write '@' where the © tags belong.
        "@mak": { (make: rawText($0), model: nil, serial: nil) },
        "@mod": { (make: nil, model: rawText($0), serial: nil) },
        // Apple/pro-app and Canon model-name atoms.
        "cmnm": { (make: nil, model: rawText($0), serial: nil) },
        "CNMN": { (make: nil, model: rawText($0), serial: nil) },
        // Canon SX280 / Samsung: may carry 4 NUL bytes + 2 unknown bytes
        // before the value.
        "manu": { (make: prefixQuirkText($0), model: nil, serial: nil) },
        "modl": { (make: nil, model: prefixQuirkText($0), serial: nil) },
        // Serial-bearing atoms (Apple pro apps, Kodak).
        "slno": { (make: nil, model: nil, serial: rawText($0)) },
        "SNum": { (make: nil, model: nil, serial: rawText($0)) },
        "cmid": { (make: nil, model: nil, serial: rawText($0)) },
    ]

    /// QuickTime international text: [2-byte size][2-byte language][text],
    /// possibly repeated per language -- take the first entry. Some writers
    /// omit the header entirely, so fall back to the raw payload when the
    /// declared size doesn't fit.
    private static func internationalText(_ payload: Data) -> String? {
        let bytes = rebased(payload)
        if bytes.count >= 4 {
            let declared = Int(bytes[0]) << 8 | Int(bytes[1])
            if declared > 0, declared <= bytes.count - 4 {
                return decodeTrimmed(bytes.subdata(in: 4..<(4 + declared)))
            }
        }
        return decodeTrimmed(bytes)
    }

    private static func rawText(_ payload: Data) -> String? {
        decodeTrimmed(rebased(payload))
    }

    private static func prefixQuirkText(_ payload: Data) -> String? {
        var bytes = rebased(payload)
        if bytes.count > 6, bytes.prefix(4).allSatisfy({ $0 == 0 }) {
            bytes = bytes.subdata(in: 6..<bytes.count)
        }
        return decodeTrimmed(bytes)
    }

    private static func decodeTrimmed(_ bytes: Data) -> String? {
        guard !bytes.isEmpty else {
            return nil
        }
        let text: String
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            text = String(data: bytes, encoding: .utf16BigEndian) ?? ""
        } else {
            text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\u{FEFF}"))
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rebased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }
}
