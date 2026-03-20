import CoreGraphics
import Foundation
import RollKeepCore

struct PDFReceiptExporter {
    private typealias ReceiptReport = PDFReceiptReport

    private let fileManager: FileManager
    private let reportBuilder: PDFReceiptReportBuilder

    init(
        fileManager: FileManager = .default,
        reportBuilder: PDFReceiptReportBuilder = .init()
    ) {
        self.fileManager = fileManager
        self.reportBuilder = reportBuilder
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

        let report = buildReport(
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
        try writePDF(report: report, to: outputURL)
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
        let report = buildReport(
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

        var lines: [String] = []
        lines.append("RollKeep Transfer Receipt")
        lines.append("Status: \(report.statusLabel)")
        lines.append("")
        lines.append("At a glance")
        for metric in report.metrics {
            lines.append("\(metric.label): \(metric.value)")
        }
        lines.append("")

        lines.append("Run context")
        for row in report.contextRows {
            lines.append("\(row.0): \(row.1)")
        }
        lines.append("")

        lines.append("Capture inventory")
        for row in report.inventoryRows {
            lines.append("\(row.0): \(row.1)")
        }
        if !report.cameraDistribution.isEmpty {
            lines.append("Distribution:")
            for item in report.cameraDistribution {
                lines.append("- \(item)")
            }
        }
        lines.append("")

        lines.append("Phase timeline")
        for timing in report.phaseTimings {
            lines.append("\(timing.phase): \(String(format: "%.2fs", Double(timing.milliseconds) / 1_000.0))")
        }
        lines.append("")

        if !report.alerts.isEmpty {
            lines.append("Attention")
            for alert in report.alerts {
                lines.append("- \(alert)")
            }
            lines.append("")
        }

        lines.append("File appendix")
        if report.totalFileOutcomeCount > report.fileOutcomes.count {
            lines.append("Showing first \(report.fileOutcomes.count) of \(report.totalFileOutcomeCount) file outcomes.")
        }
        if report.fileOutcomes.isEmpty {
            lines.append("No file outcomes recorded.")
        } else {
            for (index, outcome) in report.fileOutcomes.enumerated() {
                lines.append("\(index + 1). [\(outcome.mediaType)] \(outcome.path)")
                lines.append("   outcome: \(outcome.outcome) | executed: \(outcome.executed)")
                lines.append("   final: \(outcome.finalPath)")
            }
        }
        if !report.scanErrors.isEmpty {
            lines.append("")
            lines.append("Scan errors")
            for error in report.scanErrors {
                lines.append("- \(error)")
            }
        }

        return lines
    }

    private func buildReport(
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
    ) -> ReceiptReport {
        reportBuilder.build(input: PDFReceiptReportInput(
            sessionID: sessionID,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            dryRun: dryRun,
            receiptPath: receiptSink.path,
            receiptSinkKind: receiptSink.kind.rawValue,
            generatedAt: generatedAt,
            finalStatus: finalStatus,
            verificationEnabled: verificationEnabled,
            failurePhase: failurePhase?.rawValue,
            failureReason: failureReason,
            summary: summary,
            scanSummary: scanSummary
        ))
    }

    private func writePDF(report: ReceiptReport, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(
                domain: "PDFReceiptExporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed creating PDF context"]
            )
        }

        var composer = PDFReceiptPageComposer(report: report, context: context, mediaBox: mediaBox)
        composer.render()
        context.closePDF()
    }
}
