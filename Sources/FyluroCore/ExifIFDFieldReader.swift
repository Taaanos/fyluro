import Foundation

enum ExifByteOrder: Sendable {
    case littleEndian
    case bigEndian
}

struct ExifIFDFields: Equatable, Sendable {
    var make: String?
    var model: String?
    var serial: String?
    /// DNG UniqueCameraModel (0xC614) -- model fallback for DNGs whose IFD0
    /// Model is missing or names the digitizing software instead of a camera.
    var uniqueCameraModel: String?

    var hasIdentity: Bool {
        make != nil || model != nil || serial != nil || uniqueCameraModel != nil
    }
}

/// Reads camera make/model/serial straight from TIFF/EXIF bytes, with no
/// ImageIO involvement, so identity survives RAW formats the OS decoder does
/// not know yet and EXIF blobs embedded inside vendor video atoms.
///
/// Entry points:
/// - `readTIFF`: a standalone TIFF header (NEF/ARW/DNG/CR2/PEF/..., plus the
///   RAW variants that keep the standard IFD layout behind a different magic
///   word: Panasonic RW2/RWL 0x0055, Olympus ORF "RO"/"SR"/"OR").
/// - `readJPEG`: scans JPEG segments for the APP1 Exif payload.
/// - `readIFD`: a bare IFD at a known offset (vendor video atoms like Fuji
///   MVTG or Casio QVMI, whose value offsets are relative to a caller-known
///   base rather than a TIFF header).
///
/// Every offset/count/length here comes straight from untrusted file bytes:
/// all reads are bounds-checked, entry counts and value sizes are capped, and
/// size arithmetic uses overflow-reporting operations (RT-P0-12).
struct ExifIFDFieldReader: Sendable {
    private static let tagMake: UInt16 = 0x010F
    private static let tagModel: UInt16 = 0x0110
    private static let tagExifIFDPointer: UInt16 = 0x8769
    private static let tagBodySerialNumber: UInt16 = 0xA431
    private static let tagDNGUniqueCameraModel: UInt16 = 0xC614
    private static let tagDNGCameraSerialNumber: UInt16 = 0xC62F

    private static let asciiType: UInt16 = 2
    private static let maxIFDEntries = 512
    private static let maxValueByteCount = 4096
    private static let maxJPEGSegments = 64
    private static let jpegAPP1Marker: UInt8 = 0xE1
    private static let exifHeader = Data("Exif\0\0".utf8)

    /// TIFF magic words accepted after the II/MM order marker: 0x002A is
    /// standard TIFF; 0x0055 is Panasonic RW2/RWL; 0x4F52/0x5352 are Olympus
    /// ORF ("RO"/"SR" little-endian, "OR" big-endian). All keep the standard
    /// IFD0-offset field at byte 4.
    private static let acceptedTIFFMagics: Set<UInt16> = [0x002A, 0x0055, 0x4F52, 0x5352]

