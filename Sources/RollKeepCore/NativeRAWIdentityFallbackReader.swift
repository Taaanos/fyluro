import Foundation

/// Dispatches to the right byte-level identity reader for a RAW/photo file
/// when ImageIO can't (or won't) supply Make/Model itself. Tried in order:
/// 1. Format-specific readers for containers that are not plain TIFF (CR3:
///    ISO-BMFF + Canon uuid; RAF: FUJIFILM header + embedded JPEG preview;
///    MRW: segment-framed embedded TIFF).
/// 2. A generic bounded-prefix TIFF-variant sniff (`ExifIFDFieldReader`),
///    which covers every other TIFF-based RAW format for free -- NEF, ARW,
///    CR2, DNG, PEF, SR2, SRF, NRW, ERF, MEF, DCR, FFF, RWL, KDC, K25, and
///    ORF/RW2's nonstandard-but-still-TIFF-shaped magic words -- since they
///    all keep Make/Model in a standard IFD0 near the front of the file
///    regardless of vendor.
///
/// Not every RAW format in the ingest allowlist has a path here: CRW (CIFF,
/// not TIFF) and X3F (its own directory format) still fall through to
/// `unknown-camera` for now.
struct NativeRAWIdentityFallbackReader {
    /// Real production RAW files can run into the tens/hundreds of MB;
    /// Make/Model/Serial always live in IFD0 near the file start, so a
    /// generous-but-bounded prefix read is enough without risking a huge
    /// in-memory read on a hostile/huge file (AGENTS.md 2026-07-16,
    /// RT-P0-12).
    private static let genericTIFFPrefixReadLength = 2 * 1024 * 1024

    private let cr3Reader: CanonCR3IdentityReader
    private let rafReader: FujiFilmRAFIdentityReader
    private let mrwReader: MinoltaMRWIdentityReader
    private let exifReader: ExifIFDFieldReader

    init(
        cr3Reader: CanonCR3IdentityReader = CanonCR3IdentityReader(),
        rafReader: FujiFilmRAFIdentityReader = FujiFilmRAFIdentityReader(),
        mrwReader: MinoltaMRWIdentityReader = MinoltaMRWIdentityReader(),
        exifReader: ExifIFDFieldReader = ExifIFDFieldReader()
    ) {
        self.cr3Reader = cr3Reader
        self.rafReader = rafReader
        self.mrwReader = mrwReader
        self.exifReader = exifReader
    }

    func identity(for fileURL: URL) -> ExifIFDFields? {
        switch fileURL.pathExtension.lowercased() {
        case "cr3":
            guard let decoded = cr3Reader.identity(for: fileURL) else {
                return nil
            }
            return ExifIFDFields(make: decoded.make, model: decoded.model, serial: decoded.serial, uniqueCameraModel: nil)
        case "raf":
            return rafReader.identity(for: fileURL)
        case "mrw":
            return mrwReader.identity(for: fileURL)
        default:
            return genericTIFFIdentity(for: fileURL)
        }
    }

    private func genericTIFFIdentity(for fileURL: URL) -> ExifIFDFields? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let prefix = try? handle.read(upToCount: Self.genericTIFFPrefixReadLength), !prefix.isEmpty else {
            return nil
        }

        let fields = exifReader.readTIFF(prefix)
        return (fields?.hasIdentity == true) ? fields : nil
    }
}
