import Foundation

public struct PDFReceiptReport {
    public struct Metric {
        public enum Tone {
            case neutral
            case accent
            case success
            case warning
            case danger
        }

        public let label: String
        public let value: String
        public let tone: Tone

        public init(label: String, value: String, tone: Tone) {
            self.label = label
            self.value = value
            self.tone = tone
        }
    }

    public struct FileOutcome {
        public let mediaType: String
        public let outcome: String
        public let executed: Bool
        public let path: String
        public let sourcePath: String
        public let finalPath: String
        public let collisionRenamed: Bool

        public init(
            mediaType: String,
            outcome: String,
            executed: Bool,
            path: String,
            sourcePath: String,
            finalPath: String,
            collisionRenamed: Bool
        ) {
            self.mediaType = mediaType
            self.outcome = outcome
            self.executed = executed
            self.path = path
            self.sourcePath = sourcePath
            self.finalPath = finalPath
            self.collisionRenamed = collisionRenamed
        }
    }

    public let statusLabel: String
    public let generatedAtText: String
    public let sessionID: String
    public let sourcePath: String
    public let destinationPath: String
    public let receiptPath: String
    public let receiptSinkKind: String
    public let dryRun: Bool
    public let metrics: [Metric]
    public let contextRows: [(String, String)]
    public let inventoryRows: [(String, String)]
    public let cameraDistribution: [String]
    public let alerts: [String]
    public let fileOutcomes: [FileOutcome]
    public let totalFileOutcomeCount: Int
    public let scanErrors: [String]
    public let totalScanErrorCount: Int

    public init(
        statusLabel: String,
        generatedAtText: String,
        sessionID: String,
        sourcePath: String,
        destinationPath: String,
        receiptPath: String,
        receiptSinkKind: String,
        dryRun: Bool,
        metrics: [Metric],
        contextRows: [(String, String)],
        inventoryRows: [(String, String)],
        cameraDistribution: [String],
        alerts: [String],
        fileOutcomes: [FileOutcome],
        totalFileOutcomeCount: Int,
        scanErrors: [String],
        totalScanErrorCount: Int
    ) {
        self.statusLabel = statusLabel
        self.generatedAtText = generatedAtText
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.receiptPath = receiptPath
        self.receiptSinkKind = receiptSinkKind
        self.dryRun = dryRun
        self.metrics = metrics
        self.contextRows = contextRows
        self.inventoryRows = inventoryRows
        self.cameraDistribution = cameraDistribution
        self.alerts = alerts
        self.fileOutcomes = fileOutcomes
        self.totalFileOutcomeCount = totalFileOutcomeCount
        self.scanErrors = scanErrors
        self.totalScanErrorCount = totalScanErrorCount
    }
}

public struct PDFReceiptReportInput {
    public let sessionID: String
    public let sourcePath: String
    public let destinationPath: String
    public let dryRun: Bool
    public let receiptPath: String
    public let receiptSinkKind: String
    public let generatedAt: Date
    public let finalStatus: String
    public let failurePhase: String?
    public let failureReason: String?
    public let summary: [String: Any]
    public let scanSummary: ScanSummary

    public init(
        sessionID: String,
        sourcePath: String,
        destinationPath: String,
        dryRun: Bool,
        receiptPath: String,
        receiptSinkKind: String,
        generatedAt: Date,
        finalStatus: String,
        failurePhase: String?,
        failureReason: String?,
        summary: [String: Any],
        scanSummary: ScanSummary
    ) {
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.dryRun = dryRun
        self.receiptPath = receiptPath
        self.receiptSinkKind = receiptSinkKind
        self.generatedAt = generatedAt
        self.finalStatus = finalStatus
        self.failurePhase = failurePhase
        self.failureReason = failureReason
        self.summary = summary
        self.scanSummary = scanSummary
    }
}

public struct PDFReceiptReportBuilder {
    private let isoFormatter: ISO8601DateFormatter
    private let displayDateFormatter: DateFormatter
    private let byteFormatter: ByteCountFormatter

    public init() {
        self.isoFormatter = ISO8601DateFormatter()
        self.displayDateFormatter = DateFormatter()
        self.displayDateFormatter.dateStyle = .medium
        self.displayDateFormatter.timeStyle = .medium
        self.byteFormatter = ByteCountFormatter()
        self.byteFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        self.byteFormatter.countStyle = .file
    }

