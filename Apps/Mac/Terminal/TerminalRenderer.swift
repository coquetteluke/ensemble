import AppKit
import CoreText
import SwiftUI
import EnsembleKit

/// The terminal's colours for one appearance: the theme's text and background, a cursor, a selection, and the
/// 16 ANSI colours tuned to sit with Ensemble's palette. The other 240 indexed colours are xterm's.
struct TerminalPalette: Equatable {
    var foreground: CGColor
    var background: CGColor
    var cursor: CGColor
    var cursorText: CGColor
    var selection: CGColor
    /// All 256 indexed colours.
    var indexed: [CGColor]

    init(theme: Theme) {
        func cg(_ color: Color) -> CGColor { color.resolve(in: EnvironmentValues()).cgColor }
        func hex(_ value: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        foreground = cg(theme.textPrimary)
        background = cg(theme.codeBackground)
        cursor = cg(theme.textPrimary)
        cursorText = cg(theme.codeBackground)
        selection = cg(theme.accent.opacity(theme.isDark ? 0.38 : 0.24))
        let ansi: [UInt32] = theme.isDark
            ? [0x2E2D2B, 0xF0524F, 0x3FB950, 0xD99F38, 0x58A6FF, 0xC79BFF, 0x39C5CF, 0xC9C9C7,
               0x6E6E6E, 0xFF7B72, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF3F3F3]
            : [0x1D1D1B, 0xCF222E, 0x1A7F37, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E6C69,
               0x57554F, 0xA40E26, 0x116329, 0x7D4E00, 0x0550AE, 0x6639BA, 0x0E6B73, 0x8C8A86]
        var colours = ansi.map(hex)
        let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
        for red in levels { for green in levels { for blue in levels { colours.append(hex(red << 16 | green << 8 | blue)) } } }
        for step in 0..<24 {
            let grey = UInt32(8 + step * 10)
            colours.append(hex(grey << 16 | grey << 8 | grey))
        }
        indexed = colours
    }

    func color(_ color: TerminalColor, foreground isForeground: Bool) -> CGColor {
        switch color {
        case .default:
            return isForeground ? foreground : background
        case .indexed(let index):
            return indexed[Int(index)]
        case .rgb(let red, let green, let blue):
            return CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }
}

/// SF Mono at the terminal's size, and the cell grid it makes.
struct TerminalMetrics: Equatable {
    let size: CGFloat
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    /// Distance from the top of a line to the baseline.
    let baseline: CGFloat
    /// Height of the font's glyph box (ascent plus descent).
    let glyphHeight: CGFloat
    /// Space around the grid.
    let padding: CGSize

    init(size: CGFloat) {
        self.size = size
        let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold) as CTFont
        self.regular = regular
        self.bold = bold
        italic = CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .traitItalic, .traitItalic) ?? regular
        boldItalic = CTFontCreateCopyWithSymbolicTraits(bold, size, nil, .traitItalic, .traitItalic) ?? bold
        var glyph = CGGlyph(0)
        var character = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(regular, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        cellWidth = advance.width
        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        glyphHeight = ascent + descent
        lineHeight = ceil(glyphHeight * 1.18)
        baseline = ((lineHeight - glyphHeight) / 2 + ascent).rounded()
        padding = CGSize(width: (size * 0.85).rounded(), height: (size * 0.5).rounded())
    }

    func font(for flags: TerminalAttributes.Flags) -> CTFont {
        switch (flags.contains(.bold), flags.contains(.italic)) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }

    /// Columns and rows that fit in `size`.
    func grid(for size: CGSize) -> (columns: Int, rows: Int) {
        let columns = Int((size.width - padding.width * 2) / cellWidth)
        let rows = Int((size.height - padding.height * 2) / lineHeight)
        return (max(columns, 2), max(rows, 2))
    }
}

/// Where and how to draw the cursor.
struct TerminalCursorDrawing {
    var documentRow: Int
    var column: Int
    var style: TerminalCursorStyle
    var focused: Bool
    /// Text being composed with an input method, drawn at the cursor.
    var markedText: String = ""
}

/// Draws terminal lines with Core Graphics and Core Text into a flipped context (y grows downwards): backgrounds,
/// text in runs, underline and strikethrough, the selection and the cursor. The live view and the snapshots share it.
enum TerminalRenderer {
    /// Draws document lines `range` (see `TerminalEmulator.documentLine`); `lineTop(index)` gives each line's top edge.
    static func drawLines(_ context: CGContext, emulator: TerminalEmulator, range: ClosedRange<Int>, lineTop: (Int) -> CGFloat,
                          metrics: TerminalMetrics, palette: TerminalPalette, selection: ClosedRange<TerminalPosition>?,
                          cursor: TerminalCursorDrawing?) {
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let firstStable = emulator.firstStableRow
        for index in range {
            let line = emulator.documentLine(index)
            let stable = firstStable + index
            var selectedColumns: Range<Int>?
            if let selection, stable >= selection.lowerBound.row, stable <= selection.upperBound.row {
                let start = stable == selection.lowerBound.row ? selection.lowerBound.column : 0
                let end = stable == selection.upperBound.row ? selection.upperBound.column + 1 : emulator.columns
                if start < end { selectedColumns = start..<end }
            }
            let lineCursor = cursor.flatMap { $0.documentRow == index ? $0 : nil }
            drawLine(context, line: line, columns: emulator.columns, top: lineTop(index), metrics: metrics, palette: palette,
                     selected: selectedColumns, cursor: lineCursor)
        }
    }

