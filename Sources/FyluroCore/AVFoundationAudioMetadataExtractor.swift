import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Extracts audio capture-date metadata. Tries AVFoundation's metadata-item
/// APIs first (the `com.apple.quicktime.creationdate`-style tag real Camera/
/// Voice-Memos recordings duplicate into `udta`), then falls back to reading
/// the mandatory ISO-BMFF `moov/mvhd` box's `creation_time` field directly --
/// AVFoundation's metadata-item surface only exposes *extra* tags, not this
/// structural header field every valid MP4/M4A carries, so a file with no
/// redundant `udta` tag (confirmed on a real fixture) would otherwise report
/// no embedded date at all despite `exiftool`/`ffprobe` reading one reliably.
/// Deliberately narrow in scope compared to `AVFoundationVideoMetadataExtractor`:
/// no vendor-atom decoding, no camera make/model resolution -- standalone
/// audio is not subject to camera/device inference in v1 (ROL-6 Section 6).
public struct AVFoundationAudioMetadataExtractor: AudioMetadataExtracting {
    public init() {}

    public func extract(from fileURL: URL, fallbackMtime: Date) -> AudioMetadata {
        if let captureDateTime = embeddedCreationDate(from: fileURL) {
            return AudioMetadata(
                captureDateTime: captureDateTime,
                captureDateSource: .creationTime,
                usedFallback: false
            )
        }

        return AudioMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            usedFallback: true
        )
    }

    private func embeddedCreationDate(from fileURL: URL) -> Date? {
        if let date = avMetadataCreationDate(from: fileURL) {
            return date
        }
        return ISOBMFFMovieHeaderCreationTimeReader().creationDate(fileURL: fileURL)
    }

    private func avMetadataCreationDate(from fileURL: URL) -> Date? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: fileURL)

        if let date = creationDate(in: asset.commonMetadata) {
            return date
        }
        for format in asset.availableMetadataFormats {
            if let date = creationDate(in: asset.metadata(forFormat: format)) {
                return date
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(AVFoundation)
    private func creationDate(in items: [AVMetadataItem]) -> Date? {
        for item in items where isCreationDateItem(item) {
            if let date = item.dateValue {
                return date
            }
            if let raw = item.stringValue, let parsed = VideoCreationDateParser().parse(raw) {
                return parsed
            }
        }
        return nil
    }

    private func isCreationDateItem(_ item: AVMetadataItem) -> Bool {
        if item.commonKey?.rawValue.lowercased() == "creationdate" {
            return true
        }
        if let identifier = item.identifier?.rawValue.lowercased(),
           identifier.contains("creationdate") || identifier.contains("creation_time")
        {
            return true
        }
        if let key = item.key as? String {
            let normalized = key.lowercased()
            return normalized.contains("creationdate") || normalized.contains("creation_time")
        }
        return false
    }
    #endif
}
