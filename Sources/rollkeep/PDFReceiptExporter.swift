import CoreGraphics
import CoreText
import Foundation
import RollKeepCore

struct PDFReceiptExporter {
    private enum LineStyle {
        case title
        case section
        case subsection
        case body
        case muted
        case spacer

        var fontSize: CGFloat {
            switch self {
            case .title:
                return 18
            case .section:
                return 14
            case .subsection:
                return 12
            case .body:
                return 11
            case .muted:
                return 10
            case .spacer:
                return 11
            }
        }

        var lineHeight: CGFloat {
            switch self {
            case .title:
                return 24
            case .section:
                return 20
            case .subsection:
                return 16
            case .body:
                return 15
            case .muted:
                return 14
            case .spacer:
                return 10
            }
        }

        var topSpacing: CGFloat {
            switch self {
            case .title:
                return 0
            case .section:
                return 8
            case .subsection:
                return 5
            case .body:
                return 0
            case .muted:
                return 0
            case .spacer:
                return 0
            }
        }

        var isBold: Bool {
            switch self {
            case .title, .section, .subsection:
                return true
            case .body, .muted, .spacer:
                return false
            }
        }

        var color: CGColor {
            switch self {
            case .title, .section, .subsection, .body:
                return CGColor(gray: 0.08, alpha: 1.0)
            case .muted:
                return CGColor(gray: 0.38, alpha: 1.0)
            case .spacer:
                return CGColor(gray: 0.08, alpha: 1.0)
            }
        }
    }

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
        generatedAt: Date,
        finalStatus: String,
        verificationEnabled: Bool,
        failurePhase: IngestPhase?,
        failureReason: String?,
        summary: [String: Any],
        scanSummary: ScanSummary
    ) throws -> URL {
        let receiptURL = URL(fileURLWithPath: receiptSink.path, isDirectory: false)
        let outputURL = receiptURL.deletingPathExtension().appendingPathExtension("summary.pdf")

        let reportLines = buildReportLines(
            sessionID: sessionID,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            dryRun: dryRun,
            receiptSink: receiptSink,
            generatedAt: generatedAt,
            finalStatus: finalStatus,
            verificationEnabled: verificationEnabled,
            failurePhase: failurePhase,
            failureReason: failureReason,
            summary: summary,
            scanSummary: scanSummary
        )

        let dirURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try writePDF(lines: reportLines, to: outputURL)
        return outputURL
    }

    func buildReportLines(
        sessionID: String,
        sourcePath: String,
        destinationPath: String,
        dryRun: Bool,
        receiptSink: ReceiptSink,
        generatedAt: Date,
        finalStatus: String,
        verificationEnabled: Bool,
        failurePhase: IngestPhase?,
        failureReason: String?,
        summary: [String: Any],
        scanSummary: ScanSummary
    ) -> [String] {
        let statusLabel = statusLabel(finalStatus: finalStatus, dryRun: dryRun, verificationEnabled: verificationEnabled)
        let totalsByOutcome = summary["totals_by_outcome"] as? [String: Any] ?? [:]
        let totalsByMediaType = summary["totals_by_media_type"] as? [String: Any] ?? [:]
        let phaseTimings = (summary["phase_timings_ms"] as? [[String: Any]] ?? []).sorted {
            let lhs = $0["phase"] as? String ?? ""
            let rhs = $1["phase"] as? String ?? ""
            return lhs < rhs
        }

        let perFileOutcomes = summary["per_file_outcomes"] as? [[String: Any]] ?? []
        let errorCount = intValue(totalsByOutcome["errors"])

        var lines: [String] = []
        lines.append("RollKeep Ingest Receipt")
        lines.append("Status: \(statusLabel)")
        lines.append("")
        lines.append("Executive Summary")
        lines.append("Generated: \(isoFormatter.string(from: generatedAt))")
        lines.append("Session: \(sessionID)")
        lines.append("Source: \(sourcePath)")
        lines.append("Destination: \(destinationPath)")
        lines.append("Receipt NDJSON: \(receiptSink.path) [\(receiptSink.kind.rawValue)]")
        lines.append("Dry run: \(dryRun)")
        lines.append("")
        lines.append("What happened")
        lines.append("Candidates: \(scanSummary.candidates.count)")
        lines.append("Photos: \(intValue(totalsByMediaType["photos"]))")
        lines.append("Videos: \(intValue(totalsByMediaType["videos"]))")
        lines.append("Copied to staging: \(intValue(totalsByOutcome["copied"]))")
        lines.append("Verified: \(intValue(totalsByOutcome["verified"]))")
        lines.append("Committed: \(intValue(totalsByOutcome["committed"]))")
        lines.append("Duplicates skipped: \(intValue(totalsByOutcome["duplicate_not_copied"]))")
        lines.append("Conflicts renamed: \(intValue(totalsByOutcome["conflicts_renamed"]))")
        lines.append("Errors: \(errorCount)")
        lines.append("")

        lines.append("Phase timings")
        for timing in phaseTimings {
            let phase = timing["phase"] as? String ?? "unknown"
            let milliseconds = intValue(timing["milliseconds"])
            lines.append("\(phase): \(String(format: "%.3fs", Double(milliseconds) / 1_000.0))")
        }
        lines.append("")

        if let failurePhase {
            lines.append("Attention")
            lines.append("Failure phase: \(failurePhase.rawValue)")
            lines.append("Reason: \(failureReason ?? "unknown")")
            lines.append("")
        } else if errorCount > 0 {
            lines.append("Attention")
            lines.append("Completed with \(errorCount) recorded error event(s).")
            lines.append("")
        }

        lines.append("Camera and date inventory")
        let cameraLabel = summary["camera_label"] as? String ?? "unknown-camera"
        let mixedCamera = boolValue(summary["mixed_camera_detected"])
        let knownCameraCount = intValue(summary["known_camera_file_count"])
        let unknownCameraCount = intValue(summary["unknown_camera_file_count"])
        let dateRange = summary["date_range"] as? [String: Any] ?? [:]
        lines.append("Card label: \(cameraLabel)")
        lines.append("Mixed camera detected: \(mixedCamera)")
        lines.append("Known camera files: \(knownCameraCount)")
        lines.append("Unknown camera files: \(unknownCameraCount)")
        lines.append("Date range: \(stringValue(dateRange["start"])) to \(stringValue(dateRange["end"]))")

        if let cameraLabels = summary["camera_labels"] as? [[String: Any]], !cameraLabels.isEmpty {
            lines.append("Distribution:")
            for entry in cameraLabels {
                lines.append("- \(stringValue(entry["label"])): \(intValue(entry["file_count"]))")
            }
        }

        lines.append("")
        lines.append("Audit Appendix")
        lines.append("Per-file outcomes")

        if perFileOutcomes.isEmpty {
            lines.append("No file outcomes recorded.")
        } else {
            for (index, entry) in perFileOutcomes.enumerated() {
                let path = stringValue(entry["path"])
                let outcome = stringValue(entry["outcome"])
                let mediaType = stringValue(entry["media_type"])
                let executed = boolValue(entry["executed"])
                let finalPath = stringValue(entry["final_path"])
                lines.append("\(index + 1). [\(mediaType)] \(path)")
                lines.append("   outcome: \(outcome) | executed: \(executed)")
                lines.append("   final: \(finalPath)")
            }
        }

        if !scanSummary.errors.isEmpty {
            lines.append("")
            lines.append("Scan errors")
            for error in scanSummary.errors.prefix(20) {
                lines.append("- \(error.path): \(error.message)")
            }
        }

        return lines
    }

    private func writePDF(lines: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFReceiptExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed creating PDF context"]) }

        let margin: CGFloat = 54
        let usableWidth = mediaBox.width - (margin * 2)
        var y: CGFloat = mediaBox.height - margin

        context.beginPDFPage(nil)
        var pageNumber = 1
        for (index, line) in lines.enumerated() {
            let style = style(for: line, index: index)
            let paragraphs = style == .spacer ? [""] : wrappedLines(for: line, width: usableWidth, fontSize: style.fontSize, isBold: style.isBold)

            for paragraphLine in paragraphs {
                if style.topSpacing > 0 {
                    y -= style.topSpacing
                }

                if y - style.lineHeight < margin {
                    drawFooter(context: context, pageRect: mediaBox, pageNumber: pageNumber)
                    context.endPDFPage()
                    context.beginPDFPage(nil)
                    y = mediaBox.height - margin
                    pageNumber += 1
                }

                drawText(
                    context: context,
                    text: paragraphLine,
                    at: CGPoint(x: margin, y: y),
                    fontSize: style.fontSize,
                    isBold: style.isBold,
                    color: style.color
                )
                y -= style.lineHeight

                if style == .section {
                    drawSectionDivider(
                        context: context,
                        x: margin,
                        y: y + 6,
                        width: usableWidth
                    )
                    y -= 4
                }
            }
        }

        drawFooter(context: context, pageRect: mediaBox, pageNumber: pageNumber)
        context.endPDFPage()
        context.closePDF()
    }

    private func drawSectionDivider(context: CGContext, x: CGFloat, y: CGFloat, width: CGFloat) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 0.83, alpha: 1.0))
        context.setLineWidth(0.6)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
        context.restoreGState()
    }

    private func drawFooter(context: CGContext, pageRect: CGRect, pageNumber: Int) {
        drawText(
            context: context,
            text: "RollKeep ingest receipt",
            at: CGPoint(x: 54, y: 28),
            fontSize: 9,
            isBold: false,
            color: CGColor(gray: 0.45, alpha: 1.0)
        )
        drawText(
            context: context,
            text: "Page \(pageNumber)",
            at: CGPoint(x: pageRect.width - 90, y: 28),
            fontSize: 9,
            isBold: false,
            color: CGColor(gray: 0.45, alpha: 1.0)
        )
    }

    private func drawText(
        context: CGContext,
        text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        isBold: Bool,
        color: CGColor
    ) {
        let fontName = isBold ? "Helvetica-Bold" : "Helvetica"
        guard let font = CTFontCreateWithName(fontName as CFString, fontSize, nil) as CTFont? else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private func style(for line: String, index: Int) -> LineStyle {
        if line.isEmpty {
            return .spacer
        }
        if index == 0 && line == "RollKeep Ingest Receipt" {
            return .title
        }
        if line == "Executive Summary" ||
            line == "What happened" ||
            line == "Phase timings" ||
            line == "Attention" ||
            line == "Camera and date inventory" ||
            line == "Audit Appendix" ||
            line == "Scan errors" {
            return .section
        }
        if line == "Per-file outcomes" || line == "Distribution:" {
            return .subsection
        }
        if line.hasPrefix("Generated: ") ||
            line.hasPrefix("Session: ") ||
            line.hasPrefix("Source: ") ||
            line.hasPrefix("Destination: ") ||
            line.hasPrefix("Receipt NDJSON: ") {
            return .muted
        }
        return .body
    }

    private func wrappedLines(for text: String, width: CGFloat, fontSize: CGFloat, isBold: Bool) -> [String] {
        guard !text.isEmpty else {
            return [""]
        }

        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        guard !words.isEmpty else {
            return [text]
        }

        var lines: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if textWidth(candidate, fontSize: fontSize, isBold: isBold) <= width {
                current = candidate
            } else {
                if !current.isEmpty {
                    lines.append(current)
                }

                let wordString = String(word)
                if textWidth(wordString, fontSize: fontSize, isBold: isBold) <= width {
                    current = wordString
                } else {
                    lines.append(contentsOf: hardWrap(wordString, width: width, fontSize: fontSize, isBold: isBold))
                    current = ""
                }
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines.isEmpty ? [text] : lines
    }

    private func hardWrap(_ text: String, width: CGFloat, fontSize: CGFloat, isBold: Bool) -> [String] {
        var chunks: [String] = []
        var current = ""

        for character in text {
            let candidate = current + String(character)
            if textWidth(candidate, fontSize: fontSize, isBold: isBold) <= width || current.isEmpty {
                current = candidate
            } else {
                chunks.append(current)
                current = String(character)
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func textWidth(_ text: String, fontSize: CGFloat, isBold: Bool) -> CGFloat {
        let fontName = isBold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return ceil(bounds.width)
    }

    private func statusLabel(finalStatus: String, dryRun: Bool, verificationEnabled: Bool) -> String {
        if finalStatus == "aborted" {
            return "FAILED"
        }
        if dryRun {
            return "DRY RUN"
        }
        if verificationEnabled {
            return "VERIFIED"
        }
        return "COMPLETED (verification skipped)"
    }

    private func intValue(_ value: Any?) -> Int {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 0
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        return "unknown"
    }
}
