import CoreGraphics
import CoreText
import Foundation
import RollKeepCore

struct PDFReceiptExporter {
    private typealias ReceiptReport = PDFReceiptReport

    private struct TextStyle {
        enum Weight {
            case regular
            case medium
            case semibold
            case bold
            case mono
        }

        let fontSize: CGFloat
        let lineHeight: CGFloat
        let color: CGColor
        let weight: Weight
    }

    private struct Palette {
        let pageBackground = PDFReceiptExporter.rgb(247, 249, 252)
        let cardBackground = PDFReceiptExporter.rgb(255, 255, 255)
        let heroBackground = PDFReceiptExporter.rgb(234, 242, 255)
        let heroStroke = PDFReceiptExporter.rgb(199, 215, 243)
        let border = PDFReceiptExporter.rgb(215, 221, 232)
        let divider = PDFReceiptExporter.rgb(226, 231, 239)
        let primaryText = PDFReceiptExporter.rgb(26, 31, 42)
        let secondaryText = PDFReceiptExporter.rgb(92, 101, 118)
        let accent = PDFReceiptExporter.rgb(10, 103, 225)
        let success = PDFReceiptExporter.rgb(26, 127, 55)
        let warning = PDFReceiptExporter.rgb(168, 111, 1)
        let danger = PDFReceiptExporter.rgb(184, 38, 33)
    }

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
            lines.append("\(timing.phase): \(formatDuration(milliseconds: timing.milliseconds))")
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

        let palette = Palette()
        let margin: CGFloat = 48
        let topInset: CGFloat = 56
        let bottomInset: CGFloat = 48
        let usableWidth = mediaBox.width - (margin * 2)
        var y: CGFloat = mediaBox.height - topInset
        context.beginPDFPage(nil)
        var pageNumber = 1
        drawPageBackground(context: context, pageRect: mediaBox, color: palette.pageBackground)

        let heroTitleStyle = TextStyle(fontSize: 24, lineHeight: 30, color: palette.primaryText, weight: .bold)
        let heroBodyStyle = TextStyle(fontSize: 11, lineHeight: 15, color: palette.secondaryText, weight: .regular)
        let sectionTitleStyle = TextStyle(fontSize: 15, lineHeight: 20, color: palette.primaryText, weight: .semibold)
        let sectionBodyStyle = TextStyle(fontSize: 11, lineHeight: 15, color: palette.primaryText, weight: .regular)
        let sectionLabelStyle = TextStyle(fontSize: 10, lineHeight: 14, color: palette.secondaryText, weight: .medium)
        let captionStyle = TextStyle(fontSize: 9, lineHeight: 13, color: palette.secondaryText, weight: .regular)
        let metricLabelStyle = TextStyle(fontSize: 9, lineHeight: 12, color: palette.secondaryText, weight: .medium)
        let metricValueStyle = TextStyle(fontSize: 19, lineHeight: 23, color: palette.primaryText, weight: .semibold)
        let monoStyle = TextStyle(fontSize: 9.5, lineHeight: 13, color: palette.secondaryText, weight: .mono)

        func beginNewPage() {
            drawFooter(
                context: context,
                pageRect: mediaBox,
                pageNumber: pageNumber,
                sessionID: report.sessionID,
                palette: palette
            )
            context.endPDFPage()
            context.beginPDFPage(nil)
            pageNumber += 1
            drawPageBackground(context: context, pageRect: mediaBox, color: palette.pageBackground)
            y = mediaBox.height - topInset

            let continuationTitle = "RollKeep Transfer Receipt Appendix"
            drawText(
                context: context,
                text: continuationTitle,
                at: CGPoint(x: margin, y: y),
                style: TextStyle(fontSize: 12, lineHeight: 16, color: palette.primaryText, weight: .semibold)
            )
            let statusText = "Status: \(report.statusLabel)"
            let statusWidth = textWidth(statusText, style: captionStyle)
            drawText(
                context: context,
                text: statusText,
                at: CGPoint(x: margin + usableWidth - statusWidth, y: y),
                style: captionStyle
            )
            y -= 20
            drawDivider(context: context, x: margin, y: y, width: usableWidth, color: palette.divider)
            y -= 14
        }

        func ensureSpace(_ requiredHeight: CGFloat) {
            if y - requiredHeight < bottomInset {
                beginNewPage()
            }
        }