    func readTIFF(_ data: Data) -> ExifIFDFields? {
        let bytes = Self.rebased(data)
        guard bytes.count >= 8 else {
            return nil
        }

        let order: ExifByteOrder
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): order = .littleEndian
        case (0x4D, 0x4D): order = .bigEndian
        default: return nil
        }

        guard let magic = Self.readUInt16(bytes, at: 2, order: order),
              Self.acceptedTIFFMagics.contains(magic),
              let ifd0Offset = Self.readUInt32(bytes, at: 4, order: order)
        else {
            return nil
        }

        return collectFields(
            in: bytes,
            ifdOffset: Int(ifd0Offset),
            byteOrder: order,
            offsetsBase: 0,
            followExifIFD: true
        )
    }

    func readJPEG(_ data: Data) -> ExifIFDFields? {
        let bytes = Self.rebased(data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            return nil
        }

        var offset = 2
        for _ in 0..<Self.maxJPEGSegments {
            // Skip fill bytes before the marker.
            while offset < bytes.count, bytes[offset] == 0xFF {
                offset += 1
            }
            guard offset > 2, bytes[offset - 1] == 0xFF, offset < bytes.count else {
                return nil
            }

            let marker = bytes[offset]
            offset += 1

            switch marker {
            case 0xD8, 0x01, 0xD0...0xD7:
                continue // standalone markers, no length field
            case 0xD9, 0xDA:
                return nil // EOI / start of scan: no APP1 Exif before image data
            default:
                break
            }

            guard let length = Self.readUInt16(bytes, at: offset, order: .bigEndian),
                  length >= 2
            else {
                return nil
            }
            let payloadStart = offset + 2
            let payloadLength = Int(length) - 2
            guard bytes.count - payloadStart >= payloadLength else {
                return nil
            }

            if marker == Self.jpegAPP1Marker,
               payloadLength > Self.exifHeader.count,
               bytes.subdata(in: payloadStart..<(payloadStart + Self.exifHeader.count)) == Self.exifHeader
            {
                let tiffStart = payloadStart + Self.exifHeader.count
                return readTIFF(bytes.subdata(in: tiffStart..<(payloadStart + payloadLength)))
            }

            offset = payloadStart + payloadLength
        }

        return nil
    }

    /// Reads one IFD at `ifdOffset` (plus its ExifIFD, if pointed to). Value
    /// offsets inside the IFD are resolved relative to `offsetsBase` -- 0 for
    /// a real TIFF, but vendor atoms embed IFDs whose offsets are relative to
    /// the atom payload start (or some fixed shift of it).
    func readIFD(
        in data: Data,
        at ifdOffset: Int,
        byteOrder: ExifByteOrder,
        offsetsBase: Int
    ) -> ExifIFDFields {
        collectFields(
            in: Self.rebased(data),
            ifdOffset: ifdOffset,
            byteOrder: byteOrder,
            offsetsBase: offsetsBase,
            followExifIFD: true
        )
    }

    private func collectFields(
        in bytes: Data,
        ifdOffset: Int,
        byteOrder order: ExifByteOrder,
        offsetsBase: Int,
        followExifIFD: Bool
    ) -> ExifIFDFields {
        var fields = ExifIFDFields()
        var bodySerial: String?
        var dngSerial: String?
        var exifIFDPointer: Int?

        guard ifdOffset >= 0, let entryCount = Self.readUInt16(bytes, at: ifdOffset, order: order) else {
            return fields
        }

        for index in 0..<min(Int(entryCount), Self.maxIFDEntries) {
            let entryOffset = ifdOffset + 2 + index * 12
            guard let tag = Self.readUInt16(bytes, at: entryOffset, order: order),
                  let type = Self.readUInt16(bytes, at: entryOffset + 2, order: order),
                  let valueCount = Self.readUInt32(bytes, at: entryOffset + 4, order: order)
            else {
                break
            }

            switch tag {
            case Self.tagMake:
                fields.make = fields.make ?? asciiValue(
                    in: bytes, entryOffset: entryOffset, type: type,
                    valueCount: valueCount, order: order, offsetsBase: offsetsBase
                )
            case Self.tagModel:
                fields.model = fields.model ?? asciiValue(
                    in: bytes, entryOffset: entryOffset, type: type,
                    valueCount: valueCount, order: order, offsetsBase: offsetsBase
                )
            case Self.tagDNGUniqueCameraModel:
                fields.uniqueCameraModel = fields.uniqueCameraModel ?? asciiValue(
                    in: bytes, entryOffset: entryOffset, type: type,
                    valueCount: valueCount, order: order, offsetsBase: offsetsBase
                )
            case Self.tagDNGCameraSerialNumber:
                dngSerial = dngSerial ?? asciiValue(
                    in: bytes, entryOffset: entryOffset, type: type,
                    valueCount: valueCount, order: order, offsetsBase: offsetsBase
                )
            case Self.tagBodySerialNumber:
                bodySerial = bodySerial ?? asciiValue(
                    in: bytes, entryOffset: entryOffset, type: type,
                    valueCount: valueCount, order: order, offsetsBase: offsetsBase
                )
            case Self.tagExifIFDPointer where followExifIFD:
                if let pointer = Self.readUInt32(bytes, at: entryOffset + 8, order: order) {
                    exifIFDPointer = Int(pointer)
                }
            default:
                break
            }
        }

        if bodySerial == nil, followExifIFD, let exifIFDPointer {
            let exifFields = collectFields(
                in: bytes,
                ifdOffset: offsetsBase + exifIFDPointer,
                byteOrder: order,
                offsetsBase: offsetsBase,
                followExifIFD: false
            )
            bodySerial = exifFields.serial
        }

        fields.serial = bodySerial ?? dngSerial
        return fields
    }

    private func asciiValue(
        in bytes: Data,
        entryOffset: Int,
        type: UInt16,
        valueCount: UInt32,
        order: ExifByteOrder,
        offsetsBase: Int
    ) -> String? {
        guard type == Self.asciiType, valueCount > 0 else {
            return nil
        }
        // ASCII element size is 1, so the byte count is the value count; the
        // count is attacker-controlled, so clamp before converting.
        guard valueCount <= UInt32(Self.maxValueByteCount) else {
            return nil
        }
        let byteCount = Int(valueCount)

        let valueOffset: Int
        if byteCount <= 4 {
            valueOffset = entryOffset + 8
        } else {
            guard let offset = Self.readUInt32(bytes, at: entryOffset + 8, order: order) else {
                return nil
            }
            valueOffset = offsetsBase + Int(offset)
        }

        guard valueOffset >= 0, bytes.count - valueOffset >= byteCount else {
            return nil
        }

        let raw = bytes.subdata(in: valueOffset..<(valueOffset + byteCount))
        let terminated = raw.prefix { $0 != 0 }
        let trimmed = String(decoding: terminated, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Data slices keep their parent's indices; rebase so absolute offsets
    /// starting at 0 are always valid.
    private static func rebased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }

    private static func readUInt16(_ bytes: Data, at offset: Int, order: ExifByteOrder) -> UInt16? {
        guard offset >= 0, bytes.count - offset >= 2 else {
            return nil
        }
        let b0 = UInt16(bytes[offset])
        let b1 = UInt16(bytes[offset + 1])
        return order == .bigEndian ? (b0 << 8) | b1 : (b1 << 8) | b0
    }

    private static func readUInt32(_ bytes: Data, at offset: Int, order: ExifByteOrder) -> UInt32? {
        guard offset >= 0, bytes.count - offset >= 4 else {
            return nil
        }
        var value: UInt32 = 0
        if order == .bigEndian {
            for i in 0..<4 {
                value = (value << 8) | UInt32(bytes[offset + i])
            }
        } else {
            for i in (0..<4).reversed() {
                value = (value << 8) | UInt32(bytes[offset + i])
            }
        }
        return value
    }
}