    private struct CellColors {
        var foreground: CGColor
        var background: CGColor
    }

    private static func colors(_ cell: TerminalCell, palette: TerminalPalette, selected: Bool) -> CellColors {
        let attributes = cell.attributes
        var foreground = palette.color(attributes.foreground, foreground: true)
        var background = palette.color(attributes.background, foreground: false)
        if attributes.flags.contains(.inverse) { swap(&foreground, &background) }
        if attributes.flags.contains(.dim) { foreground = foreground.copy(alpha: foreground.alpha * 0.55) ?? foreground }
        if selected { background = palette.selection }
        if attributes.flags.contains(.hidden) { foreground = background }
        return CellColors(foreground: foreground, background: background)
    }

    private static func drawLine(_ context: CGContext, line: TerminalLine, columns: Int, top: CGFloat, metrics: TerminalMetrics,
                                 palette: TerminalPalette, selected: Range<Int>?, cursor: TerminalCursorDrawing?) {
        let left = metrics.padding.width
        let width = metrics.cellWidth
        let height = metrics.lineHeight

        // Backgrounds, in runs of one colour.
        var column = 0
        while column < columns {
            let start = column
            let background = colors(line.cell(at: column), palette: palette, selected: selected?.contains(column) == true).background
            column += 1
            while column < columns,
                  colors(line.cell(at: column), palette: palette, selected: selected?.contains(column) == true).background == background {
                column += 1
            }
            if background != palette.background {
                context.setFillColor(background)
                context.fill(CGRect(x: left + CGFloat(start) * width, y: top, width: CGFloat(column - start) * width, height: height))
            }
        }

        // Text: runs of plain ASCII in one style go together; anything else is drawn in its own cell.
        var run = ""
        var runStart = 0
        var runFont = metrics.regular
        var runColor = palette.foreground
        var runFlags = TerminalAttributes.Flags()
        func flush() {
            guard !run.isEmpty else { return }
            drawText(context, run, x: left + CGFloat(runStart) * width, top: top, font: runFont, color: runColor, metrics: metrics)
            decorate(context, flags: runFlags, x: left + CGFloat(runStart) * width, width: CGFloat(run.count) * width,
                     top: top, color: runColor, metrics: metrics)
            run = ""
        }
        for column in 0..<min(columns, line.cells.count) {
            let cell = line.cells[column]
            if cell.width == 0 { continue }
            let isCursorCell = cursor.map { $0.column == column && $0.focused && $0.style == .block && $0.markedText.isEmpty } ?? false
            if isCursorCell { flush(); continue }
            let cellColors = colors(cell, palette: palette, selected: selected?.contains(column) == true)
            let flags = cell.attributes.flags.intersection([.bold, .italic, .underline, .strikethrough])
            let font = metrics.font(for: flags)
            let scalar = cell.text.unicodeScalars.first
            let simple = cell.width == 1 && cell.text.unicodeScalars.count == 1 && (scalar?.isASCII ?? false)
            if simple {
                if !run.isEmpty, font != runFont || cellColors.foreground != runColor || flags != runFlags || runStart + run.count != column {
                    flush()
                }
                if run.isEmpty {
                    runStart = column
                    runFont = font
                    runColor = cellColors.foreground
                    runFlags = flags
                }
                run.append(cell.text)
            } else {
                flush()
                let x = left + CGFloat(column) * width
                let cellWidth = CGFloat(cell.width) * width
                if let scalar, (0x2500...0x259F).contains(scalar.value) {
                    drawStretched(context, cell.text, x: x, top: top, font: font, color: cellColors.foreground, metrics: metrics)
                } else {
                    drawText(context, cell.text, x: x, top: top, font: font, color: cellColors.foreground, metrics: metrics)
                }
                decorate(context, flags: flags, x: x, width: cellWidth, top: top, color: cellColors.foreground, metrics: metrics)
            }
        }
        flush()

        if let cursor { drawCursor(context, cursor: cursor, line: line, top: top, metrics: metrics, palette: palette) }
    }

