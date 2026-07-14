import CoreGraphics
import Foundation

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
            text: "RollKeep Transfer Receipt",
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

    mutating func drawPhaseTimings() {
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
        let trackGap: CGFloat = 10
        let trackWidth = usableWidth - labelWidth - 56 - (trackGap * 2)

        for timing in report.phaseTimings {
            ensureSpace(28)
            let baseline = y
            textRenderer.drawText(
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
            primitives.drawRoundedRect(
                context: context,
                rect: trackRect,
                radius: 4,
                fill: pdfReceiptRGB(227, 234, 244),
                stroke: nil,
                lineWidth: 0
            )

            if timing.milliseconds > 0 {
                let ratio = CGFloat(timing.milliseconds) / CGFloat(maxDuration)
                let fillWidth = max(2, trackRect.width * ratio)
                primitives.drawRoundedRect(
                    context: context,
                    rect: CGRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height),
                    radius: 4,
                    fill: palette.accent,
                    stroke: nil,
                    lineWidth: 0
                )
            }

            textRenderer.drawText(
                context: context,
                text: textRenderer.formatDuration(milliseconds: timing.milliseconds),
                at: CGPoint(x: trackRect.maxX + trackGap, y: baseline),
                style: monoStyle
            )
            y -= 26
        }
        y -= 8
    }

    mutating func drawAlertSection() {
        guard !report.alerts.isEmpty else { return }
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

        for (index, outcome) in report.fileOutcomes.enumerated() {
            let header = "\(index + 1). [\(outcome.mediaType.uppercased())] \(outcome.outcome) | \(outcome.executed ? "executed" : "planned")"
            let headerLines = textRenderer.wrappedLines(for: header, width: usableWidth, style: sectionBodyStyle)
            let sourceLines = textRenderer.wrappedLines(for: "Source: \(outcome.path)", width: usableWidth, style: monoStyle)
            let finalLines = textRenderer.wrappedLines(for: "Final: \(outcome.finalPath)", width: usableWidth, style: monoStyle)
            let required = CGFloat(headerLines.count) * sectionBodyStyle.lineHeight
                + CGFloat(sourceLines.count + finalLines.count) * monoStyle.lineHeight
                + 8

            ensureSpace(required + 6)

            for line in headerLines {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin, y: y),
                    style: sectionBodyStyle
                )
                y -= sectionBodyStyle.lineHeight
            }
            for line in sourceLines {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin, y: y),
                    style: monoStyle
                )
                y -= monoStyle.lineHeight
            }
            for line in finalLines {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: margin, y: y),
                    style: monoStyle
                )
                y -= monoStyle.lineHeight
            }
            y -= 2
            primitives.drawDivider(context: context, x: margin, y: y + 4, width: usableWidth, color: palette.divider)
            y -= 6
        }
    }

    mutating func drawScanErrorsIfNeeded() {
        guard !report.scanErrors.isEmpty else { return }
        drawSectionHeader("Scan Errors", subtitle: "Files skipped during source traversal. Review before archival decisions.")

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
                    style: sectionBodyStyle
                )
                y -= sectionBodyStyle.lineHeight
            }
            y -= 3
        }
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
