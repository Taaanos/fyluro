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

    public struct NeedsLookItem {
        public let label: String
        public let path: String
        public let note: String?

        public init(label: String, path: String, note: String? = nil) {
            self.label = label
            self.path = path
            self.note = note
        }
    }

    public struct RenamedItem {
        public let sourcePath: String
        public let finalPath: String

        public init(sourcePath: String, finalPath: String) {
            self.sourcePath = sourcePath
            self.finalPath = finalPath
        }
    }

    public struct LandedFolder {
        public let folder: String
        public let photos: Int
        public let videos: Int
        public let audio: Int
        public let sidecars: Int

        public var total: Int { photos + videos + audio + sidecars }

        public init(folder: String, photos: Int, videos: Int, audio: Int, sidecars: Int) {
            self.folder = folder
            self.photos = photos
            self.videos = videos
            self.audio = audio
            self.sidecars = sidecars
        }
    }

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
    public let notices: [String]
    public let needsLook: [NeedsLookItem]
    public let needsLookTotal: Int
    public let renamed: [RenamedItem]
    public let renamedTotal: Int
    public let landed: [LandedFolder]
    public let landedFolderTotal: Int
    public let alreadyInLibraryCount: Int
    public let foundCount: Int

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
        notices: [String] = [],
        needsLook: [NeedsLookItem] = [],
        needsLookTotal: Int = 0,
        renamed: [RenamedItem] = [],
        renamedTotal: Int = 0,
        landed: [LandedFolder] = [],
        landedFolderTotal: Int = 0,
        alreadyInLibraryCount: Int = 0,
        foundCount: Int = 0
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
        self.notices = notices
        self.needsLook = needsLook
        self.needsLookTotal = needsLookTotal
        self.renamed = renamed
        self.renamedTotal = renamedTotal
        self.landed = landed
        self.landedFolderTotal = landedFolderTotal
        self.alreadyInLibraryCount = alreadyInLibraryCount
        self.foundCount = foundCount
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
    static let needsLookCap = 200
    static let renamedCap = 200
    static let landedFolderCap = 60

    private struct PlannedFile {
        let mediaType: String
        let outcome: String
        let executed: Bool
        let path: String
        let finalPath: String
        let collisionRenamed: Bool
        let isSidecar: Bool
    }

    private let isoFormatter: ISO8601DateFormatter
    private let displayDateFormatter: DateFormatter
    private let byteFormatter: ByteCountFormatter
    private let countFormatter: NumberFormatter

    public init() {
        self.isoFormatter = ISO8601DateFormatter()
        self.displayDateFormatter = DateFormatter()
        self.displayDateFormatter.dateStyle = .medium
        self.displayDateFormatter.timeStyle = .medium
        self.countFormatter = NumberFormatter()
        self.countFormatter.numberStyle = .decimal
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
            alerts.append("Import failed during \(failurePhase): \(input.failureReason ?? "unknown failure reason").")
        }
        if errorCount > 0, input.failurePhase == nil {
            let errorPhrase = errorCount == 1 ? "1 recorded error" : "\(errorCount) recorded errors"
            alerts.append("Import completed with \(errorPhrase). Review the detailed event log before archiving.")
        }
        var notices: [String] = []
        if input.dryRun {
            notices.append("Dry run: no file was copied or committed. The counts show what would happen.")
        }

        let allOutcomes = perFileOutcomeEntries.map { entry in
            PlannedFile(
                mediaType: stringValue(entry["media_type"]),
                outcome: stringValue(entry["outcome"]),
                executed: boolValue(entry["executed"]),
                path: stringValue(entry["path"]),
                finalPath: stringValue(entry["final_path"]),
                collisionRenamed: entry["collision_suffix"] != nil,
                isSidecar: isSidecar(entry)
            )
        }
        let appendix = appendixGroups(input: input, outcomes: allOutcomes)

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
            notices: notices,
            needsLook: appendix.needsLook,
            needsLookTotal: appendix.needsLookTotal,
            renamed: appendix.renamed,
            renamedTotal: appendix.renamedTotal,
            landed: appendix.landed,
            landedFolderTotal: appendix.landedFolderTotal,
            alreadyInLibraryCount: appendix.alreadyInLibraryCount,
            foundCount: allOutcomes.isEmpty ? input.scanSummary.candidates.count : allOutcomes.count
        )
    }

    private struct AppendixGroups {
        let needsLook: [PDFReceiptReport.NeedsLookItem]
        let needsLookTotal: Int
        let renamed: [PDFReceiptReport.RenamedItem]
        let renamedTotal: Int
        let landed: [PDFReceiptReport.LandedFolder]
        let landedFolderTotal: Int
        let alreadyInLibraryCount: Int
    }

    private func appendixGroups(input: PDFReceiptReportInput, outcomes: [PlannedFile]) -> AppendixGroups {
        let root = input.destinationPath.hasSuffix("/") ? input.destinationPath : input.destinationPath + "/"
        func libraryRelative(_ path: String) -> String {
            path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        }

        var lookItems: [PDFReceiptReport.NeedsLookItem] = input.scanSummary.errors.map { error in
            PDFReceiptReport.NeedsLookItem(label: "Scan error", path: error.path, note: error.message)
        }
        if !input.dryRun {
            for file in outcomes where file.outcome != "committed" && file.outcome != "duplicate_not_copied" {
                lookItems.append(PDFReceiptReport.NeedsLookItem(
                    label: "Not completed",
                    path: file.path,
                    note: "planned for \(libraryRelative(file.finalPath))"
                ))
            }
        }

        let renamedItems = outcomes.filter(\.collisionRenamed).map { file in
            PDFReceiptReport.RenamedItem(sourcePath: file.path, finalPath: libraryRelative(file.finalPath))
        }

        let landedFiles = outcomes.filter { file in
            input.dryRun ? file.outcome != "duplicate_not_copied" : file.outcome == "committed"
        }
        var counts: [String: (photos: Int, videos: Int, audio: Int, sidecars: Int)] = [:]
        for file in landedFiles {
            let folder = libraryRelative((file.finalPath as NSString).deletingLastPathComponent)
            var entry = counts[folder] ?? (0, 0, 0, 0)
            if file.isSidecar {
                entry.sidecars += 1
            } else {
                switch file.mediaType {
                case "video": entry.videos += 1
                case "audio": entry.audio += 1
                default: entry.photos += 1
                }
            }
            counts[folder] = entry
        }
        let allFolders = counts.keys.sorted().map { folder -> PDFReceiptReport.LandedFolder in
            let entry = counts[folder] ?? (0, 0, 0, 0)
            return PDFReceiptReport.LandedFolder(
                folder: folder,
                photos: entry.photos,
                videos: entry.videos,
                audio: entry.audio,
                sidecars: entry.sidecars
            )
        }

        return AppendixGroups(
            needsLook: Array(lookItems.prefix(Self.needsLookCap)),
            needsLookTotal: lookItems.count,
            renamed: Array(renamedItems.prefix(Self.renamedCap)),
            renamedTotal: renamedItems.count,
            landed: Array(allFolders.prefix(Self.landedFolderCap)),
            landedFolderTotal: allFolders.count,
            alreadyInLibraryCount: outcomes.filter { $0.outcome == "duplicate_not_copied" }.count
        )
    }

    private func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func metrics(
        input: PDFReceiptReportInput,
        outcomes: [PlannedFile],
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
            foundSubtitle = sidecarCount > 0 ? "\(count(mediaCount)) media + \(count(sidecarCount)) sidecars" : "\(count(mediaCount)) media"
        }

        let renamedNote = "same name, different content — kept both"
        var tiles: [PDFReceiptReport.Metric] = [
            .init(label: "Found", value: count(foundCount), tone: .neutral, subtitle: foundSubtitle),
        ]

        if input.dryRun {
            let alreadyCount = outcomes.filter { $0.outcome == "duplicate_not_copied" }.count
            let renamedCount = outcomes.filter(\.collisionRenamed).count
            tiles.append(.init(label: "Verified", value: "Not run", tone: .neutral))
            tiles.append(.init(label: "Would add", value: count(foundCount - alreadyCount), tone: .neutral))
            tiles.append(.init(label: "Already in library", value: count(alreadyCount), tone: .neutral))
            tiles.append(.init(
                label: "Would rename",
                value: count(renamedCount),
                tone: .neutral,
                subtitle: renamedCount > 0 ? renamedNote : nil
            ))
        } else if completed {
            tiles.append(.init(label: "Verified", value: count(verifiedCount), tone: verifiedCount > 0 ? .success : .neutral))
            tiles.append(.init(label: "Added to library", value: count(committedCount), tone: committedCount > 0 ? .success : .neutral))
            tiles.append(.init(label: "Already in library", value: count(duplicateCount), tone: .neutral))
            tiles.append(.init(
                label: "Renamed",
                value: count(conflictCount),
                tone: .neutral,
                subtitle: conflictCount > 0 ? renamedNote : nil
            ))
        } else {
            tiles.append(.init(label: "Verified", value: count(verifiedCount), tone: .neutral))
            tiles.append(.init(
                label: "Added to library",
                value: count(committedCount),
                tone: .neutral,
                subtitle: "run did not finish"
            ))
            tiles.append(.init(label: "Already in library", value: "—", tone: .neutral, subtitle: "not completed"))
            tiles.append(.init(label: "Renamed", value: "—", tone: .neutral, subtitle: "not completed"))
        }

        tiles.append(.init(label: "Errors", value: count(errorCount), tone: errorCount > 0 ? .danger : .success))
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

    private func dateRangeText(start: String, end: String) -> String {
        guard start != "unknown" || end != "unknown" else { return "Unknown" }
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
        } else if rest.hasPrefix("YYYY") {
            chronological = "Year"
            rest = String(rest.dropFirst("YYYY".count))
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
            headline: headlineParts.joined(separator: " • "),
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
        guard rawValue != "unknown" else { return "Unknown" }
        if let date = isoFormatter.date(from: rawValue) {
            return displayDateFormatter.string(from: date)
        }
        return rawValue
    }

}
