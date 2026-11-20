import Foundation

/// Canon vendor structures in MOV/MP4/CR3 files (ported facts: exiftool
/// Canon.pm %uuid/%CNTH; QuickTime.pm %Movie uuid dispatch).
enum CanonVideoMetadata {
    /// moov-level uuid 85c0b687-820f-11e0-8111-f4ce462b6a48: written by MP4
    /// compacts (SX280) and by every CR3 still. Its content is MOV-style
    /// child boxes: CMT1 (full TIFF, IFD0), CMT2 (full TIFF, ExifIFD),
    /// CNTH, CNCV, THMB, ...
    static let movieUuidUsertype = Data([
        0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
        0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48,
    ])
}

/// Decodes `moov/udta/CNTH`: its CNDA child is a complete THM JPEG whose
/// EXIF identifies the camera.
struct CanonCNTHMetadataDecoder {
    private let exifReader = ExifIFDFieldReader()

    func decode(_ payload: Data) -> (make: String?, model: String?, serial: String?) {
        for child in ISOBMFFBoxWalker.childBoxes(in: payload) where child.type == "CNDA" {
            if let fields = exifReader.readJPEG(child.payload), fields.hasIdentity {
                return (make: fields.make, model: fields.model, serial: fields.serial)
            }
        }
        return (make: nil, model: nil, serial: nil)
    }
}

/// Decodes the content (usertype already stripped) of the Canon moov-level
/// uuid box.
struct CanonMovieUuidDecoder {
    private let exifReader = ExifIFDFieldReader()
    private let cnthDecoder = CanonCNTHMetadataDecoder()

    func decode(_ content: Data) -> (make: String?, model: String?, serial: String?) {
        var make: String?
        var model: String?
        var serial: String?

        for child in ISOBMFFBoxWalker.childBoxes(in: content) {
            switch child.type {
            case "CMT1", "CMT2":
                // CMT1 carries IFD0 (Make/Model), CMT2 the ExifIFD
                // (BodySerialNumber); both are complete TIFF structures.
                if let fields = exifReader.readTIFF(child.payload) {
                    make = make ?? fields.make
                    model = model ?? fields.model
                    serial = serial ?? fields.serial
                }
            case "CNTH":
                if make == nil || model == nil {
                    let decoded = cnthDecoder.decode(child.payload)
                    make = make ?? decoded.make
                    model = model ?? decoded.model
                    serial = serial ?? decoded.serial
                }
            default:
                break
            }
            if make != nil, model != nil, serial != nil {
                break
            }
        }

        return (make: make, model: model, serial: serial)
    }
}
