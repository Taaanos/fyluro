import Foundation

/// Decodes the `moov/udta/TAGS` atom: a fixed binary block whose leading
/// bytes are a vendor signature string that doubles as the Make, with the
/// model at a vendor-specific offset (ported facts: exiftool QuickTime.pm
/// %UserData TAGS dispatch + the per-vendor MOV tables in FujiFilm.pm,
/// Nikon.pm, Olympus.pm, Pentax.pm, Samsung.pm, Kodak.pm, Minolta.pm,
/// Sanyo.pm -- Make is string[21..32] at 0x00; Model, where present, is a
/// string at 0x18 (0x16 for Kodak); Pentax/Minolta/Sanyo carry no usable
/// model in this atom).
struct VendorSignatureTagsDecoder {
    private struct Layout {
        let signature: String
        let modelOffset: Int?
        let modelMaxLength: Int
    }

    /// Longer signatures first so "KONICA MINOLTA ..." wins over "MINOLTA ...".
    private static let layouts: [Layout] = [
        Layout(signature: "KONICA MINOLTA DIGITAL CAMERA", modelOffset: nil, modelMaxLength: 0),
        Layout(signature: "FUJIFILM DIGITAL CAMERA", modelOffset: 0x18, modelMaxLength: 16),
        Layout(signature: "NIKON DIGITAL CAMERA", modelOffset: 0x18, modelMaxLength: 24),
        Layout(signature: "OLYMPUS DIGITAL CAMERA", modelOffset: 0x18, modelMaxLength: 24),
        Layout(signature: "SAMSUNG DIGITAL CAMERA", modelOffset: 0x18, modelMaxLength: 16),
        Layout(signature: "EASTMAN KODAK COMPANY", modelOffset: 0x16, modelMaxLength: 42),
        Layout(signature: "PENTAX DIGITAL CAMERA", modelOffset: nil, modelMaxLength: 0),
        Layout(signature: "MINOLTA DIGITAL CAMERA", modelOffset: nil, modelMaxLength: 0),
        Layout(signature: "SANYO DIGITAL CAMERA", modelOffset: nil, modelMaxLength: 0),
    ]

    private static let makeMaxLength = 32

    func decode(_ payload: Data) -> (make: String?, model: String?, serial: String?) {
        let bytes = payload.startIndex == 0 ? payload : Data(payload)

        guard let layout = Self.layouts.first(where: { bytes.starts(with: Data($0.signature.utf8)) }) else {
            return (make: nil, model: nil, serial: nil)
        }

        // The make field is the signature string itself (matches what
        // exiftool reports, e.g. "PENTAX DIGITAL CAMERA").
        let make = Self.printableRun(in: bytes, from: 0, maxLength: Self.makeMaxLength)
        var model: String?
        if let modelOffset = layout.modelOffset {
            model = Self.printableRun(in: bytes, from: modelOffset, maxLength: layout.modelMaxLength)
        }
        return (make: make, model: model, serial: nil)
    }

    /// Reads a run of printable ASCII starting at `offset`, stopping at the
    /// first NUL or non-printable byte -- the vendor blocks NUL-pad their
    /// string fields and follow them with binary data (e.g. Nikon's `01 00`
    /// right after an 8-byte model field), so this never needs the exact
    /// per-vendor field length to stay inside the string.
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
