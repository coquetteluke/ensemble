import Foundation

/// A colour as a program asked for it: the terminal's default, one of the 256 indexed colours (0 to 15 are the
/// themed ANSI colours), or a 24-bit colour.
public enum TerminalColor: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// How a cell's text is drawn (SGR state).
public struct TerminalAttributes: Hashable, Sendable {
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let bold = Flags(rawValue: 1 << 0)
        public static let dim = Flags(rawValue: 1 << 1)
        public static let italic = Flags(rawValue: 1 << 2)
        public static let underline = Flags(rawValue: 1 << 3)
        public static let blink = Flags(rawValue: 1 << 4)
        public static let inverse = Flags(rawValue: 1 << 5)
        public static let hidden = Flags(rawValue: 1 << 6)
        public static let strikethrough = Flags(rawValue: 1 << 7)
    }

    public var foreground: TerminalColor
    public var background: TerminalColor
    public var flags: Flags

    public init(foreground: TerminalColor = .default, background: TerminalColor = .default, flags: Flags = []) {
        self.foreground = foreground
        self.background = background
        self.flags = flags
    }

    public static let plain = TerminalAttributes()
}

/// One character cell. A wide character (CJK, most emoji) takes two cells: the first has `width` 2 and the
/// text, the second has `width` 0 and no text.
public struct TerminalCell: Hashable, Sendable {
    /// One grapheme cluster (a base character and any combining marks), a space for a blank cell, or empty for
    /// the second half of a wide character.
    public var text: String
    public var width: UInt8
    public var attributes: TerminalAttributes

    public init(text: String = " ", width: UInt8 = 1, attributes: TerminalAttributes = .plain) {
        self.text = text
        self.width = width
        self.attributes = attributes
    }

    public static let blank = TerminalCell()

    /// A blank cell that keeps a background colour (erasing uses the current background, as xterm does).
    static func blank(background: TerminalColor) -> TerminalCell {
        background == .default ? .blank : TerminalCell(attributes: TerminalAttributes(background: background))
    }

    var isPlainBlank: Bool { width == 1 && text == " " && attributes == .plain }
}

/// One row of cells. On screen a line has exactly as many cells as the terminal has columns; in the scrollback
/// trailing blank cells are dropped to save memory.
public struct TerminalLine: Hashable, Sendable {
    public var cells: [TerminalCell]
    /// The text ran on into the next line because it reached the right edge (a soft wrap). Copying joins such
    /// lines without a line break.
    public var wrapped: Bool

    public init(cells: [TerminalCell], wrapped: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
    }

    public init(columns: Int, background: TerminalColor = .default) {
        cells = Array(repeating: .blank(background: background), count: max(columns, 0))
        wrapped = false
    }

    /// The cell at `column`, blank past the stored cells.
    public func cell(at column: Int) -> TerminalCell {
        column >= 0 && column < cells.count ? cells[column] : .blank
    }

    /// The line's text with trailing spaces removed (the halves of wide characters count once).
    public var text: String {
        text(from: 0, to: cells.count)
    }

    /// Text of columns `start..<end`, trailing spaces removed.
    public func text(from start: Int, to end: Int) -> String {
        let lower = max(0, start)
        let upper = min(cells.count, end)
        guard lower < upper else { return "" }
        var result = ""
        for column in lower..<upper where cells[column].width != 0 {
            result += cells[column].text.isEmpty ? " " : cells[column].text
        }
        while result.last == " " { result.removeLast() }
        return result
    }

    /// The line without trailing plain blank cells, for the scrollback.
    func trimmed() -> TerminalLine {
        var end = cells.count
        while end > 0, cells[end - 1].isPlainBlank { end -= 1 }
        if end == cells.count { return self }
        return TerminalLine(cells: Array(cells[0..<end]), wrapped: wrapped)
    }

    /// Exactly `columns` cells: cut (never leaving half a wide character) or padded with blanks.
    func fitted(to columns: Int) -> TerminalLine {
        var copy = self
        if copy.cells.count > columns {
            copy.cells.removeSubrange(columns...)
            if columns > 0, copy.cells[columns - 1].width == 2 { copy.cells[columns - 1] = .blank }
        } else if copy.cells.count < columns {
            copy.cells.append(contentsOf: repeatElement(.blank, count: columns - copy.cells.count))
        }
        return copy
    }
}

/// A place in the terminal's text: `row` counts from the first line ever kept (see `TerminalEmulator.stableRow`),
/// so it stays on the same text while lines scroll into the scrollback.
public struct TerminalPosition: Hashable, Comparable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (a: TerminalPosition, b: TerminalPosition) -> Bool {
        a.row != b.row ? a.row < b.row : a.column < b.column
    }
}

/// The cursor shape a program asked for (DECSCUSR).
public enum TerminalCursorStyle: Sendable, Equatable {
    case block, underline, bar
}
