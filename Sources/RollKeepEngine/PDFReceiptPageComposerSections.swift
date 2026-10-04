import CoreGraphics
import Foundation
import RollKeepCore

extension PDFReceiptPageComposer {
    mutating func drawHero() {
        let heroHeight: CGFloat = 138
        ensureSpace(heroHeight + 12)
        let heroRect = CGRect(x: margin, y: y - heroHeight, width: usableWidth, height: heroHeight)
        primitives.drawRoundedRect(
            context: context,
            rect: heroRect,
            radius: 16,
            fill: palette.heroBackground,
            stroke: palette.heroStroke,
            lineWidth: 1
        )

        textRenderer.drawText(
            context: context,
            text: "\(AppBrand.name) Transfer Receipt",
            at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 34),
            style: heroTitleStyle
        )
        textRenderer.drawText(
            context: context,
            text: "Readable evidence summary for fast validation.",
            at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 54),
            style: heroBodyStyle
        )
        textRenderer.drawText(
            context: context,
            text: "Generated: \(report.generatedAtText)",
            at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 76),
            style: heroBodyStyle
        )
        textRenderer.drawText(
            context: context,
            text: "Session: \(report.sessionID)",
            at: CGPoint(x: heroRect.minX + 18, y: heroRect.maxY - 98),
            style: heroBodyStyle
        )

        let badgeColor = toneColor(for: report.statusLabel)
        let badgeText = report.statusLabel
        let badgeTextStyle = PDFReceiptTextStyle(
            fontSize: 11,
            lineHeight: 15,
            color: pdfReceiptRGB(255, 255, 255),
            weight: .semibold
        )
        let badgeWidth = textRenderer.singleLineWidth(badgeText, style: badgeTextStyle) + 22
        let badgeRect = CGRect(
            x: heroRect.maxX - badgeWidth - 16,
            y: heroRect.maxY - 38,
            width: badgeWidth,
            height: 24
        )
        primitives.drawRoundedRect(
            context: context,
            rect: badgeRect,
            radius: 12,
            fill: badgeColor,
            stroke: nil,
            lineWidth: 0
        )
        textRenderer.drawText(
            context: context,
            text: badgeText,
            at: CGPoint(x: badgeRect.minX + 11, y: badgeRect.maxY - 16),
            style: badgeTextStyle
        )

        y = heroRect.minY - 24
    }

    mutating func drawMetrics() {
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

    func drawMetricCard(metric: ReceiptReport.Metric, rect: CGRect) {
        primitives.drawRoundedRect(
            context: context,
            rect: rect,
            radius: 12,
            fill: palette.cardBackground,
            stroke: palette.border,
            lineWidth: 1
        )

        let valueStyle = PDFReceiptTextStyle(
            fontSize: metricValueStyle.fontSize,
            lineHeight: metricValueStyle.lineHeight,
            color: toneColor(for: metric.tone),
            weight: metricValueStyle.weight
        )

        textRenderer.drawText(
            context: context,
            text: metric.label.uppercased(),
            at: CGPoint(x: rect.minX + 12, y: rect.maxY - 22),
            style: metricLabelStyle
        )
        textRenderer.drawText(
            context: context,
            text: metric.value,
            at: CGPoint(x: rect.minX + 12, y: rect.maxY - 50),
            style: valueStyle
        )
    }

    mutating func drawAttentionSection() {
        guard !report.alerts.isEmpty || !report.scanErrors.isEmpty else { return }
        drawSectionHeader(
            "Attention",
            subtitle: "Review these points before treating this ingest as fully closed."
        )

        for alert in report.alerts {
            let wrapped = textRenderer.wrappedLines(for: "• \(alert)", width: usableWidth, style: sectionBodyStyle)
            let required = CGFloat(wrapped.count) * sectionBodyStyle.lineHeight + 6
            ensureSpace(required)
            for line in wrapped {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin, y: y),
                    style: PDFReceiptTextStyle(
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

        if report.totalScanErrorCount > report.scanErrors.count {
            let note = "Showing first \(report.scanErrors.count) of \(report.totalScanErrorCount) scan errors."
            let wrapped = textRenderer.wrappedLines(for: note, width: usableWidth, style: sectionBodyStyle)
            ensureSpace(CGFloat(wrapped.count) * sectionBodyStyle.lineHeight + 6)
            for line in wrapped {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin, y: y),
                    style: PDFReceiptTextStyle(
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

        for entry in report.scanErrors {
            let wrapped = textRenderer.wrappedLines(for: "• \(entry)", width: usableWidth, style: sectionBodyStyle)
            let required = CGFloat(wrapped.count) * sectionBodyStyle.lineHeight + 4
            ensureSpace(required)
            for line in wrapped {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin, y: y),
                    style: PDFReceiptTextStyle(
                        fontSize: sectionBodyStyle.fontSize,
                        lineHeight: sectionBodyStyle.lineHeight,
                        color: palette.danger,
                        weight: .medium
                    )
                )
                y -= sectionBodyStyle.lineHeight
            }
            y -= 3
        }

        y -= 8
    }

    mutating func drawFileAppendix() {
        if y < (mediaBox.height * 0.45) {
            beginNewPage()
        }
        drawSectionHeader(
            "File Appendix",
            subtitle: "Per-file outcomes for quick visual audit."
        )

        if report.totalFileOutcomeCount > report.fileOutcomes.count {
            let note = "Showing first \(report.fileOutcomes.count) of \(report.totalFileOutcomeCount) planned files."
            let wrapped = textRenderer.wrappedLines(for: note, width: usableWidth, style: sectionBodyStyle)
            ensureSpace(CGFloat(wrapped.count) * sectionBodyStyle.lineHeight + 6)
            for line in wrapped {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin, y: y),
                    style: PDFReceiptTextStyle(
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
            textRenderer.drawText(
                context: context,
                text: "No file outcomes recorded.",
                at: CGPoint(x: margin, y: y),
                style: sectionBodyStyle
            )
            y -= sectionBodyStyle.lineHeight + 8
            return
        }

        let headerGap: CGFloat = 3
        let interEntryGap: CGFloat = 14

        for (index, outcome) in report.fileOutcomes.enumerated() {
            let (statusLabel, statusColor) = fileOutcomeStatus(for: outcome)
            let prefix = "\(index + 1)  \(outcome.mediaType.uppercased())"
            let sourceLines = textRenderer.wrappedLines(for: outcome.sourcePath, width: usableWidth, style: pathStyle)
            let finalLines = textRenderer.wrappedLines(for: "→ \(outcome.finalPath)", width: usableWidth, style: pathStyle)
            let entryHeight = sectionLabelStyle.lineHeight + headerGap
                + CGFloat(sourceLines.count + finalLines.count) * pathStyle.lineHeight

            ensureSpace(entryHeight + interEntryGap)

            textRenderer.drawText(context: context, text: prefix, at: CGPoint(x: margin, y: y), style: sectionLabelStyle)
            let prefixWidth = textRenderer.singleLineWidth(prefix, style: sectionLabelStyle)
            textRenderer.drawText(
                context: context,
                text: statusLabel,
                at: CGPoint(x: margin + prefixWidth + 8, y: y),
                style: PDFReceiptTextStyle(
                    fontSize: sectionLabelStyle.fontSize,
                    lineHeight: sectionLabelStyle.lineHeight,
                    color: statusColor,
                    weight: .semibold
                )
            )
            y -= sectionLabelStyle.lineHeight + headerGap

            for line in sourceLines {
                textRenderer.drawText(context: context, text: line, at: CGPoint(x: margin, y: y), style: pathStyle)
                y -= pathStyle.lineHeight
            }
            for line in finalLines {
                textRenderer.drawText(context: context, text: line, at: CGPoint(x: margin, y: y), style: pathStyle)
                y -= pathStyle.lineHeight
            }

            y -= interEntryGap
        }
    }

    func fileOutcomeStatus(for outcome: ReceiptReport.FileOutcome) -> (String, CGColor) {
        if outcome.outcome == "duplicate_not_copied" {
            return ("Duplicate — not copied", palette.warning)
        }
        if outcome.executed {
            return (outcome.collisionRenamed ? "Committed (renamed)" : "Committed", palette.success)
        }
        return ("Planned", palette.accent)
    }

    mutating func drawForensicNote() {
        let text = "Full forensic event stream: \(report.receiptPath) [\(report.receiptSinkKind)]"
        let wrapped = textRenderer.wrappedLines(for: text, width: usableWidth, style: captionStyle)
        ensureSpace(CGFloat(wrapped.count) * captionStyle.lineHeight + 4)
        for line in wrapped {
            textRenderer.drawText(
                context: context,
                text: line,
                at: CGPoint(x: margin, y: y),
                style: captionStyle
            )
            y -= captionStyle.lineHeight
        }
    }

    func toneColor(for tone: ReceiptReport.Metric.Tone) -> CGColor {
        switch tone {
        case .neutral:
            return palette.primaryText
        case .accent:
            return palette.accent
        case .success:
            return palette.success
        case .warning:
            return palette.warning
        case .danger:
            return palette.danger
        }
    }

    func toneColor(for status: String) -> CGColor {
        switch status {
        case "VERIFIED":
            return palette.success
        case "FAILED":
            return palette.danger
        case "DRY RUN":
            return palette.warning
        default:
            return palette.accent
        }
    }
}
