import CoreGraphics
import CoreText
import Foundation
import FyluroCore

struct PDFReceiptTextStyle {
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

struct PDFReceiptPalette {
    let pageBackground = pdfReceiptRGB(255, 255, 255)
    let cardBackground = pdfReceiptRGB(255, 255, 255)
    let heroBackground = pdfReceiptRGB(234, 242, 255)
    let heroStroke = pdfReceiptRGB(199, 215, 243)
    let border = pdfReceiptRGB(215, 221, 232)
    let divider = pdfReceiptRGB(226, 231, 239)
    let primaryText = pdfReceiptRGB(26, 31, 42)
    let secondaryText = pdfReceiptRGB(92, 101, 118)
    let accent = pdfReceiptRGB(10, 103, 225)
    let success = pdfReceiptRGB(26, 127, 55)
    let warning = pdfReceiptRGB(168, 111, 1)
    let danger = pdfReceiptRGB(184, 38, 33)
}

struct PDFReceiptTextRenderer {
    func drawText(
        context: CGContext,
        text: String,
        at point: CGPoint,
        style: PDFReceiptTextStyle
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

    func wrappedLines(for text: String, width: CGFloat, style: PDFReceiptTextStyle) -> [String] {
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

    func singleLineWidth(_ text: String, style: PDFReceiptTextStyle) -> CGFloat {
        textWidth(text, style: style)
    }

    private func hardWrap(_ text: String, width: CGFloat, style: PDFReceiptTextStyle) -> [String] {
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

    private func textWidth(_ text: String, style: PDFReceiptTextStyle) -> CGFloat {
        let font = font(size: style.fontSize, weight: style.weight)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return ceil(bounds.width)
    }

    private func font(size: CGFloat, weight: PDFReceiptTextStyle.Weight) -> CTFont {
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
}

struct PDFReceiptDrawingPrimitives {
    let textRenderer = PDFReceiptTextRenderer()

    func drawPageBackground(context: CGContext, pageRect: CGRect, color: CGColor) {
        context.saveGState()
        context.setFillColor(color)
        context.fill(pageRect)
        context.restoreGState()
    }

    func drawDivider(
        context: CGContext,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        color: CGColor
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(0.6)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
        context.restoreGState()
    }

    func drawFooter(
        context: CGContext,
        pageRect: CGRect,
        pageNumber: Int,
        sessionID: String,
        palette: PDFReceiptPalette
    ) {
        let footerMargin: CGFloat = 48
        drawDivider(
            context: context,
            x: footerMargin,
            y: 42,
            width: pageRect.width - (footerMargin * 2),
            color: palette.divider
        )
        textRenderer.drawText(
            context: context,
            text: "\(AppBrand.name) transfer receipt",
            at: CGPoint(x: footerMargin, y: 26),
            style: PDFReceiptTextStyle(fontSize: 9, lineHeight: 12, color: palette.secondaryText, weight: .regular)
        )
        // Right-align the text to the same margin as the divider. A fixed start offset
        // pushed the text off the page when the session ID is long (finding F1).
        let footerStyle = PDFReceiptTextStyle(fontSize: 9, lineHeight: 12, color: palette.secondaryText, weight: .regular)
        let rightText = "Session \(sessionID.prefix(8)) • Page \(pageNumber)"
        let rightWidth = textRenderer.singleLineWidth(rightText, style: footerStyle)
        textRenderer.drawText(
            context: context,
            text: rightText,
            at: CGPoint(x: pageRect.width - footerMargin - rightWidth, y: 26),
            style: footerStyle
        )
    }

    func drawRoundedRect(
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
}

/// A small table. The first column wraps long text. The other columns hold short values.
/// The composer owns the y-cursor and the page breaks. The table only measures and draws a row.
struct PDFReceiptTable {
    struct Column {
        let title: String
        let width: CGFloat
        let rightAligned: Bool
        let monospaced: Bool
        var color: CGColor? = nil
    }

    let columns: [Column]
    let bodyStyle: PDFReceiptTextStyle
    let monoStyle: PDFReceiptTextStyle
    let headerStyle: PDFReceiptTextStyle
    let rowPadding: CGFloat = 5
    let textRenderer = PDFReceiptTextRenderer()

    private func style(for column: Column, header: Bool) -> PDFReceiptTextStyle {
        if header { return headerStyle }
        let base = column.monospaced ? monoStyle : bodyStyle
        guard let color = column.color else { return base }
        return PDFReceiptTextStyle(fontSize: base.fontSize, lineHeight: base.lineHeight, color: color, weight: base.weight)
    }

    private func lines(for cells: [String], header: Bool) -> [[String]] {
        zip(columns, cells).map { column, cell in
            textRenderer.wrappedLines(for: cell, width: column.width - 8, style: style(for: column, header: header))
        }
    }

    func rowHeight(cells: [String], header: Bool = false) -> CGFloat {
        let longest = lines(for: cells, header: header).map(\.count).max() ?? 1
        return CGFloat(max(1, longest)) * bodyStyle.lineHeight + rowPadding
    }

    /// Draws one row. `baseline` is the baseline of the first line. Returns the row height.
    @discardableResult
    func drawRow(
        cells: [String],
        context: CGContext,
        x: CGFloat,
        baseline: CGFloat,
        header: Bool = false
    ) -> CGFloat {
        var columnX = x
        for (column, columnLines) in zip(columns, lines(for: cells, header: header)) {
            let columnStyle = style(for: column, header: header)
            for (index, line) in columnLines.enumerated() {
                let lineWidth = textRenderer.singleLineWidth(line, style: columnStyle)
                let textX = column.rightAligned ? columnX + column.width - 8 - lineWidth : columnX
                textRenderer.drawText(
                    context: context,
                    text: line,
                    at: CGPoint(x: textX, y: baseline - CGFloat(index) * bodyStyle.lineHeight),
                    style: columnStyle
                )
            }
            columnX += column.width
        }
        return rowHeight(cells: cells, header: header)
    }
}

func pdfReceiptRGB(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1.0) -> CGColor {
    CGColor(
        red: red / 255.0,
        green: green / 255.0,
        blue: blue / 255.0,
        alpha: alpha
    )
}
