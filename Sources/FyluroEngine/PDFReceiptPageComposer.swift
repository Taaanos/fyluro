import CoreGraphics
import Foundation
import FyluroCore

struct PDFReceiptPageComposer {
    typealias ReceiptReport = PDFReceiptReport

    let report: ReceiptReport
    let context: CGContext
    let mediaBox: CGRect
    let palette = PDFReceiptPalette()
    let primitives = PDFReceiptDrawingPrimitives()
    let textRenderer = PDFReceiptTextRenderer()

    let margin: CGFloat = 48
    let topInset: CGFloat = 56
    let bottomInset: CGFloat = 48
    var pageNumber = 1
    var y: CGFloat

    var usableWidth: CGFloat { mediaBox.width - (margin * 2) }

    var heroTitleStyle: PDFReceiptTextStyle {
        .init(fontSize: 24, lineHeight: 30, color: palette.primaryText, weight: .bold)
    }

    var heroBodyStyle: PDFReceiptTextStyle {
        .init(fontSize: 11, lineHeight: 15, color: palette.secondaryText, weight: .regular)
    }

    var sectionTitleStyle: PDFReceiptTextStyle {
        .init(fontSize: 15, lineHeight: 20, color: palette.primaryText, weight: .semibold)
    }

    var sectionBodyStyle: PDFReceiptTextStyle {
        .init(fontSize: 11, lineHeight: 15, color: palette.primaryText, weight: .regular)
    }

    var sectionLabelStyle: PDFReceiptTextStyle {
        .init(fontSize: 10, lineHeight: 14, color: palette.secondaryText, weight: .medium)
    }

    var captionStyle: PDFReceiptTextStyle {
        .init(fontSize: 9, lineHeight: 13, color: palette.secondaryText, weight: .regular)
    }

    var metricLabelStyle: PDFReceiptTextStyle {
        .init(fontSize: 9, lineHeight: 12, color: palette.secondaryText, weight: .medium)
    }

    var metricValueStyle: PDFReceiptTextStyle {
        .init(fontSize: 19, lineHeight: 23, color: palette.primaryText, weight: .semibold)
    }

    var monoStyle: PDFReceiptTextStyle {
        .init(fontSize: 9.5, lineHeight: 13, color: palette.secondaryText, weight: .mono)
    }

    var pathStyle: PDFReceiptTextStyle {
        .init(fontSize: 9.5, lineHeight: 12, color: palette.primaryText, weight: .mono)
    }

    init(report: ReceiptReport, context: CGContext, mediaBox: CGRect) {
        self.report = report
        self.context = context
        self.mediaBox = mediaBox
        self.y = mediaBox.height - topInset
    }

    mutating func render() {
        context.beginPDFPage(nil)
        primitives.drawPageBackground(context: context, pageRect: mediaBox, color: palette.pageBackground)

        drawHeader()
        drawFilmModeSection()
        drawAttentionSection()
        drawMetrics()

        // Keep the heading with its rows. A section must not start at the bottom of a page.
        ensureSpace(190)
        drawSectionHeader(
            "Capture Inventory",
            subtitle: "Camera and date context extracted from the full card scan."
        )
        for row in report.inventoryRows {
            drawDetailRow(label: row.0, value: row.1)
        }
        if !report.cameraDistribution.isEmpty {
            let distributionText = report.cameraDistribution.map { "•\u{00A0}\($0)" }.joined(separator: "    ")
            drawDetailRow(label: "Distribution", value: distributionText)
        }
        y -= 14

        drawNeedsLookSection()
        drawRenamedSection()
        drawLandedSection()
        drawAlreadyInLibraryNote()
        drawForensicNote()

        primitives.drawFooter(
            context: context,
            pageRect: mediaBox,
            pageNumber: pageNumber,
            sessionID: report.sessionID,
            palette: palette
        )
        context.endPDFPage()
    }

    mutating func beginNewPage() {
        primitives.drawFooter(
            context: context,
            pageRect: mediaBox,
            pageNumber: pageNumber,
            sessionID: report.sessionID,
            palette: palette
        )
        context.endPDFPage()
        context.beginPDFPage(nil)
        pageNumber += 1
        primitives.drawPageBackground(context: context, pageRect: mediaBox, color: palette.pageBackground)
        y = mediaBox.height - topInset

        let continuationTitle = "\(AppBrand.name) Transfer Receipt Appendix"
        textRenderer.drawText(
            context: context,
            text: continuationTitle,
            at: CGPoint(x: margin, y: y),
            style: PDFReceiptTextStyle(fontSize: 12, lineHeight: 16, color: palette.primaryText, weight: .semibold)
        )
        let statusText = "Status: \(report.statusLabel)"
        let statusWidth = textRenderer.singleLineWidth(statusText, style: captionStyle)
        textRenderer.drawText(
            context: context,
            text: statusText,
            at: CGPoint(x: margin + usableWidth - statusWidth, y: y),
            style: captionStyle
        )
        y -= 28
    }

    mutating func ensureSpace(_ requiredHeight: CGFloat) {
        if y - requiredHeight < bottomInset {
            beginNewPage()
        }
    }

    mutating func drawSectionHeader(
        _ title: String,
        subtitle: String? = nil,
        minimumFollowingHeight: CGFloat = 0
    ) {
        let subtitleLines = subtitle.map { line in
            textRenderer.wrappedLines(for: line, width: usableWidth, style: captionStyle)
        } ?? []
        let subtitleHeight = CGFloat(subtitleLines.count) * captionStyle.lineHeight
        ensureSpace(sectionTitleStyle.lineHeight + subtitleHeight + 16 + minimumFollowingHeight)
        textRenderer.drawText(context: context, text: title, at: CGPoint(x: margin, y: y), style: sectionTitleStyle)
        y -= sectionTitleStyle.lineHeight
        for line in subtitleLines {
            textRenderer.drawText(context: context, text: line, at: CGPoint(x: margin, y: y), style: captionStyle)
            y -= captionStyle.lineHeight
        }
        y -= 16
    }

    mutating func drawDetailRow(label: String, value: String) {
        let labelColumnWidth: CGFloat = 154
        let valueWidth = usableWidth - labelColumnWidth - 12
        let valueLines = textRenderer.wrappedLines(for: value, width: valueWidth, style: sectionBodyStyle)
        let rowLineCount = max(1, valueLines.count)
        let rowHeight = CGFloat(rowLineCount) * sectionBodyStyle.lineHeight + 8
        ensureSpace(rowHeight + 4)

        textRenderer.drawText(
            context: context,
            text: "\(label):",
            at: CGPoint(x: margin, y: y),
            style: sectionLabelStyle
        )

        var valueBaseline = y
        for line in valueLines {
            textRenderer.drawText(
                context: context,
                text: line,
                at: CGPoint(x: margin + labelColumnWidth, y: valueBaseline),
                style: sectionBodyStyle
            )
            valueBaseline -= sectionBodyStyle.lineHeight
        }

        y -= rowHeight
    }
}