    public func build(input: PDFReceiptReportInput) -> PDFReceiptReport {
        let status = statusLabel(finalStatus: input.finalStatus, dryRun: input.dryRun)
        let totalsByOutcome = input.summary["totals_by_outcome"] as? [String: Any] ?? [:]
        let errorCount = intValue(totalsByOutcome["errors"])
        let copiedCount = intValue(totalsByOutcome["copied"])
        let verifiedCount = intValue(totalsByOutcome["verified"])
        let committedCount = intValue(totalsByOutcome["committed"])
        let duplicateCount = intValue(totalsByOutcome["duplicate_not_copied"])
        let conflictCount = intValue(totalsByOutcome["conflicts_renamed"])
        let bytesProcessed = intValue(input.summary["bytes_processed"])
        let candidateCount = input.scanSummary.candidates.count
        let pathScheme = stringValue(input.summary["path_scheme"])

        let dateRange = input.summary["date_range"] as? [String: Any] ?? [:]
        let rangeStart = displayDate(stringValue(dateRange["start"]))
        let rangeEnd = displayDate(stringValue(dateRange["end"]))

        let contextRows: [(String, String)] = [
            ("Generated", displayDateFormatter.string(from: input.generatedAt)),
            ("Source", input.sourcePath),
            ("Destination", input.destinationPath),
            ("Path Scheme", pathScheme),
            ("Receipt sink", input.receiptSinkKind),
            ("Dry run", input.dryRun ? "yes" : "no"),
        ]

        let inventoryRows: [(String, String)] = [
            ("Known camera files", "\(intValue(input.summary["known_camera_file_count"]))"),
            ("Unknown camera files", "\(intValue(input.summary["unknown_camera_file_count"]))"),
            ("Date range", "\(rangeStart) to \(rangeEnd)"),
        ]

        let distribution = (input.summary["camera_labels"] as? [[String: Any]] ?? []).map { entry in
            "\(stringValue(entry["label"])): \(intValue(entry["file_count"]))"
        }

        var alerts: [String] = []
        if let failurePhase = input.failurePhase {
            alerts.append("Ingest failed during \(failurePhase): \(input.failureReason ?? "unknown failure reason").")
        }
        if errorCount > 0, input.failurePhase == nil {
            alerts.append("Ingest completed with \(errorCount) recorded error event(s). Review the detailed event log before archival decisions.")
        }
        if input.dryRun {
            alerts.append("Dry run mode was enabled, so no file copy or commit actions were executed.")
        }

        let allOutcomes = (input.summary["per_file_outcomes"] as? [[String: Any]] ?? []).map { entry in
            PDFReceiptReport.FileOutcome(
                mediaType: stringValue(entry["media_type"]),
                outcome: stringValue(entry["outcome"]),
                executed: boolValue(entry["executed"]),
                path: stringValue(entry["path"]),
                sourcePath: stringValue(entry["source_path"]),
                finalPath: stringValue(entry["final_path"]),
                collisionRenamed: entry["collision_suffix"] != nil
            )
        }
        let maximumOutcomes = 80
        let outcomePreview = Array(allOutcomes.prefix(maximumOutcomes))

        let scanErrors = input.scanSummary.errors.prefix(20).map { error in
            "\(error.path): \(error.message)"
        }

        let metrics: [PDFReceiptReport.Metric] = [
            .init(label: "Candidates", value: "\(candidateCount)", tone: .neutral),
            .init(label: "Copied", value: "\(copiedCount)", tone: .accent),
            .init(label: "Verified", value: "\(verifiedCount)", tone: .success),
            .init(label: "Committed", value: "\(committedCount)", tone: .success),
            .init(label: "Duplicates", value: "\(duplicateCount)", tone: .neutral),
            .init(label: "Conflicts", value: "\(conflictCount)", tone: .warning),
            .init(label: "Errors", value: "\(errorCount)", tone: errorCount > 0 ? .danger : .success),
            .init(
                label: "Data",
                value: byteFormatter.string(fromByteCount: Int64(max(bytesProcessed, 0))),
                tone: .neutral
            ),
        ]

        return PDFReceiptReport(
            statusLabel: status,
            generatedAtText: displayDateFormatter.string(from: input.generatedAt),
            sessionID: input.sessionID,
            sourcePath: input.sourcePath,
            destinationPath: input.destinationPath,
            receiptPath: input.receiptPath,
            receiptSinkKind: input.receiptSinkKind,
            dryRun: input.dryRun,
            metrics: metrics,
            contextRows: contextRows,
            inventoryRows: inventoryRows,
            cameraDistribution: distribution,
            alerts: alerts,
            fileOutcomes: outcomePreview,
            totalFileOutcomeCount: allOutcomes.count,
            scanErrors: scanErrors,
            totalScanErrorCount: input.scanSummary.errors.count
        )
    }

    private func statusLabel(finalStatus: String, dryRun: Bool) -> String {
        if finalStatus == "aborted" {
            return "FAILED"
        }
        if dryRun {
            return "DRY RUN"
        }
        return "VERIFIED"
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

    private func displayDate(_ rawValue: String) -> String {
        guard rawValue != "unknown" else { return "unknown" }
        if let date = isoFormatter.date(from: rawValue) {
            return displayDateFormatter.string(from: date)
        }
        return rawValue
    }

}
