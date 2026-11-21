import CoreGraphics
import Foundation
import XCTest
@testable import FyluroCore
@testable import FyluroEngine

/// Measures real wall-clock cost of rendering an adversarially long string in
/// the PDF receipt, rather than assuming a complexity class (see
/// docs/testing/red-team-ingest-test-matrix.md RT-P1-10). `EmbeddedVideoMetadataTextParser`'s
/// regex captures used to have no max-length bound, letting a crafted
/// "Model:" field survive sanitization as a single unbroken token up to
/// ~2MB -- that root cause is now fixed (`sanitize()` rejects anything over
/// 128 UTF-8 bytes), so this scenario is no longer reachable via that path.
/// These tests remain as a direct, synthetic-data regression lock on the PDF
/// renderer's own characteristics (`summaryData` is a loosely-typed
/// `[String: Any]`, so nothing prevents some other/future call site from
/// passing it an oversized value) and as a permanent record of the measured
/// cost shape.
final class PDFReceiptRenderingSupportBenchmarkTests: XCTestCase {
    private let style = PDFReceiptTextStyle(
        fontSize: 9,
        lineHeight: 12,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        weight: .regular
    )

    private static func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    /// A space-free hostile string is exactly one "word" to `wrappedLines`,
    /// so `textWidth()` measures the ENTIRE unbroken string in one
    /// `CTLineCreateWithAttributedString` call before any wrapping logic
    /// (`hardWrap`) ever runs. Prints real timings so the scaling shape is
    /// measured, not assumed. Confirmed empirically linear (~7s/1M chars,
    /// not O(n^2)) -- kept to modest sizes by default so this stays fast in
    /// every `swift test` run; set FYLURO_REPRODUCE_METADATA_LENGTH_BOMB=1
    /// to also exercise sizes up to the real ~1.9MB worst case.
    func testWrappedLinesScalingOnUnbrokenHostileString() {
        let renderer = PDFReceiptTextRenderer()
        var sizes = [1_000, 10_000, 100_000]
        if ProcessInfo.processInfo.environment["FYLURO_REPRODUCE_METADATA_LENGTH_BOMB"] != nil {
            sizes += [500_000, 1_000_000, 1_900_000]
        }

        for size in sizes {
            let hostileLabel = String(repeating: "a", count: size)
            let time = Self.elapsed {
                _ = renderer.wrappedLines(for: hostileLabel, width: 500, style: style)
            }
            print("wrappedLines(unbroken hostile string, \(size) chars): \(time)s")
        }
    }

    /// Full-pipeline reachability, no filesystem involved: an oversized
    /// "camera_labels" entry reaches `PDFReceiptReportBuilder`'s Camera
    /// Distribution line (`distribution` map) and is rendered as one
    /// unbroken detail-row value by `PDFReceiptPageComposer`, exactly the
    /// path a crafted "Model:"/"Make:" field can reach even under --dry-run,
    /// with no NAME_MAX interaction at all. Uses a modest label by default
    /// (still enough to prove reachability without a crash) so this stays
    /// fast in every `swift test` run; set
    /// FYLURO_REPRODUCE_METADATA_LENGTH_BOMB=1 for the real ~1.9MB
    /// worst-case size (confirmed empirically: ~11.5s, 209KB PDF, no crash).
    func testFullPDFExportWithOversizedCameraDistributionLabel() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-pdf-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let receiptPath = tempRoot
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
            .appendingPathComponent("session-123.ndjson", isDirectory: false)
            .path

        let scanSummary = ScanSummary(
            candidates: [], photoCount: 0, videoCount: 0, photoBytes: 0, videoBytes: 0,
            filesInTypicalLocations: 0, filesOutsideTypicalLocations: 0, errors: []
        )

        let reproduceFullSize = ProcessInfo.processInfo.environment["FYLURO_REPRODUCE_METADATA_LENGTH_BOMB"] != nil
        let hostileLabel = String(repeating: "a", count: reproduceFullSize ? 1_900_000 : 50_000)
        let summaryData: [String: Any] = [
            "totals_by_outcome": ["copied": 0, "verified": 0, "committed": 0, "duplicate_not_copied": 0, "conflicts_renamed": 0, "errors": 0],
            "totals_by_media_type": ["photos": 0, "videos": 1],
            "phase_timings_ms": [],
            "path_scheme": "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>",
            "known_camera_file_count": 1,
            "unknown_camera_file_count": 0,
            "camera_labels": [["label": hostileLabel, "file_count": 1]],
            "date_range": ["start": "unknown", "end": "unknown"],
            "per_file_outcomes": [],
        ]

        var producedURL: URL?
        let time = Self.elapsed {
            producedURL = try? PDFReceiptExporter().write(
                sessionID: "session-123",
                sourcePath: "/source",
                destinationPath: "/dest",
                dryRun: true,
                receiptSink: ReceiptSink(kind: .destination, path: receiptPath),
                generatedAt: Date(),
                finalStatus: "completed",
                failurePhase: nil,
                failureReason: nil,
                summary: summaryData,
                scanSummary: scanSummary
            )
        }

        print("Full PDF export with a 1.9MB unbroken Camera Distribution label: \(time)s")
        XCTAssertNotNil(producedURL, "PDF export should still complete (not crash) on an oversized label")
        if let producedURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: producedURL.path)
            print("Produced PDF size: \((attributes[.size] as? NSNumber)?.intValue ?? 0) bytes")
        }
    }
}
