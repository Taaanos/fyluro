import Foundation
import RollKeepCore

struct MarkdownReceiptExporter {
    private let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.isoFormatter = ISO8601DateFormatter()
    }

    func write(
        sessionID: String,
        sourcePath: String,
        destinationPath: String,
        dryRun: Bool,
        receiptSink: ReceiptSink,
        summary: ScanSummary
    ) throws -> URL {
        let receiptURL = URL(fileURLWithPath: receiptSink.path, isDirectory: false)
        let outputURL = receiptURL.deletingPathExtension().appendingPathExtension("summary.md")
        let markdown = render(
            sessionID: sessionID,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            dryRun: dryRun,
            receiptSink: receiptSink,
            generatedAt: Date(),
            summary: summary
        )

        let dirURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    func render(
        sessionID: String,
        sourcePath: String,
        destinationPath: String,
        dryRun: Bool,
        receiptSink: ReceiptSink,
        generatedAt: Date,
        summary: ScanSummary
    ) -> String {
        let photos = summary.candidates.filter { $0.mediaType == .photo }
        let videos = summary.candidates.filter { $0.mediaType == .video }

        let photoDated = photos.filter { $0.photoMetadata?.planBucket == "dated" }.count
        let photoUnsorted = photos.filter { $0.photoMetadata?.planBucket == "_unsorted" }.count

        var dateSourceCounts: [String: Int] = [:]
        for photo in photos {
            let source = photo.photoMetadata?.captureDateSource.rawValue ?? PhotoCaptureDateSource.missing.rawValue
            dateSourceCounts[source, default: 0] += 1
        }

        let assessment = summary.cameraAssessment

        let unsortedPhotos = photos
            .filter { $0.photoMetadata?.planBucket == "_unsorted" }
            .prefix(20)

        var lines: [String] = []
        lines.append("# Rollkeep Scan Summary")
        lines.append("")
        lines.append("- Session: `\(sessionID)`")
        lines.append("- Generated: `\(isoFormatter.string(from: generatedAt))`")
        lines.append("- Source: `\(sourcePath)`")
        lines.append("- Destination: `\(destinationPath)`")
        lines.append("- Dry run: `\(dryRun)`")
        lines.append("- Receipt sink: `\(receiptSink.kind.rawValue)`")
        lines.append("- NDJSON receipt: `\(receiptSink.path)`")
        lines.append("")

        lines.append("## Totals")
        lines.append("")
        lines.append("- Candidates: `\(summary.candidates.count)`")
        lines.append("- Photos: `\(photos.count)` (`\(summary.photoBytes)` bytes)")
        lines.append("- Videos: `\(videos.count)` (`\(summary.videoBytes)` bytes)")
        lines.append("- Typical media paths: `\(summary.filesInTypicalLocations)`")
        lines.append("- Outside typical media paths: `\(summary.filesOutsideTypicalLocations)`")
        lines.append("- Scan errors: `\(summary.errors.count)`")
        lines.append("")

        lines.append("## EXIF Coverage (Photos)")
        lines.append("")
        lines.append("- Dated (EXIF datetime found): `\(photoDated)`")
        lines.append("- `_unsorted` (EXIF datetime missing): `\(photoUnsorted)`")
        lines.append("")

        lines.append("## Datetime Source Breakdown")
        lines.append("")
        if dateSourceCounts.isEmpty {
            lines.append("- No photo files detected.")
        } else {
            for source in dateSourceCounts.keys.sorted() {
                lines.append("- `\(source)`: `\(dateSourceCounts[source] ?? 0)`")
            }
        }
        lines.append("")

        lines.append("## Camera Inventory")
        lines.append("")
        lines.append("- Card camera label: `\(assessment.cameraLabel)`")
        lines.append("- Mixed camera detected: `\(assessment.mixedCameraDetected)`")
        lines.append("- Files with detected camera metadata: `\(assessment.knownCameraFileCount)`")
        lines.append("- Files without detected camera metadata: `\(assessment.unknownCameraFileCount)`")
        lines.append("")
        if assessment.distribution.isEmpty {
            lines.append("- No media files detected.")
        } else {
            for entry in assessment.distribution {
                lines.append("- `\(entry.cameraLabel)`: `\(entry.fileCount)`")
            }
        }
        lines.append("")

        lines.append("## `_unsorted` Photos (First 20)")
        lines.append("")
        if unsortedPhotos.isEmpty {
            lines.append("- None")
        } else {
            lines.append("| Path | Make | Model | Serial |")
            lines.append("| --- | --- | --- | --- |")
            for photo in unsortedPhotos {
                let make = photo.photoMetadata?.cameraMake ?? "missing"
                let model = photo.photoMetadata?.cameraModel ?? "missing"
                let serial = photo.photoMetadata?.cameraSerial ?? "missing"
                lines.append("| `\(photo.relativePath)` | `\(make)` | `\(model)` | `\(serial)` |")
            }
        }
        lines.append("")

        if !summary.errors.isEmpty {
            lines.append("## Scan Errors")
            lines.append("")
            for error in summary.errors.prefix(20) {
                lines.append("- `\(error.path)`: \(error.message)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
