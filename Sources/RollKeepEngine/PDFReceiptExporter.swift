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

    private func buildReport(
        sessionID: String,
        sourcePath: String,
        destinationPath: String,
        dryRun: Bool,
        receiptSink: ReceiptSink,
        generatedAt: Date,
        finalStatus: String,
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