        func drawSectionHeader(_ title: String, subtitle: String? = nil) {
            let subtitleLines = subtitle.map { line in
                wrappedLines(for: line, width: usableWidth, style: captionStyle)
            } ?? []
            let subtitleHeight = CGFloat(subtitleLines.count) * captionStyle.lineHeight
            ensureSpace(sectionTitleStyle.lineHeight + subtitleHeight + 16)
            drawText(context: context, text: title, at: CGPoint(x: margin, y: y), style: sectionTitleStyle)
            y -= sectionTitleStyle.lineHeight
            for line in subtitleLines {
                drawText(context: context, text: line, at: CGPoint(x: margin, y: y), style: captionStyle)
                y -= captionStyle.lineHeight
            }
            drawDivider(context: context, x: margin, y: y + 2, width: usableWidth, color: palette.divider)
            y -= 12
        }

        func drawDetailRow(label: String, value: String) {
            let labelColumnWidth: CGFloat = 154
            let valueWidth = usableWidth - labelColumnWidth - 12
            let valueLines = wrappedLines(for: value, width: valueWidth, style: sectionBodyStyle)
            let rowLineCount = max(1, valueLines.count)
            let rowHeight = CGFloat(rowLineCount) * sectionBodyStyle.lineHeight + 12
            ensureSpace(rowHeight + 4)

            drawText(
                context: context,
                text: "\(label):",
                at: CGPoint(x: margin, y: y),
                style: sectionLabelStyle
            )

            var valueBaseline = y
            for line in valueLines {
                drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin + labelColumnWidth, y: valueBaseline),
                    style: sectionBodyStyle
                )
                valueBaseline -= sectionBodyStyle.lineHeight
            }

            y -= rowHeight
            drawDivider(context: context, x: margin, y: y + 7, width: usableWidth, color: palette.divider)
        }

        func drawMetricCard(metric: ReceiptReport.Metric, rect: CGRect) {
            drawRoundedRect(
                context: context,
                rect: rect,
                radius: 12,
                fill: palette.cardBackground,
                stroke: palette.border,
                lineWidth: 1
            )

            let toneColor: CGColor
            switch metric.tone {
            case .neutral:
                toneColor = palette.primaryText
            case .accent:
                toneColor = palette.accent
            case .success:
                toneColor = palette.success
            case .warning:
                toneColor = palette.warning
            case .danger:
                toneColor = palette.danger
            }

            let valueStyle = TextStyle(
                fontSize: metricValueStyle.fontSize,
                lineHeight: metricValueStyle.lineHeight,
                color: toneColor,
                weight: metricValueStyle.weight
            )

            drawText(
                context: context,
                text: metric.label.uppercased(),
                at: CGPoint(x: rect.minX + 12, y: rect.maxY - 22),
                style: metricLabelStyle
            )
            drawText(
                context: context,
                text: metric.value,
                at: CGPoint(x: rect.minX + 12, y: rect.maxY - 50),
                style: valueStyle
            )
        }

        func drawHero() {
            let heroHeight: CGFloat = 138
            ensureSpace(heroHeight + 12)
            let heroRect = CGRect(x: margin, y: y - heroHeight, width: usableWidth, height: heroHeight)
            drawRoundedRect(
                context: context,
                rect: heroRect,
                radius: 16,
                fill: palette.heroBackground,
                stroke: palette.heroStroke,
                lineWidth: 1
            )

            drawText(
                context: context,
                text: "RollKeep Transfer Receipt",
                at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 34),
                style: heroTitleStyle
            )
            drawText(
                context: context,
                text: "Readable evidence summary for fast validation. Full forensic details remain in NDJSON.",
                at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 54),
                style: heroBodyStyle
            )
            drawText(
                context: context,
                text: "Generated: \(report.generatedAtText)",
                at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 76),
                style: heroBodyStyle
            )
            drawText(
                context: context,
                text: "Session: \(report.sessionID)",
                at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 98),
                style: heroBodyStyle
            )

            let badgeColor: CGColor
            switch report.statusLabel {
            case "VERIFIED":
                badgeColor = palette.success
            case "FAILED":
                badgeColor = palette.danger
            case "DRY RUN":
                badgeColor = palette.warning
            default:
                badgeColor = palette.accent
            }
            let badgeText = report.statusLabel
            let badgeTextStyle = TextStyle(fontSize: 11, lineHeight: 15, color: PDFReceiptExporter.rgb(255, 255, 255), weight: .semibold)
            let badgeWidth = textWidth(badgeText, style: badgeTextStyle) + 22
            let badgeRect = CGRect(
                x: heroRect.maxX - badgeWidth - 16,
                y: heroRect.maxY - 38,
                width: badgeWidth,
                height: 24
            )
            drawRoundedRect(
                context: context,
                rect: badgeRect,
                radius: 12,
                fill: badgeColor,
                stroke: nil,
                lineWidth: 0
            )
            drawText(
                context: context,
                text: badgeText,
                at: CGPoint(x: badgeRect.minX + 11, y: badgeRect.maxY - 16),
                style: badgeTextStyle
            )

            y = heroRect.minY - 24
        }

        func drawMetrics() {
            drawSectionHeader(
                "At a Glance",
                subtitle: "Pipeline totals that matter most for immediate confidence."
            )
            let cardsPerRow = 4
            let rowGap: CGFloat = 12
            let cardHeight: CGFloat = 72
            let cardWidth = (usableWidth - (CGFloat(cardsPerRow - 1) * rowGap)) / CGFloat(cardsPerRow)
            let rowCount = Int(ceil(Double(report.metrics.count) / Double(cardsPerRow)))
            let totalHeight = CGFloat(rowCount) * cardHeight + CGFloat(max(0, rowCount - 1)) * rowGap
            ensureSpace(totalHeight + 12)

            for (index, metric) in report.metrics.enumerated() {
                let row = index / cardsPerRow
                let column = index % cardsPerRow
                let cardX = margin + CGFloat(column) * (cardWidth + rowGap)
                let cardY = y - CGFloat(row + 1) * cardHeight - CGFloat(row) * rowGap
                let rect = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
                drawMetricCard(metric: metric, rect: rect)
            }
            y -= totalHeight + 18
        }

        func drawPhaseTimings() {
            drawSectionHeader(
                "Phase Timeline",
                subtitle: "Relative duration per ingest phase."
            )

            guard !report.phaseTimings.isEmpty else {
                drawDetailRow(label: "Timings", value: "No phase timing data was recorded.")
                y -= 8
                return
            }

            let maxDuration = max(report.phaseTimings.map(\.milliseconds).max() ?? 0, 1)
            let labelWidth: CGFloat = 78
            let valueWidth: CGFloat = 56
            let trackGap: CGFloat = 10
            let trackWidth = usableWidth - labelWidth - valueWidth - (trackGap * 2)

            for timing in report.phaseTimings {
                ensureSpace(28)
                let baseline = y
                drawText(
                    context: context,
                    text: timing.phase.capitalized,
                    at: CGPoint(x: margin, y: baseline),
                    style: sectionLabelStyle
                )

                let trackRect = CGRect(
                    x: margin + labelWidth + trackGap,
                    y: baseline - 10,
                    width: trackWidth,
                    height: 8
                )
                drawRoundedRect(
                    context: context,
                    rect: trackRect,
                    radius: 4,
                    fill: PDFReceiptExporter.rgb(227, 234, 244),
                    stroke: nil,
                    lineWidth: 0
                )

                if timing.milliseconds > 0 {
                    let ratio = CGFloat(timing.milliseconds) / CGFloat(maxDuration)
                    let fillWidth = max(2, trackRect.width * ratio)
                    drawRoundedRect(
                        context: context,
                        rect: CGRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height),
                        radius: 4,
                        fill: palette.accent,
                        stroke: nil,
                        lineWidth: 0
                    )
                }

                drawText(
                    context: context,
                    text: formatDuration(milliseconds: timing.milliseconds),
                    at: CGPoint(x: trackRect.maxX + trackGap, y: baseline),
                    style: monoStyle
                )
                y -= 26
            }
            y -= 8
        }

        func drawAlertSection() {
            guard !report.alerts.isEmpty else { return }
            drawSectionHeader(
                "Attention",
                subtitle: "Review these points before treating this ingest as fully closed."
            )

            for alert in report.alerts {
                let wrapped = wrappedLines(for: "• \(alert)", width: usableWidth, style: sectionBodyStyle)
                let required = CGFloat(wrapped.count) * sectionBodyStyle.lineHeight + 6
                ensureSpace(required)
                for line in wrapped {
                    drawText(
                        context: context,
                        text: line,
                        at: CGPoint(x: margin, y: y),
                        style: TextStyle(
                            fontSize: sectionBodyStyle.fontSize,
                            lineHeight: sectionBodyStyle.lineHeight,
                            color: palette.danger,
                            weight: .medium
                        )
                    )
                    y -= sectionBodyStyle.lineHeight
                }
                y -= 4
            }
            y -= 8
        }

        func drawFileAppendix() {
            if y < (mediaBox.height * 0.45) {
                beginNewPage()
            }
            drawSectionHeader(
                "File Appendix",
                subtitle: "Per-file outcomes for quick visual audit. NDJSON remains the full forensic source."
            )

            if report.totalFileOutcomeCount > report.fileOutcomes.count {
                let note = "Showing first \(report.fileOutcomes.count) of \(report.totalFileOutcomeCount) planned files."
                let wrapped = wrappedLines(for: note, width: usableWidth, style: sectionBodyStyle)
                ensureSpace(CGFloat(wrapped.count) * sectionBodyStyle.lineHeight + 6)
                for line in wrapped {
                    drawText(
                        context: context,
                        text: line,
                        at: CGPoint(x: margin, y: y),
                        style: TextStyle(
                            fontSize: sectionBodyStyle.fontSize,
                            lineHeight: sectionBodyStyle.lineHeight,
                            color: palette.warning,
                            weight: .medium
                        )
                    )
                    y -= sectionBodyStyle.lineHeight
                }
                y -= 6
            }

            if report.fileOutcomes.isEmpty {
                drawText(
                    context: context,
                    text: "No file outcomes recorded.",
                    at: CGPoint(x: margin, y: y),
                    style: sectionBodyStyle
                )
                y -= sectionBodyStyle.lineHeight + 8
                return
            }

            for (index, outcome) in report.fileOutcomes.enumerated() {
                let header = "\(index + 1). [\(outcome.mediaType.uppercased())] \(outcome.outcome) | \(outcome.executed ? "executed" : "planned")"
                let headerLines = wrappedLines(for: header, width: usableWidth, style: sectionBodyStyle)
                let sourceLines = wrappedLines(for: "Source: \(outcome.path)", width: usableWidth, style: monoStyle)
                let finalLines = wrappedLines(for: "Final: \(outcome.finalPath)", width: usableWidth, style: monoStyle)
                let required = CGFloat(headerLines.count) * sectionBodyStyle.lineHeight
                    + CGFloat(sourceLines.count + finalLines.count) * monoStyle.lineHeight
                    + 8

                ensureSpace(required + 6)

                for line in headerLines {
                    drawText(
                        context: context,
                        text: line,
                        at: CGPoint(x: margin, y: y),
                        style: sectionBodyStyle
                    )
                    y -= sectionBodyStyle.lineHeight
                }
                for line in sourceLines {
                    drawText(
                        context: context,
                        text: line,
                        at: CGPoint(x: margin, y: y),
                        style: monoStyle
                    )
                    y -= monoStyle.lineHeight
                }
                for line in finalLines {
                    drawText(
                        context: context,
                        text: line,
                        at: CGPoint(x: margin, y: y),
                        style: monoStyle
                    )
                    y -= monoStyle.lineHeight
                }
                y -= 2
                drawDivider(context: context, x: margin, y: y + 4, width: usableWidth, color: palette.divider)
                y -= 6
            }
        }

        func drawScanErrorsIfNeeded() {
            guard !report.scanErrors.isEmpty else { return }
            drawSectionHeader("Scan Errors", subtitle: "Top scan errors recorded during source traversal.")
            for entry in report.scanErrors {
                let wrapped = wrappedLines(for: "• \(entry)", width: usableWidth, style: sectionBodyStyle)
                let required = CGFloat(wrapped.count) * sectionBodyStyle.lineHeight + 4
                ensureSpace(required)
                for line in wrapped {
                    drawText(
                        context: context,
                        text: line,
                        at: CGPoint(x: margin, y: y),
                        style: sectionBodyStyle
                    )
                    y -= sectionBodyStyle.lineHeight
                }
                y -= 3
            }
        }

        drawHero()
        drawMetrics()

        drawSectionHeader(
            "Run Context",
            subtitle: "Where this run happened and where to find complete evidence."
        )
        for row in report.contextRows {
            drawDetailRow(label: row.0, value: row.1)
        }
        y -= 14

        drawSectionHeader(
            "Capture Inventory",
            subtitle: "Camera and date context extracted from the full card scan."
        )
        for row in report.inventoryRows {
            drawDetailRow(label: row.0, value: row.1)
        }
        if !report.cameraDistribution.isEmpty {
            let distributionText = report.cameraDistribution.map { "• \($0)" }.joined(separator: "    ")
            drawDetailRow(label: "Distribution", value: distributionText)
        }
        y -= 14

        drawPhaseTimings()
        drawAlertSection()
        drawFileAppendix()
        drawScanErrorsIfNeeded()

        ensureSpace(captionStyle.lineHeight + 4)
        drawText(
            context: context,
            text: "Full forensic event stream: \(report.receiptPath) [\(report.receiptSinkKind)]",
            at: CGPoint(x: margin, y: y),
            style: captionStyle
        )

        drawFooter(
            context: context,
            pageRect: mediaBox,
            pageNumber: pageNumber,
            sessionID: report.sessionID,
            palette: palette
        )
        context.endPDFPage()
        context.closePDF()
    }

    private func drawPageBackground(context: CGContext, pageRect: CGRect, color: CGColor) {
        context.saveGState()
        context.setFillColor(color)
        context.fill(pageRect)
        context.restoreGState()
    }

    private func drawDivider(context: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, color: CGColor) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(0.6)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
        context.restoreGState()
    }

    private func drawFooter(
        context: CGContext,
        pageRect: CGRect,
        pageNumber: Int,
        sessionID: String,
        palette: Palette
    ) {
        drawDivider(
            context: context,
            x: 44,
            y: 42,
            width: pageRect.width - 88,
            color: palette.divider
        )
        drawText(
            context: context,
            text: "RollKeep transfer receipt",
            at: CGPoint(x: 44, y: 26),
            style: TextStyle(fontSize: 9, lineHeight: 12, color: palette.secondaryText, weight: .regular)
        )
        drawText(
            context: context,
            text: "Session \(sessionID) • Page \(pageNumber)",
            at: CGPoint(x: pageRect.width - 180, y: 26),
            style: TextStyle(fontSize: 9, lineHeight: 12, color: palette.secondaryText, weight: .regular)
        )
    }

    private func drawRoundedRect(
        context: CGContext,
        rect: CGRect,
        radius: CGFloat,
        fill: CGColor,
        stroke: CGColor?,
        lineWidth: CGFloat
    ) {
        context.saveGState()
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(fill)
        if let stroke {
            context.setStrokeColor(stroke)
            context.setLineWidth(lineWidth)
            context.drawPath(using: .fillStroke)
        } else {
            context.drawPath(using: .fill)
        }
        context.restoreGState()
    }

    private func drawText(
        context: CGContext,
        text: String,
        at point: CGPoint,
        style: TextStyle
    ) {
        let font = font(size: style.fontSize, weight: style.weight)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private func wrappedLines(for text: String, width: CGFloat, style: TextStyle) -> [String] {
        guard !text.isEmpty else { return [""] }
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        guard !words.isEmpty else { return [text] }

        var lines: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if textWidth(candidate, style: style) <= width {
                current = candidate
            } else {
                if !current.isEmpty {
                    lines.append(current)
                }

                let wordString = String(word)
                if textWidth(wordString, style: style) <= width {
                    current = wordString
                } else {
                    lines.append(contentsOf: hardWrap(wordString, width: width, style: style))
                    current = ""
                }
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines.isEmpty ? [text] : lines
    }

    private func hardWrap(_ text: String, width: CGFloat, style: TextStyle) -> [String] {
        var chunks: [String] = []
        var current = ""

        for character in text {
            let candidate = current + String(character)
            if textWidth(candidate, style: style) <= width || current.isEmpty {
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

    private func textWidth(_ text: String, style: TextStyle) -> CGFloat {
        let font = font(size: style.fontSize, weight: style.weight)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return ceil(bounds.width)
    }

    private func font(size: CGFloat, weight: TextStyle.Weight) -> CTFont {
        let candidates: [String]
        switch weight {
        case .regular:
            candidates = ["SFProText-Regular", "HelveticaNeue", "Helvetica"]
        case .medium:
            candidates = ["SFProText-Medium", "HelveticaNeue-Medium", "Helvetica-Bold"]
        case .semibold:
            candidates = ["SFProText-Semibold", "HelveticaNeue-Bold", "Helvetica-Bold"]
        case .bold:
            candidates = ["SFProDisplay-Bold", "HelveticaNeue-Bold", "Helvetica-Bold"]
        case .mono:
            candidates = ["SFMono-Regular", "Menlo-Regular", "Courier"]
        }

        for candidate in candidates {
            let font = CTFontCreateWithName(candidate as CFString, size, nil)
            let postScriptName = CTFontCopyPostScriptName(font) as String
            if postScriptName != ".LastResort" {
                return font
            }
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func formatDuration(milliseconds: Int) -> String {
        String(format: "%.2fs", Double(milliseconds) / 1_000.0)
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1.0) -> CGColor {
        CGColor(
            red: red / 255.0,
            green: green / 255.0,
            blue: blue / 255.0,
            alpha: alpha
        )
    }
}
