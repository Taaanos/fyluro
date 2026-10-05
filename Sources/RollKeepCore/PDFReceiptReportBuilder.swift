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
        public let subtitle: String?

        public init(label: String, value: String, tone: Tone, subtitle: String? = nil) {
            self.label = label
            self.value = value
            self.tone = tone
            self.subtitle = subtitle
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
        /// True for a companion file (for example `.xmp`). The summary JSON has no sidecar flag,
        /// so the builder derives it from the extension (ROL-6 Section 5).
        public let isSidecar: Bool

        public init(
            mediaType: String,
            outcome: String,
            executed: Bool,
            path: String,
            sourcePath: String,
            finalPath: String,
            collisionRenamed: Bool,
            isSidecar: Bool = false
        ) {
            self.mediaType = mediaType
            self.outcome = outcome
            self.executed = executed
            self.path = path
            self.sourcePath = sourcePath
            self.finalPath = finalPath
            self.collisionRenamed = collisionRenamed
            self.isSidecar = isSidecar
        }
    }

    /// The film camera and film that made the shots. Built only when Film Mode was used.
    public struct FilmModeSection {
        public let headline: String
        public let detailRows: [(String, String)]
        public let exifNote: String

        public init(headline: String, detailRows: [(String, String)], exifNote: String) {
            self.headline = headline
            self.detailRows = detailRows
            self.exifNote = exifNote
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
    public let filmMode: FilmModeSection?
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
        filmMode: FilmModeSection? = nil,
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
        self.filmMode = filmMode
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
        let verifiedCount = intValue(totalsByOutcome["verified"])
        let committedCount = intValue(totalsByOutcome["committed"])
        let duplicateCount = intValue(totalsByOutcome["duplicate_not_copied"])
        let conflictCount = intValue(totalsByOutcome["conflicts_renamed"])
        let bytesProcessed = intValue(input.summary["bytes_processed"])
        let perFileOutcomeEntries = input.summary["per_file_outcomes"] as? [[String: Any]] ?? []
        let hasUnsortedFiles = perFileOutcomeEntries.contains { entry in
            stringValue(entry["final_path"]).contains("/_unsorted/")
        }
        let pathSchemeLines = readablePathScheme(
            stringValue(input.summary["path_scheme"]),
            includeUnsorted: hasUnsortedFiles
        )

        let dateRange = input.summary["date_range"] as? [String: Any] ?? [:]
        let rangeText = dateRangeText(start: stringValue(dateRange["start"]), end: stringValue(dateRange["end"]))

        var contextRows: [(String, String)] = [
            ("Generated", displayDateFormatter.string(from: input.generatedAt)),
            ("Session", input.sessionID),
            ("Source", input.sourcePath),
            ("Destination", input.destinationPath),
        ]
        contextRows.append(contentsOf: pathSchemeLines)

        let inventoryRows: [(String, String)] = [
            ("Known camera files", "\(intValue(input.summary["known_camera_file_count"]))"),
            ("Unknown camera files", "\(intValue(input.summary["unknown_camera_file_count"]))"),
            ("Date range", rangeText),
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
                collisionRenamed: entry["collision_suffix"] != nil,
                isSidecar: isSidecar(entry)
            )
        }
        let maximumOutcomes = 80
        let outcomePreview = Array(allOutcomes.prefix(maximumOutcomes))

        let scanErrors = input.scanSummary.errors.prefix(20).map { error in
            "\(error.path): \(error.message)"
        }

        let metrics = metrics(
            input: input,
            outcomes: allOutcomes,
            verifiedCount: verifiedCount,
            committedCount: committedCount,
            duplicateCount: duplicateCount,
            conflictCount: conflictCount,
            errorCount: errorCount,
            bytesProcessed: bytesProcessed
        )

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
            filmMode: filmModeSection(from: input.summary["film_mode"]),
            inventoryRows: inventoryRows,
            cameraDistribution: distribution,
            alerts: alerts,
            fileOutcomes: outcomePreview,
            totalFileOutcomeCount: allOutcomes.count,
            scanErrors: scanErrors,
            totalScanErrorCount: input.scanSummary.errors.count
        )
    }

    /// The tiles use the same words as the app. For a completed run, Found = Added to library +
    /// Already in library. A dry run shows what would happen. A failed run shows "Not completed"
    /// for the counts that depend on the commit step.
    private func metrics(
        input: PDFReceiptReportInput,
        outcomes: [PDFReceiptReport.FileOutcome],
        verifiedCount: Int,
        committedCount: Int,
        duplicateCount: Int,
        conflictCount: Int,
        errorCount: Int,
        bytesProcessed: Int
    ) -> [PDFReceiptReport.Metric] {
        let completed = input.finalStatus != "aborted" && !input.dryRun
        let foundCount = outcomes.isEmpty ? input.scanSummary.candidates.count : outcomes.count
        let sidecarCount = outcomes.filter(\.isSidecar).count
        let mediaCount = outcomes.isEmpty ? foundCount : outcomes.count - sidecarCount
        var foundSubtitle: String?
        if foundCount > 0 {
            foundSubtitle = sidecarCount > 0 ? "\(mediaCount) media + \(sidecarCount) sidecars" : "\(mediaCount) media"
        }

        let renamedNote = "same name, different content — kept both"
        var tiles: [PDFReceiptReport.Metric] = [
            .init(label: "Found", value: "\(foundCount)", tone: .neutral, subtitle: foundSubtitle),
        ]

        if input.dryRun {
            let alreadyCount = outcomes.filter { $0.outcome == "duplicate_not_copied" }.count
            let renamedCount = outcomes.filter(\.collisionRenamed).count
            tiles.append(.init(label: "Verified", value: "Not run", tone: .neutral))
            tiles.append(.init(label: "Would add", value: "\(foundCount - alreadyCount)", tone: .neutral))
            tiles.append(.init(label: "Already in library", value: "\(alreadyCount)", tone: .neutral))
            tiles.append(.init(
                label: "Would rename",
                value: "\(renamedCount)",
                tone: .neutral,
                subtitle: renamedCount > 0 ? renamedNote : nil
            ))
        } else if completed {
            tiles.append(.init(label: "Verified", value: "\(verifiedCount)", tone: verifiedCount > 0 ? .success : .neutral))
            tiles.append(.init(label: "Added to library", value: "\(committedCount)", tone: committedCount > 0 ? .success : .neutral))
            tiles.append(.init(label: "Already in library", value: "\(duplicateCount)", tone: .neutral))
            tiles.append(.init(
                label: "Renamed",
                value: "\(conflictCount)",
                tone: .neutral,
                subtitle: conflictCount > 0 ? renamedNote : nil
            ))
        } else {
            tiles.append(.init(label: "Verified", value: "\(verifiedCount)", tone: .neutral))
            tiles.append(.init(
                label: "Added to library",
                value: "\(committedCount)",
                tone: .neutral,
                subtitle: "run did not finish"
            ))
            tiles.append(.init(label: "Already in library", value: "Not completed", tone: .neutral))
            tiles.append(.init(label: "Renamed", value: "Not completed", tone: .neutral))
        }

        tiles.append(.init(label: "Errors", value: "\(errorCount)", tone: errorCount > 0 ? .danger : .success))
        tiles.append(.init(
            label: "Data",
            value: byteFormatter.string(fromByteCount: Int64(max(bytesProcessed, 0))),
            tone: .neutral
        ))
        return tiles
    }

    /// A companion file by extension. A `.wav` counts as a sidecar only when its media type is not
    /// audio, because a standalone WAV is audio and a WAV next to a video takes the video's type.
    private func isSidecar(_ entry: [String: Any]) -> Bool {
        let path = stringValue(entry["path"] ?? entry["source_path"])
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard MediaSidecarSupport.transferExtensions.contains(fileExtension) else { return false }
        if fileExtension == "wav" {
            return stringValue(entry["media_type"]) != "audio"
        }
        return true
    }

    /// A same-day range reads "23 Sep 2026, 17:49–19:23". Other ranges keep "start to end".
    private func dateRangeText(start: String, end: String) -> String {
        guard start != "unknown" || end != "unknown" else { return "unknown" }
        guard let startDate = isoFormatter.date(from: start), let endDate = isoFormatter.date(from: end) else {
            return "\(displayDate(start)) to \(displayDate(end))"
        }
        let dayFormatter = DateFormatter()
        dayFormatter.dateStyle = .medium
        dayFormatter.timeStyle = .none
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        if Calendar.current.isDate(startDate, inSameDayAs: endDate) {
            let day = dayFormatter.string(from: startDate)
            if startDate == endDate {
                return "\(day), \(timeFormatter.string(from: startDate))"
            }
            return "\(day), \(timeFormatter.string(from: startDate))–\(timeFormatter.string(from: endDate))"
        }
        return "\(displayDate(start)) to \(displayDate(end))"
    }

    /// Turns the receipt's `path_scheme` string into one line that a person can read.
    /// For example "Year/YearMonth › Camera › Photos/Videos › RAW/Non-RAW".
    /// The `_unsorted` variant is shown only when undated files exist.
    /// An unknown format is returned unchanged.
    func readablePathScheme(_ raw: String, includeUnsorted: Bool) -> [(String, String)] {
        let dated = raw.components(separatedBy: " ; ").first ?? raw
        var rest = dated
        var chronological: String
        if rest.hasPrefix("YYYY/YYYYMM") {
            chronological = "Year/YearMonth"
            rest = String(rest.dropFirst("YYYY/YYYYMM".count))
        } else if rest.hasPrefix("YYYY/MM") {
            chronological = "Year/Month"
            rest = String(rest.dropFirst("YYYY/MM".count))
        } else {
            return [("Path scheme", raw)]
        }

        let components = rest.split(separator: "/").map(String.init).compactMap { component -> String? in
            switch component {
            case "<filename>": return nil
            case "<Camera>": return "Camera"
            case "<Photos|Videos>": return "Photos/Videos"
            case "<RAW|Non-RAW (Photos)>": return "RAW/Non-RAW (photos)"
            default: return component
            }
        }

        var rows = [("Path scheme", ([chronological] + components).joined(separator: " › "))]
        if includeUnsorted {
            rows.append(("Undated files", (["_unsorted"] + components).joined(separator: " › ")))
        }
        return rows
    }

    private func filmModeSection(from rawValue: Any?) -> PDFReceiptReport.FilmModeSection? {
        guard let film = rawValue as? [String: Any], boolValue(film["used"]) else { return nil }

        func text(_ key: String) -> String? {
            guard let value = film[key] else { return nil }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let number = value as? NSNumber {
                return "\(number.intValue)"
            }
            return nil
        }

        var headlineParts = ["Shot on \(text("camera") ?? "unknown camera")"]
        if let stock = text("film_stock") {
            headlineParts.append(stock)
        }
        switch (text("iso"), text("shot_at_iso")) {
        case let (iso?, shotAt?):
            headlineParts.append("ISO \(iso) (shot at \(shotAt))")
        case let (iso?, nil):
            headlineParts.append("ISO \(iso)")
        case let (nil, shotAt?):
            headlineParts.append("shot at ISO \(shotAt)")
        case (nil, nil):
            break
        }
        let year = intValue(film["year"])
        let month = intValue(film["month"])
        if year > 0 {
            let symbols = displayDateFormatter.standaloneMonthSymbols ?? []
            if month >= 1, month <= symbols.count {
                headlineParts.append("\(symbols[month - 1]) \(year)")
            } else {
                headlineParts.append("\(year)")
            }
        }

        var rows: [(String, String)] = []
        if let lens = text("lens") { rows.append(("Lens", lens)) }
        if let notes = text("development_notes") { rows.append(("Development", notes)) }
        if let scanner = text("scanner") { rows.append(("Digitized with", scanner)) }
        if let creator = text("creator") { rows.append(("Creator", creator)) }
        if let copyright = text("copyright") { rows.append(("Copyright", copyright)) }

        let applied = intValue(film["exif_applied_count"])
        let skipped = intValue(film["exif_skipped_count"])
        var note = "EXIF written to \(applied) \(applied == 1 ? "file" : "files")"
        if skipped > 0 {
            note += "; \(skipped) RAW \(skipped == 1 ? "file" : "files") kept their original camera metadata"
        }
        note += "."

        return PDFReceiptReport.FilmModeSection(
            headline: headlineParts.joined(separator: " · "),
            detailRows: rows,
            exifNote: note
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