    private static func drawText(_ context: CGContext, _ text: String, x: CGFloat, top: CGFloat, font: CTFont, color: CGColor,
                                 metrics: TerminalMetrics) {
        guard text.contains(where: { $0 != " " }) else { return }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: x, y: top + metrics.baseline)
        CTLineDraw(line, context)
    }

    /// Box-drawing and block characters stretched to the full line height, so lines in `top`, `vim` and other
    /// full-screen programs join up between rows.
    private static func drawStretched(_ context: CGContext, _ text: String, x: CGFloat, top: CGFloat, font: CTFont, color: CGColor,
                                      metrics: TerminalMetrics) {
        let scale = metrics.lineHeight / metrics.glyphHeight
        let glyphTop = metrics.baseline - CTFontGetAscent(font)
        context.saveGState()
        // Map the glyph box (glyphTop ... glyphTop + glyphHeight) onto the whole line.
        context.translateBy(x: 0, y: top)
        context.scaleBy(x: 1, y: scale)
        context.translateBy(x: 0, y: -glyphTop)
        drawText(context, text, x: x, top: 0, font: font, color: color, metrics: metrics)
        context.restoreGState()
    }

    private static func decorate(_ context: CGContext, flags: TerminalAttributes.Flags, x: CGFloat, width: CGFloat, top: CGFloat,
                                 color: CGColor, metrics: TerminalMetrics) {
        let thickness = max(1, (metrics.size / 12).rounded())
        context.setFillColor(color)
        if flags.contains(.underline) {
            context.fill(CGRect(x: x, y: top + metrics.baseline + thickness * 1.5, width: width, height: thickness))
        }
        if flags.contains(.strikethrough) {
            context.fill(CGRect(x: x, y: top + metrics.baseline - metrics.glyphHeight * 0.28, width: width, height: thickness))
        }
    }

    private static func drawCursor(_ context: CGContext, cursor: TerminalCursorDrawing, line: TerminalLine, top: CGFloat,
                                   metrics: TerminalMetrics, palette: TerminalPalette) {
        let x = metrics.padding.width + CGFloat(cursor.column) * metrics.cellWidth
        let cell = line.cell(at: cursor.column)
        let cellWidth = CGFloat(max(cell.width, 1)) * metrics.cellWidth
        let rect = CGRect(x: x, y: top, width: cellWidth, height: metrics.lineHeight)
        if !cursor.markedText.isEmpty {
            // Text being composed (an input method or a dead key), underlined at the cursor.
            let composedWidth = CGFloat(cursor.markedText.unicodeScalars.reduce(0) { $0 + max(TerminalCharacterWidth.of($1), 0) })
                * metrics.cellWidth
            context.setFillColor(palette.background)
            context.fill(CGRect(x: x, y: top, width: max(composedWidth, metrics.cellWidth), height: metrics.lineHeight))
            drawText(context, cursor.markedText, x: x, top: top, font: metrics.regular, color: palette.foreground, metrics: metrics)
            context.setFillColor(palette.foreground)
            context.fill(CGRect(x: x, y: top + metrics.baseline + 2, width: max(composedWidth, metrics.cellWidth), height: 1))
            return
        }
        guard cursor.focused else {
            context.setStrokeColor(palette.cursor)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            return
        }
        switch cursor.style {
        case .block:
            context.setFillColor(palette.cursor)
            context.fill(rect)
            let font = metrics.font(for: cell.attributes.flags.intersection([.bold, .italic]))
            drawText(context, cell.text, x: x, top: top, font: font, color: palette.cursorText, metrics: metrics)
        case .bar:
            context.setFillColor(palette.cursor)
            context.fill(CGRect(x: x, y: top, width: max(2, metrics.size / 6), height: metrics.lineHeight))
        case .underline:
            context.setFillColor(palette.cursor)
            context.fill(CGRect(x: x, y: top + metrics.lineHeight - 2, width: cellWidth, height: 2))
        }
    }

    /// The screen (the last `rows` lines) drawn into an image of `size` points at `scale`, for snapshots.
    static func screenImage(emulator: TerminalEmulator, size: CGSize, scale: CGFloat, metrics: TerminalMetrics,
                            palette: TerminalPalette, cursorFocused: Bool, showsCursor: Bool = true) -> CGImage? {
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(palette.background)
        context.fill(CGRect(origin: .zero, size: size))
        let count = emulator.documentLineCount
        let first = max(0, count - emulator.rows)
        let cursor = showsCursor && emulator.cursorVisible
            ? TerminalCursorDrawing(documentRow: emulator.cursorDocumentRow, column: emulator.cursorColumn, style: emulator.cursorStyle,
                                    focused: cursorFocused)
            : nil
        drawLines(context, emulator: emulator, range: first...(count - 1),
                  lineTop: { metrics.padding.height + CGFloat($0 - first) * metrics.lineHeight },
                  metrics: metrics, palette: palette, selection: nil, cursor: cursor)
        return context.makeImage()
    }
}
