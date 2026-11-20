import Foundation

/// Reads camera identity from a Minolta/Sony MRW file. MRW opens with an
/// 8-byte header -- `\0MRM` (big-endian) or `\0MRI` (little-endian) plus a
/// uint32 giving the total size of the segment block that follows -- then a
/// flat sequence of `[4-byte ASCII tag][4-byte length][payload]` segments.
/// The `\0TTW` segment's payload is a complete standard TIFF (ported fact:
/// exiftool MinoltaRaw.pm ProcessMRW + %Main's `"\0TTW"` entry), so this
/// isolates that one segment and hands it to the unchanged
/// `ExifIFDFieldReader.readTIFF`.
struct MinoltaMRWIdentityReader {
    private static let bigEndianMagic = Data("\0MRM".utf8)
    private static let littleEndianMagic = Data("\0MRI".utf8)
    private static let ttwTag = Data("\0TTW".utf8)
    private static let headerLength = 8
    private static let segmentHeaderLength = 8
    private static let maxSegments = 64
    /// Guards against a corrupt/hostile segment-length field forcing a huge
    /// read (RT-P0-12); real MRW headers are at most
    /// tens of KB.
    private static let maxSegmentReadLength = 8 * 1024 * 1024

    private let exifReader: ExifIFDFieldReader

    init(exifReader: ExifIFDFieldReader = ExifIFDFieldReader()) {
        self.exifReader = exifReader
    }

    func identity(for fileURL: URL) -> ExifIFDFields? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: Self.headerLength),
              header.count == Self.headerLength
        else {
            return nil
        }

        let magic = header.prefix(4)
        let order: ExifByteOrder
        if magic == Self.bigEndianMagic {
            order = .bigEndian
        } else if magic == Self.littleEndianMagic {
            order = .littleEndian
        } else {
            return nil
        }

        guard let blockLength = Self.readUInt32(header, at: 4, order: order) else {
            return nil
        }
        // Segments run from just after this 8-byte header up to
        // blockLength bytes further -- the same offset ProcessMRW reads
        // relative to its position right after the header.
        var position = UInt64(Self.headerLength)
        let segmentsEnd = position + UInt64(blockLength)
        var segmentsRead = 0

        while position + UInt64(Self.segmentHeaderLength) <= segmentsEnd, segmentsRead < Self.maxSegments {
            segmentsRead += 1
            guard (try? handle.seek(toOffset: position)) != nil,
                  let segmentHeader = try? handle.read(upToCount: Self.segmentHeaderLength),
                  segmentHeader.count == Self.segmentHeaderLength
            else {
                return nil
            }
            position += UInt64(Self.segmentHeaderLength)

            let tag = segmentHeader.prefix(4)
            guard let length = Self.readUInt32(segmentHeader, at: 4, order: order) else {
                return nil
            }
            // Overflow-safe: `length` is attacker-controlled file bytes
            // (RT-P0-12).
            let (segmentEnd, overflowed) = position.addingReportingOverflow(UInt64(length))
            guard !overflowed, segmentEnd <= segmentsEnd else {
                return nil
            }

            if tag == Self.ttwTag {
                guard length > 0, length <= Self.maxSegmentReadLength else {
                    return nil
                }
                guard let payload = try? handle.read(upToCount: Int(length)), payload.count == Int(length) else {
                    return nil
                }
                return exifReader.readTIFF(payload)
            }

            position = segmentEnd
        }

        return nil
    }

    private static func readUInt32(_ data: Data, at offset: Int, order: ExifByteOrder) -> UInt32? {
        let base = data.startIndex + offset
        guard offset >= 0, data.endIndex - base >= 4 else {
            return nil
        }
        var value: UInt32 = 0
        if order == .bigEndian {
            for index in 0..<4 {
                value = (value << 8) | UInt32(data[base + index])
            }
        } else {
            for index in (0..<4).reversed() {
                value = (value << 8) | UInt32(data[base + index])
            }
        }
        return value
    }
}
