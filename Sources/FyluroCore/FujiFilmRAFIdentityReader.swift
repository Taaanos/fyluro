import Foundation

/// Reads camera identity from a FujiFilm RAF file. RAF opens with a
/// `FUJIFILM`-signed 0x70-byte header; exiftool's own RAFHeader tag table
/// has no separate Model field at all -- the offset-0 text blob
/// ("FUJIFILMCCD-RAW ...FinePix S5Pro") is just a source comment, never
/// extracted as a tag. What exiftool actually reports Make/Model/Serial
/// from is the embedded JPEG preview's own EXIF, located via a big-endian
/// [offset,length] uint32 pair at header bytes 0x54/0x58 (ported fact:
/// exiftool FujiFilm.pm ProcessRAF). Reuses `ExifIFDFieldReader.readJPEG`
/// unchanged once that preview is isolated.
struct FujiFilmRAFIdentityReader {
    private static let signature = Data("FUJIFILM".utf8)
    private static let headerLength = 0x70
    private static let jpegOffsetFieldOffset = 0x54
    /// Comfortably above any real RAF embedded preview (typically well
    /// under 1 MB); guards against a corrupt/hostile length field forcing a
    /// huge read (RT-P0-12).
    private static let maxJPEGPreviewReadLength = 20 * 1024 * 1024

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
              header.count == Self.headerLength,
              header.starts(with: Self.signature)
        else {
            return nil
        }

        guard let jpegOffset = Self.readUInt32BE(header, at: Self.jpegOffsetFieldOffset),
              let jpegLength = Self.readUInt32BE(header, at: Self.jpegOffsetFieldOffset + 4),
              jpegOffset > 0, jpegLength > 0, jpegLength <= Self.maxJPEGPreviewReadLength
        else {
            return nil
        }

        guard (try? handle.seek(toOffset: UInt64(jpegOffset))) != nil,
              let jpeg = try? handle.read(upToCount: Int(jpegLength)),
              jpeg.count == Int(jpegLength)
        else {
            return nil
        }

        return exifReader.readJPEG(jpeg)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        let base = data.startIndex + offset
        guard offset >= 0, data.endIndex - base >= 4 else {
            return nil
        }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[base + index])
        }
        return value
    }
}
