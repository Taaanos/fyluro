import CoreGraphics
import Foundation
import FyluroCore

extension PDFReceiptPageComposer {
    mutating func drawHeader() {
        let padding: CGFloat = 18
        let labelWidth: CGFloat = 92
        let rowGap: CGFloat = 5
        let valueWidth = usableWidth - (padding * 2) - labelWidth
        let rows = report.contextRows.map { row in
            (label: row.0, lines: textRenderer.wrappedLines(for: row.1, width: valueWidth, style: sectionBodyStyle))
        }
        let rowsHeight = rows.reduce(CGFloat(0)) { total, row in
            total + CGFloat(row.lines.count) * sectionBodyStyle.lineHeight + rowGap
        }
        let firstRowOffset = padding + 52
        let heroHeight = firstRowOffset + rowsHeight - rowGap + 4 + padding
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
            at: CGPoint(x: heroRect.minX + padding, y: heroRect.maxY - padding - 22),
            style: heroTitleStyle
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
            x: heroRect.maxX - badgeWidth - padding,
            y: heroRect.maxY - padding - 24,
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

        var rowBaseline = heroRect.maxY - firstRowOffset - sectionBodyStyle.fontSize
        for row in rows {
            textRenderer.drawText(
                context: context,
                text: "\(row.label):",
                at: CGPoint(x: heroRect.minX + padding, y: rowBaseline),
                style: sectionLabelStyle
            )
            for line in row.lines {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: heroRect.minX + padding + labelWidth, y: rowBaseline),
                    style: sectionBodyStyle
                )
                rowBaseline -= sectionBodyStyle.lineHeight
            }
            rowBaseline -= rowGap
        }

        y = heroRect.minY - 24
    }

    mutating func drawFilmModeSection() {
        guard let film = report.filmMode else { return }
        drawSectionHeader("Film Mode")

        let headlineStyle = PDFReceiptTextStyle(
            fontSize: 12,
            lineHeight: 17,
            color: palette.primaryText,
            weight: .semibold
        )
        let headlineLines = textRenderer.wrappedLines(for: film.headline, width: usableWidth, style: headlineStyle)
        ensureSpace(CGFloat(headlineLines.count) * headlineStyle.lineHeight + 8)
        for line in headlineLines {
            textRenderer.drawText(context: context, text: line, at: CGPoint(x: margin, y: y), style: headlineStyle)
            y -= headlineStyle.lineHeight
        }
        y -= 8

        for row in film.detailRows {
            drawDetailRow(label: row.0, value: row.1)
        }

        let noteLines = textRenderer.wrappedLines(for: film.exifNote, width: usableWidth, style: captionStyle)
        ensureSpace(CGFloat(noteLines.count) * captionStyle.lineHeight + 4)
        for line in noteLines {
            textRenderer.drawText(context: context, text: line, at: CGPoint(x: margin, y: y), style: captionStyle)
            y -= captionStyle.lineHeight
        }
        y -= 18
    }

    static func metricCardRects(
        count: Int,
        maxPerRow: Int = 4,
        originX: CGFloat,
        topY: CGFloat,
        usableWidth: CGFloat,
        cardHeight: CGFloat,
        gap: CGFloat
    ) -> [CGRect] {
        guard count > 0, maxPerRow > 0 else { return [] }
        let rowCount = Int(ceil(Double(count) / Double(maxPerRow)))
        var rects: [CGRect] = []
        rects.reserveCapacity(count)

        for row in 0..<rowCount {
            let startIndex = row * maxPerRow
            let rowItemCount = min(maxPerRow, count - startIndex)
            let cardWidth = (usableWidth - (CGFloat(rowItemCount - 1) * gap)) / CGFloat(rowItemCount)
            let cardY = topY - CGFloat(row + 1) * cardHeight - CGFloat(row) * gap
            for column in 0..<rowItemCount {
                let cardX = originX + CGFloat(column) * (cardWidth + gap)
                rects.append(CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight))
            }
        }
        return rects
    }

    mutating func drawMetrics() {
        drawSectionHeader(
            "At a Glance",
            subtitle: "Summary counts for this import."
        )
        let cardsPerRow = 4
        let rowGap: CGFloat = 12
        let cardHeight: CGFloat = 80
        let rowCount = Int(ceil(Double(report.metrics.count) / Double(cardsPerRow)))
        let totalHeight = CGFloat(rowCount) * cardHeight + CGFloat(max(0, rowCount - 1)) * rowGap
        ensureSpace(totalHeight + 12)

        let rects = Self.metricCardRects(
            count: report.metrics.count,
            maxPerRow: cardsPerRow,
            originX: margin,
            topY: y,
            usableWidth: usableWidth,
            cardHeight: cardHeight,
            gap: rowGap
        )
        for (metric, rect) in zip(report.metrics, rects) {
            drawMetricCard(metric: metric, rect: rect)
        }
        y -= totalHeight + 30
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
            at: CGPoint(x: rect.minX + 12, y: rect.maxY - 46),
            style: valueStyle
        )

        if let subtitle = metric.subtitle {
            let subtitleStyle = PDFReceiptTextStyle(
                fontSize: 8,
                lineHeight: 10,
                color: palette.secondaryText,
                weight: .regular
            )
            let lines = textRenderer.wrappedLines(for: subtitle, width: rect.width - 24, style: subtitleStyle)
            var baseline = rect.maxY - 60
            for line in lines.prefix(3) {
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: rect.minX + 12, y: baseline),
                    style: subtitleStyle
                )
                baseline -= subtitleStyle.lineHeight
            }
        }
    }

    mutating func drawAttentionSection() {
        if !report.alerts.isEmpty {
            drawSectionHeader("Attention")
            for alert in report.alerts {
                drawWrappedParagraph("• \(alert)", color: palette.danger, weight: .medium, gapAfter: 4)
            }
            y -= 8
        }
        for notice in report.notices {
            drawWrappedParagraph(notice, color: palette.secondaryText, gapAfter: 4)
        }
        if !report.notices.isEmpty {
            y -= 10
        }
    }

    mutating func drawWrappedParagraph(
        _ text: String,
        style: PDFReceiptTextStyle? = nil,
        color: CGColor? = nil,
        weight: PDFReceiptTextStyle.Weight? = nil,
        gapAfter: CGFloat = 4
    ) {
        let base = style ?? sectionBodyStyle
        let paragraphStyle = PDFReceiptTextStyle(
            fontSize: base.fontSize,
            lineHeight: base.lineHeight,
            color: color ?? base.color,
            weight: weight ?? base.weight
        )
        let lines = textRenderer.wrappedLines(for: text, width: usableWidth, style: paragraphStyle)
        for line in lines {
            ensureSpace(paragraphStyle.lineHeight + 2)
            textRenderer.drawText(context: context, text: line, at: CGPoint(x: margin, y: y), style: paragraphStyle)
            y -= paragraphStyle.lineHeight
        }
        y -= gapAfter
    }

    mutating func drawTable(_ table: PDFReceiptTable, rows: [[String]], showHeader: Bool = true) {
        func drawHeader(on composer: inout PDFReceiptPageComposer) {
            guard showHeader else { return }
            let titles = table.columns.map(\.title)
            composer.ensureSpace(table.rowHeight(cells: titles, header: true) + 4)
            let height = table.drawRow(
                cells: titles,
                context: composer.context,
                x: composer.margin,
                baseline: composer.y,
                header: true
            )
            composer.y -= height - 2
            composer.primitives.drawDivider(
                context: composer.context,
                x: composer.margin,
                y: composer.y + 2,
                width: composer.usableWidth,
                color: composer.palette.divider
            )
            composer.y -= 8
        }

        drawHeader(on: &self)
        for cells in rows {
            let height = table.rowHeight(cells: cells)
            let pageBefore = pageNumber
            ensureSpace(height + 2)
            if pageNumber != pageBefore {
                drawHeader(on: &self)
            }
            table.drawRow(cells: cells, context: context, x: margin, baseline: y)
            y -= height
        }
    }

    private func appendixTable(columns: [PDFReceiptTable.Column]) -> PDFReceiptTable {
        PDFReceiptTable(columns: columns, bodyStyle: sectionBodyStyle, monoStyle: pathStyle, headerStyle: sectionLabelStyle)
    }

    private func minimumTableStartHeight(
        table: PDFReceiptTable,
        rows: [[String]],
        showHeader: Bool = true
    ) -> CGFloat {
        let headerHeight: CGFloat
        if showHeader {
            let titles = table.columns.map(\.title)
            headerHeight = table.rowHeight(cells: titles, header: true) + 6
        } else {
            headerHeight = 0
        }
        let firstRowHeight = rows.first.map { table.rowHeight(cells: $0) + 2 } ?? 0
        return headerHeight + firstRowHeight
    }

    mutating func drawNeedsLookSection() {
        guard report.needsLookTotal > 0 else { return }
        let labelWidth: CGFloat = 92
        let table = appendixTable(columns: [
            .init(title: "Kind", width: labelWidth, rightAligned: false, monospaced: false, color: palette.danger),
            .init(title: "Path", width: usableWidth - labelWidth, rightAligned: false, monospaced: true),
        ])
        let rows = report.needsLook.map { item in
            [item.label, item.note.map { "\(item.path) — \($0)" } ?? item.path]
        }
        drawSectionHeader(
            "Needs Attention",
            subtitle: "Errors and files that did not finish. Library paths are relative to the destination.",
            minimumFollowingHeight: minimumTableStartHeight(table: table, rows: rows)
        )
        drawTable(table, rows: rows)
        drawMoreLine(shown: report.needsLook.count, total: report.needsLookTotal, noun: "more — see the .ndjson receipt")
        y -= 10
    }

    mutating func drawRenamedSection() {
        guard report.renamedTotal > 0 else { return }
        let half = usableWidth / 2
        let table = appendixTable(columns: [
            .init(title: "On the Card", width: half, rightAligned: false, monospaced: true),
            .init(title: "In the Library", width: half, rightAligned: false, monospaced: true),
        ])
        let rows = report.renamed.map { [$0.sourcePath, $0.finalPath] }
        drawSectionHeader(
            "Renamed to Avoid Overwrite",
            subtitle: "Same name, different content. \(AppBrand.name) kept both files and added a suffix to the new one.",
            minimumFollowingHeight: minimumTableStartHeight(table: table, rows: rows)
        )
        drawTable(table, rows: rows)
        drawMoreLine(shown: report.renamed.count, total: report.renamedTotal, noun: "more — see the .ndjson receipt")
        y -= 10
    }

    mutating func drawLandedSection() {
        guard report.landedFolderTotal > 0 else { return }
        let numberWidths: [CGFloat] = [48, 48, 44, 62, 46]
        let table = appendixTable(columns: [
            .init(title: "Folder", width: usableWidth - numberWidths.reduce(0, +), rightAligned: false, monospaced: true),
            .init(title: "Photos", width: numberWidths[0], rightAligned: true, monospaced: false),
            .init(title: "Videos", width: numberWidths[1], rightAligned: true, monospaced: false),
            .init(title: "Audio", width: numberWidths[2], rightAligned: true, monospaced: false),
            .init(title: "Sidecars", width: numberWidths[3], rightAligned: true, monospaced: false),
            .init(title: "Total", width: numberWidths[4], rightAligned: true, monospaced: false),
        ])
        let rows = report.landed.map { folder in
            [
                folder.folder,
                "\(folder.photos)", "\(folder.videos)", "\(folder.audio)", "\(folder.sidecars)",
                "\(folder.total)",
            ]
        }
        drawSectionHeader(
            report.dryRun ? "Planned Destination Folders" : "Destination Folders",
            subtitle: "Files added to the library. Folders are relative to the destination.",
            minimumFollowingHeight: minimumTableStartHeight(table: table, rows: rows)
        )
        drawTable(table, rows: rows)
        drawMoreLine(shown: report.landed.count, total: report.landedFolderTotal, noun: "more folders")
        y -= 12
    }

    mutating func drawMoreLine(shown: Int, total: Int, noun: String) {
        guard total > shown else { return }
        y -= 4
        drawWrappedParagraph("and \(total - shown) \(noun)", style: captionStyle, gapAfter: 6)
    }

    mutating func drawAlreadyInLibraryNote() {
        if report.foundCount == 0 {
            drawWrappedParagraph("No files were found on the card.", style: captionStyle, gapAfter: 8)
            return
        }
        guard report.alreadyInLibraryCount > 0 else { return }
        let count = report.alreadyInLibraryCount
        let noun = count == 1 ? "file was" : "files were"
        drawWrappedParagraph(
            "Already in library: \(count) \(noun) not copied again. They are listed one by one in the .ndjson receipt.",
            style: sectionBodyStyle,
            gapAfter: 10
        )
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
