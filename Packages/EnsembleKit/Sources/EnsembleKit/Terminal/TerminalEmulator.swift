import Foundation

/// The screen of a terminal and what programs write to it: an xterm-compatible model (`TERM=xterm-256color`)
/// with the main screen and its scrollback, the alternate screen full-screen programs use, scroll regions,
/// SGR colours and styles, wide characters, and the replies programs ask for (cursor position, device
/// attributes). It never touches a process; `feed` it bytes and read the screen.
///
/// Not thread-safe: use one emulator from one place (the app keeps each on the main actor).
public final class TerminalEmulator {
    public static let defaultScrollbackLimit = 10_000

    public private(set) var columns: Int
    public private(set) var rows: Int
    /// The screen on view: the main screen, or the alternate screen while a full-screen program runs.
    public private(set) var screen: [TerminalLine]
    /// The screen not on view.
    private var otherScreen: [TerminalLine]
    public private(set) var isAlternateScreen = false
    /// Lines that scrolled off the main screen. The alternate screen has none.
    public private(set) var scrollback: TerminalScrollback

    public private(set) var cursorRow = 0
    public private(set) var cursorColumn = 0
    /// A character was written in the last column: the next one goes on the next line (xterm's deferred wrap).
    private var pendingWrap = false
    public private(set) var cursorVisible = true
    public private(set) var cursorStyle = TerminalCursorStyle.block
    private var pen = TerminalAttributes.plain

    private var scrollTop = 0
    /// Last line of the scroll region (inclusive).
    private var scrollBottom: Int
    private var tabStops: [Bool]

    // Modes programs switch.
    /// Arrow keys send `ESC O A` instead of `ESC [ A` (DECCKM, set by `less`, `vim`, `top`).
    public private(set) var applicationCursorKeys = false
    public private(set) var applicationKeypad = false
    /// Pasted text is wrapped in `ESC [ 200 ~` and `ESC [ 201 ~` (set by the shell's line editor).
    public private(set) var bracketedPaste = false
    public private(set) var autowrap = true
    public private(set) var reverseVideo = false
    public private(set) var mouseTracking = TerminalMouseTracking.off
    /// Mouse reports use the SGR form (`ESC [ < b ; x ; y M`).
    public private(set) var mouseSGR = false
    private var originMode = false
    private var insertMode = false
    private var newLineMode = false

    private enum Charset: Sendable { case ascii, decSpecialGraphics }
    private var charsets: [Charset] = [.ascii, .ascii]
    private var activeCharset = 0

    private struct SavedCursor {
        var row: Int
        var column: Int
        var pen: TerminalAttributes
        var pendingWrap: Bool
        var originMode: Bool
        var charsets: [Charset]
        var activeCharset: Int
    }
    private var savedMain: SavedCursor?
    private var savedAlternate: SavedCursor?

    /// The window title a program set (OSC 0 or 2).
    public private(set) var title = ""
    /// The folder the shell reported with OSC 7 (`file://host/path`), if it does.
    public private(set) var reportedDirectory: String?
    public private(set) var bellCount = 0
    /// Goes up whenever anything on screen may have changed.
    public private(set) var changeCount = 0
    private var lastGraphic: Unicode.Scalar?
    private var responses: [UInt8] = []
    private var parser = TerminalParser()

    public init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = TerminalEmulator.defaultScrollbackLimit) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        self.columns = columns
        self.rows = rows
        screen = Array(repeating: TerminalLine(columns: columns), count: rows)
        otherScreen = Array(repeating: TerminalLine(columns: columns), count: rows)
        scrollback = TerminalScrollback(capacity: scrollbackLimit)
        scrollBottom = rows - 1
        tabStops = Self.defaultTabStops(columns)
    }

    // MARK: Input

    public func feed<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        parser.feed(bytes) { action in perform(action) }
        changeCount &+= 1
    }

    public func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    /// Replies the programs asked for (cursor position, device attributes), to write back to the process.
    public func takeResponses() -> [UInt8] {
        defer { responses.removeAll() }
        return responses
    }

    // MARK: Reading the text

    /// Lines on view from the top of the scrollback: the scrollback and the main screen, or just the
    /// alternate screen.
    public var documentLineCount: Int { isAlternateScreen ? rows : scrollback.count + rows }

    /// Line `index` of `documentLineCount`.
    public func documentLine(_ index: Int) -> TerminalLine {
        if isAlternateScreen { return screen[index] }
        return index < scrollback.count ? scrollback[index] : screen[index - scrollback.count]
    }

    /// The cursor's line in `documentLine` terms.
    public var cursorDocumentRow: Int { (isAlternateScreen ? 0 : scrollback.count) + cursorRow }

    /// Stable row of `documentLine(0)`. Stable rows count from the first line ever kept, so a selection stays on
    /// its text while lines scroll into the scrollback and old ones drop off.
    public var firstStableRow: Int { isAlternateScreen ? 0 : scrollback.droppedCount }

    public func line(atStableRow row: Int) -> TerminalLine? {
        let index = row - firstStableRow
        guard index >= 0, index < documentLineCount else { return nil }
        return documentLine(index)
    }

    /// The screen's text, one line per row, trailing spaces removed.
    public var screenText: String {
        screen.map(\.text).joined(separator: "\n")
    }

    /// Text from `start` to `end` (both cells included, either order), in stable rows. Soft-wrapped lines are
    /// joined without a line break.
    public func text(from start: TerminalPosition, to end: TerminalPosition) -> String {
        let (first, last) = start <= end ? (start, end) : (end, start)
        var result = ""
        for row in first.row...last.row {
            guard let line = line(atStableRow: row) else { continue }
            let from = row == first.row ? first.column : 0
            var to = row == last.row ? last.column + 1 : max(columns, line.cells.count)
            // A selection ending on the first half of a wide character takes the whole character.
            if row == last.row, last.column < line.cells.count, line.cells[last.column].width == 2 { to += 1 }
            let joinsNext = line.wrapped && row != last.row
            result += joinsNext ? line.text(from: from, to: to, trimming: false) : line.text(from: from, to: to)
            if row != last.row && !line.wrapped { result += "\n" }
        }
        return result
    }

    /// The word around `position` (for double-click): letters, digits and the characters of paths and URLs.
    public func wordRange(at position: TerminalPosition) -> (start: TerminalPosition, end: TerminalPosition) {
        guard let line = line(atStableRow: position.row), position.column < line.cells.count else {
            return (position, position)
        }
        func isWord(_ column: Int) -> Bool {
            let cell = line.cell(at: column)
            if cell.width == 0 { return column > 0 && isWord(column - 1) }
            guard let scalar = cell.text.unicodeScalars.first else { return false }
            if CharacterSet.whitespaces.contains(scalar) { return false }
            return !"\"'`()[]{}<>|;,".unicodeScalars.contains(scalar)
        }
        guard isWord(position.column) else { return (position, position) }
        var start = position.column
        var end = position.column
        while start > 0, isWord(start - 1) { start -= 1 }
        while end + 1 < line.cells.count, isWord(end + 1) { end += 1 }
        return (TerminalPosition(row: position.row, column: start), TerminalPosition(row: position.row, column: end))
    }

    // MARK: Size and history

    /// Changes the size. The main screen keeps its text: when it gets shorter the top lines go into the
    /// scrollback (blank lines below the cursor go first), when it gets taller they come back. Lines are cut or
    /// padded to the new width, not re-wrapped.
    public func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(newColumns, 1)
        let newRows = max(newRows, 1)
        guard newColumns != columns || newRows != rows else { return }

        var main = isAlternateScreen ? otherScreen : screen
        var alternate = isAlternateScreen ? screen : otherScreen
        var mainCursorRow = isAlternateScreen ? (savedMain?.row ?? cursorRow) : cursorRow

        // Main screen rows.
        if newRows < rows {
            var excess = rows - newRows
            // Blank lines below the cursor go first.
            while excess > 0, main.count - 1 > mainCursorRow, main.last.map(isBlank) == true {
                main.removeLast()
                excess -= 1
            }
            while excess > 0 {
                scrollback.append(main.removeFirst().trimmed())
                mainCursorRow -= 1
                excess -= 1
            }
            if main.count > newRows { main.removeLast(main.count - newRows) }
        } else if newRows > rows {
            var missing = newRows - rows
            while missing > 0, let line = scrollback.removeLast() {
                main.insert(line, at: 0)
                mainCursorRow += 1
                missing -= 1
            }
            main.append(contentsOf: repeatElement(TerminalLine(columns: newColumns), count: missing))
        }
        main = main.map { $0.fitted(to: newColumns) }

        // Alternate screen: programs redraw it after a resize.
        if alternate.count > newRows {
            alternate.removeLast(alternate.count - newRows)
        } else {
            alternate.append(contentsOf: repeatElement(TerminalLine(columns: newColumns), count: newRows - alternate.count))
        }
        alternate = alternate.map { $0.fitted(to: newColumns) }

        columns = newColumns
        rows = newRows
        if isAlternateScreen {
            screen = alternate
            otherScreen = main
            savedMain?.row = min(max(mainCursorRow, 0), newRows - 1)
        } else {
            screen = main
            otherScreen = alternate
            cursorRow = mainCursorRow
        }
        cursorRow = min(max(cursorRow, 0), newRows - 1)
        cursorColumn = min(cursorColumn, newColumns - 1)
        pendingWrap = false
        scrollTop = 0
        scrollBottom = newRows - 1
        let oldStops = tabStops
        tabStops = Self.defaultTabStops(newColumns)
        for column in 0..<min(oldStops.count, newColumns) { tabStops[column] = oldStops[column] }
        if var saved = savedAlternate {
            saved.row = min(saved.row, newRows - 1)
            saved.column = min(saved.column, newColumns - 1)
            savedAlternate = saved
        }
        if var saved = savedMain {
            saved.row = min(saved.row, newRows - 1)
            saved.column = min(saved.column, newColumns - 1)
            savedMain = saved
        }
        changeCount &+= 1
    }

    /// Empties the scrollback (the screen stays).
    public func clearScrollback() {
        scrollback.removeAll()
        changeCount &+= 1
    }

    // MARK: Dispatch

    private func perform(_ action: TerminalAction) {
        switch action {
        case .print(let scalar): printScalar(scalar)
        case .execute(let byte): execute(byte)
        case .csi(let csi): controlSequence(csi)
        case .escape(let intermediates, let final): escape(intermediates: intermediates, final: final)
        case .osc(let text): operatingSystemCommand(text)
        }
    }

    // MARK: Characters

    private func printScalar(_ input: Unicode.Scalar) {
        var scalar = input
        if charsets[activeCharset] == .decSpecialGraphics, let mapped = Self.decSpecialGraphics[input.value] {
            scalar = mapped
        }
        var width = TerminalCharacterWidth.of(scalar)
        if width == 0 {
            appendCombining(scalar)
            return
        }
        if width == 2 && columns < 2 { width = 1 }
        if pendingWrap {
            pendingWrap = false
            if autowrap { wrapToNextLine() }
        }
        if width == 2 && cursorColumn == columns - 1 {
            guard autowrap else { return }
            clearWideOverlap(column: cursorColumn, width: 1)
            screen[cursorRow].cells[cursorColumn] = .blank(background: pen.background)
            wrapToNextLine()
        }
        if insertMode { insertBlanks(width) }
        clearWideOverlap(column: cursorColumn, width: width)
        let text = scalar.value < 0x80 ? Self.asciiText[Int(scalar.value)] : String(Character(scalar))
        screen[cursorRow].cells[cursorColumn] = TerminalCell(text: text, width: UInt8(width), attributes: pen)
        if width == 2 {
            screen[cursorRow].cells[cursorColumn + 1] = TerminalCell(text: "", width: 0, attributes: pen)
        }
        lastGraphic = scalar
        cursorColumn += width
        if cursorColumn >= columns {
            cursorColumn = columns - 1
            pendingWrap = autowrap
        }
    }

    /// A combining mark or other zero-width character joins the character before the cursor.
    private func appendCombining(_ scalar: Unicode.Scalar) {
        var column = pendingWrap ? cursorColumn : cursorColumn - 1
        guard column >= 0 else { return }
        if screen[cursorRow].cells[column].width == 0, column > 0 { column -= 1 }
        let text = screen[cursorRow].cells[column].text
        guard !text.isEmpty, text != " " || scalar.properties.generalCategory == .nonspacingMark else { return }
        let combined = text + String(Character(scalar))
        if combined.count == 1 { screen[cursorRow].cells[column].text = combined }
    }

    private func wrapToNextLine() {
        screen[cursorRow].wrapped = true
        cursorColumn = 0
        index()
    }

    /// Before cells `column..<column+width` are overwritten: blanks the other half of any wide character cut in two.
    private func clearWideOverlap(column: Int, width: Int) {
        let row = cursorRow
        guard column < columns else { return }
        if screen[row].cells[column].width == 0, column > 0 {
            screen[row].cells[column - 1] = .blank(background: screen[row].cells[column - 1].attributes.background)
        }
        let last = min(column + width - 1, columns - 1)
        if screen[row].cells[last].width == 2, last + 1 < columns {
            screen[row].cells[last + 1] = .blank(background: screen[row].cells[last + 1].attributes.background)
        }
    }

    // MARK: C0 controls

    private func execute(_ byte: UInt8) {
        switch byte {
        case 0x07:
            bellCount &+= 1
        case 0x08:
            pendingWrap = false
            if cursorColumn > 0 { cursorColumn -= 1 }
        case 0x09:
            tab(forward: 1)
        case 0x0A, 0x0B, 0x0C:
            pendingWrap = false
            index()
            if newLineMode { cursorColumn = 0 }
        case 0x0D:
            pendingWrap = false
            cursorColumn = 0
        case 0x0E:
            activeCharset = 1
        case 0x0F:
            activeCharset = 0
        default:
            break
        }
    }

    /// Line feed: down a line, scrolling the region when at its bottom.
    private func index() {
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func tab(forward count: Int) {
        pendingWrap = false
        var remaining = count
        while remaining > 0, cursorColumn < columns - 1 {
            cursorColumn += 1
            if tabStops[cursorColumn] { remaining -= 1 }
        }
    }

    private func tab(backward count: Int) {
        pendingWrap = false
        var remaining = count
        while remaining > 0, cursorColumn > 0 {
            cursorColumn -= 1
            if tabStops[cursorColumn] { remaining -= 1 }
        }
    }

    // MARK: Scrolling and editing

    private func blankLine() -> TerminalLine { TerminalLine(columns: columns, background: pen.background) }

    private func scrollUp(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            let line = screen.remove(at: scrollTop)
            if scrollTop == 0 && !isAlternateScreen { scrollback.append(line.trimmed()) }
            screen.insert(blankLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine(), at: scrollTop)
        }
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine(), at: cursorRow)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<count {
            screen.remove(at: cursorRow)
            screen.insert(blankLine(), at: scrollBottom)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    /// Inserts blanks at the cursor, pushing the rest of the line right (ICH and insert mode).
    private func insertBlanks(_ count: Int) {
        let column = cursorColumn
        let count = min(count, columns - column)
        guard count > 0 else { return }
        var cells = screen[cursorRow].cells
        if cells[column].width == 0, column > 0 {
            cells[column - 1] = .blank
            cells[column] = .blank
        }
        cells.insert(contentsOf: repeatElement(TerminalCell.blank(background: pen.background), count: count), at: column)
        cells.removeLast(count)
        if cells[columns - 1].width == 2 { cells[columns - 1] = .blank }
        screen[cursorRow].cells = cells
    }

    private func deleteCharacters(_ count: Int) {
        let column = cursorColumn
        let count = min(count, columns - column)
        guard count > 0 else { return }
        var cells = screen[cursorRow].cells
        if cells[column].width == 0, column > 0 {
            cells[column - 1] = .blank
            cells[column] = .blank
        }
        cells.removeSubrange(column..<(column + count))
        cells.append(contentsOf: repeatElement(TerminalCell.blank(background: pen.background), count: count))
        if cells[column].width == 0 { cells[column] = .blank }
        screen[cursorRow].cells = cells
        pendingWrap = false
    }

    /// Blanks columns `start..<end` of the cursor's line (or `row`), mending wide characters cut at either end.
    private func erase(row: Int, from start: Int, to end: Int) {
        let start = max(0, start)
        let end = min(columns, end)
        guard start < end else { return }
        let blank = TerminalCell.blank(background: pen.background)
        if screen[row].cells[start].width == 0, start > 0 { screen[row].cells[start - 1] = blank }
        if end < columns, screen[row].cells[end].width == 0 { screen[row].cells[end] = blank }
        for column in start..<end { screen[row].cells[column] = blank }
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            erase(row: cursorRow, from: cursorColumn, to: columns)
            screen[cursorRow].wrapped = false
        case 1:
            erase(row: cursorRow, from: 0, to: cursorColumn + 1)
        case 2:
            erase(row: cursorRow, from: 0, to: columns)
            screen[cursorRow].wrapped = false
        default:
            break
        }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<rows { screen[row] = blankLine() }
        case 1:
            for row in 0..<cursorRow { screen[row] = blankLine() }
            eraseInLine(1)
        case 2:
            for row in 0..<rows { screen[row] = blankLine() }
        case 3:
            if !isAlternateScreen { scrollback.removeAll() }
        default:
            break
        }
    }

    // MARK: Cursor

    /// Top and bottom rows the cursor may move between: the scroll region in origin mode or when inside it.
    private var verticalLimits: (top: Int, bottom: Int) {
        if originMode { return (scrollTop, scrollBottom) }
        let top = cursorRow >= scrollTop ? scrollTop : 0
        let bottom = cursorRow <= scrollBottom ? scrollBottom : rows - 1
        return (top, bottom)
    }

    private func moveCursor(row: Int? = nil, column: Int? = nil) {
        pendingWrap = false
        if let row {
            let top = originMode ? scrollTop : 0
            let bottom = originMode ? scrollBottom : rows - 1
            cursorRow = min(max(row + top, top), bottom)
        }
        if let column { cursorColumn = min(max(column, 0), columns - 1) }
    }

    private func saveCursor() {
        let saved = SavedCursor(row: cursorRow, column: cursorColumn, pen: pen, pendingWrap: pendingWrap, originMode: originMode,
                                charsets: charsets, activeCharset: activeCharset)
        if isAlternateScreen { savedAlternate = saved } else { savedMain = saved }
    }

    private func restoreCursor() {
        guard let saved = isAlternateScreen ? savedAlternate : savedMain else {
            cursorRow = 0
            cursorColumn = 0
            pen = .plain
            originMode = false
            pendingWrap = false
            return
        }
        cursorRow = min(saved.row, rows - 1)
        cursorColumn = min(saved.column, columns - 1)
        pen = saved.pen
        pendingWrap = saved.pendingWrap && cursorColumn == columns - 1
        originMode = saved.originMode
        charsets = saved.charsets
        activeCharset = saved.activeCharset
    }

    // MARK: Screens

    private func switchToAlternate(clear: Bool) {
        guard !isAlternateScreen else {
            if clear { clearScreen() }
            return
        }
        swap(&screen, &otherScreen)
        isAlternateScreen = true
        if clear { clearScreen() }
    }

    private func switchToMain(clearAlternate: Bool) {
        guard isAlternateScreen else { return }
        if clearAlternate { clearScreen() }
        swap(&screen, &otherScreen)
        isAlternateScreen = false
    }

    private func clearScreen() {
        screen = Array(repeating: TerminalLine(columns: columns), count: rows)
    }

    private func softReset() {
        cursorVisible = true
        autowrap = true
        originMode = false
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        scrollTop = 0
        scrollBottom = rows - 1
        pen = .plain
        charsets = [.ascii, .ascii]
        activeCharset = 0
        savedMain = nil
        savedAlternate = nil
        pendingWrap = false
        cursorStyle = .block
    }

    private func fullReset() {
        switchToMain(clearAlternate: true)
        softReset()
        bracketedPaste = false
        mouseTracking = .off
        mouseSGR = false
        reverseVideo = false
        newLineMode = false
        tabStops = Self.defaultTabStops(columns)
        clearScreen()
        cursorRow = 0
        cursorColumn = 0
        title = ""
    }

    // MARK: Escape sequences

    private func escape(intermediates: [UInt8], final: UInt8) {
        if let first = intermediates.first {
            switch first {
            case UInt8(ascii: "("), UInt8(ascii: ")"):
                let slot = first == UInt8(ascii: "(") ? 0 : 1
                charsets[slot] = final == UInt8(ascii: "0") ? .decSpecialGraphics : .ascii
            case UInt8(ascii: "#") where final == UInt8(ascii: "8"):
                // DECALN: fills the screen with E (alignment test).
                let filled = TerminalLine(cells: Array(repeating: TerminalCell(text: "E"), count: columns))
                screen = Array(repeating: filled, count: rows)
                moveCursor(row: 0, column: 0)
            default:
                break
            }
            return
        }
        switch final {
        case UInt8(ascii: "7"): saveCursor()
        case UInt8(ascii: "8"): restoreCursor()
        case UInt8(ascii: "D"):
            pendingWrap = false
            index()
        case UInt8(ascii: "E"):
            pendingWrap = false
            index()
            cursorColumn = 0
        case UInt8(ascii: "M"):
            pendingWrap = false
            reverseIndex()
        case UInt8(ascii: "H"): tabStops[cursorColumn] = true
        case UInt8(ascii: "c"): fullReset()
        case UInt8(ascii: "="): applicationKeypad = true
        case UInt8(ascii: ">"): applicationKeypad = false
        default: break
        }
    }

    // MARK: Control sequences

    private func controlSequence(_ csi: TerminalCSI) {
        let marker = csi.privateMarker
        let intermediate = csi.intermediates.first
        if let intermediate {
            switch (intermediate, csi.final) {
            case (UInt8(ascii: " "), UInt8(ascii: "q")):
                switch csi.parameter(0, default: 0, zeroIsDefault: false) {
                case 3, 4: cursorStyle = .underline
                case 5, 6: cursorStyle = .bar
                default: cursorStyle = .block
                }
            case (UInt8(ascii: "!"), UInt8(ascii: "p")):
                softReset()
            default:
                break
            }
            return
        }
        let n = csi.parameter(0, default: 1)
        switch csi.final {
        case UInt8(ascii: "@") where marker == nil:
            insertBlanks(n)
        case UInt8(ascii: "A"):
            moveCursorVertically(-n)
        case UInt8(ascii: "B"), UInt8(ascii: "e"):
            moveCursorVertically(n)
        case UInt8(ascii: "C"), UInt8(ascii: "a"):
            moveCursor(column: cursorColumn + n)
        case UInt8(ascii: "D"):
            moveCursor(column: cursorColumn - n)
        case UInt8(ascii: "E"):
            moveCursorVertically(n)
            cursorColumn = 0
        case UInt8(ascii: "F"):
            moveCursorVertically(-n)
            cursorColumn = 0
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            moveCursor(column: n - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            moveCursor(row: csi.parameter(0, default: 1) - 1, column: csi.parameter(1, default: 1) - 1)
        case UInt8(ascii: "I"):
            tab(forward: n)
        case UInt8(ascii: "J"):
            eraseInDisplay(csi.parameter(0, default: 0, zeroIsDefault: false))
        case UInt8(ascii: "K"):
            eraseInLine(csi.parameter(0, default: 0, zeroIsDefault: false))
        case UInt8(ascii: "L"):
            insertLines(n)
        case UInt8(ascii: "M"):
            deleteLines(n)
        case UInt8(ascii: "P"):
            deleteCharacters(n)
        case UInt8(ascii: "S") where marker == nil:
            scrollUp(n)
        case UInt8(ascii: "T") where marker == nil && csi.parameters.count <= 1:
            scrollDown(n)
        case UInt8(ascii: "X"):
            erase(row: cursorRow, from: cursorColumn, to: cursorColumn + n)
        case UInt8(ascii: "Z"):
            tab(backward: n)
        case UInt8(ascii: "b"):
            if let lastGraphic {
                for _ in 0..<min(n, columns * rows) { printScalar(lastGraphic) }
            }
        case UInt8(ascii: "c"):
            deviceAttributes(marker)
        case UInt8(ascii: "d"):
            moveCursor(row: n - 1)
        case UInt8(ascii: "g"):
            switch csi.parameter(0, default: 0, zeroIsDefault: false) {
            case 0: tabStops[cursorColumn] = false
            case 3: tabStops = Array(repeating: false, count: columns)
            default: break
            }
        case UInt8(ascii: "h"):
            setModes(csi, enabled: true)
        case UInt8(ascii: "l"):
            setModes(csi, enabled: false)
        case UInt8(ascii: "m") where marker == nil:
            selectGraphicRendition(csi.parameters)
        case UInt8(ascii: "n"):
            deviceStatusReport(csi)
        case UInt8(ascii: "r") where marker == nil:
            setScrollRegion(top: csi.parameter(0, default: 1), bottom: csi.parameter(1, default: rows))
        case UInt8(ascii: "s") where marker == nil:
            saveCursor()
        case UInt8(ascii: "u") where marker == nil:
            restoreCursor()
        case UInt8(ascii: "t") where marker == nil:
            if csi.parameter(0, default: 0, zeroIsDefault: false) == 18 { respond("\u{1B}[8;\(rows);\(columns)t") }
        default:
            break
        }
    }

    private func moveCursorVertically(_ delta: Int) {
        let limits = verticalLimits
        pendingWrap = false
        cursorRow = min(max(cursorRow + delta, limits.top), limits.bottom)
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let top = top - 1
        let bottom = min(bottom, rows) - 1
        guard top < bottom, top >= 0 else { return }
        scrollTop = top
        scrollBottom = bottom
        moveCursor(row: 0, column: 0)
    }

    private func respond(_ text: String) {
        responses.append(contentsOf: text.utf8)
    }

    private func deviceAttributes(_ marker: UInt8?) {
        switch marker {
        case nil: respond("\u{1B}[?62;22c")
        case UInt8(ascii: ">"): respond("\u{1B}[>1;10;0c")
        default: break
        }
    }

    private func deviceStatusReport(_ csi: TerminalCSI) {
        switch csi.parameter(0, default: 0, zeroIsDefault: false) {
        case 5:
            respond("\u{1B}[0n")
        case 6:
            let row = cursorRow - (originMode ? scrollTop : 0) + 1
            let prefix = csi.privateMarker == UInt8(ascii: "?") ? "?" : ""
            respond("\u{1B}[\(prefix)\(row);\(cursorColumn + 1)R")
        default:
            break
        }
    }

    private func setModes(_ csi: TerminalCSI, enabled: Bool) {
        for parameter in csi.parameters {
            guard let mode = parameter.first, mode >= 0 else { continue }
            if csi.privateMarker == UInt8(ascii: "?") {
                setPrivateMode(mode, enabled: enabled)
            } else if csi.privateMarker == nil {
                switch mode {
                case 4: insertMode = enabled
                case 20: newLineMode = enabled
                default: break
                }
            }
        }
    }

    private func setPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 1: applicationCursorKeys = enabled
        case 5: reverseVideo = enabled
        case 6:
            originMode = enabled
            moveCursor(row: 0, column: 0)
        case 7:
            autowrap = enabled
            if !enabled { pendingWrap = false }
        case 25: cursorVisible = enabled
        case 47:
            if enabled { switchToAlternate(clear: false) } else { switchToMain(clearAlternate: false) }
        case 1047:
            if enabled { switchToAlternate(clear: false) } else { switchToMain(clearAlternate: true) }
        case 1048:
            if enabled { saveCursor() } else { restoreCursor() }
        case 1049:
            if enabled {
                saveCursor()
                switchToAlternate(clear: true)
            } else {
                switchToMain(clearAlternate: false)
                restoreCursor()
            }
        case 9, 1000: mouseTracking = enabled ? .clicks : .off
        case 1002: mouseTracking = enabled ? .drags : .off
        case 1003: mouseTracking = enabled ? .motion : .off
        case 1006: mouseSGR = enabled
        case 2004: bracketedPaste = enabled
        default: break
        }
    }

    // MARK: SGR

    private func selectGraphicRendition(_ parameters: [[Int]]) {
        if parameters.isEmpty {
            pen = .plain
            return
        }
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            let code = max(parameter[0], 0)
            switch code {
            case 0: pen = .plain
            case 1: pen.flags.insert(.bold)
            case 2: pen.flags.insert(.dim)
            case 3: pen.flags.insert(.italic)
            case 4:
                // 4:0 turns underline off; 4:1 to 4:5 are underline styles.
                if parameter.count > 1, parameter[1] == 0 { pen.flags.remove(.underline) } else { pen.flags.insert(.underline) }
            case 5, 6: pen.flags.insert(.blink)
            case 7: pen.flags.insert(.inverse)
            case 8: pen.flags.insert(.hidden)
            case 9: pen.flags.insert(.strikethrough)
            case 21: pen.flags.insert(.underline)
            case 22: pen.flags.remove([.bold, .dim])
            case 23: pen.flags.remove(.italic)
            case 24: pen.flags.remove(.underline)
            case 25: pen.flags.remove(.blink)
            case 27: pen.flags.remove(.inverse)
            case 28: pen.flags.remove(.hidden)
            case 29: pen.flags.remove(.strikethrough)
            case 30...37: pen.foreground = .indexed(UInt8(code - 30))
            case 39: pen.foreground = .default
            case 40...47: pen.background = .indexed(UInt8(code - 40))
            case 49: pen.background = .default
            case 90...97: pen.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: pen.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48, 58:
                let color: TerminalColor?
                if parameter.count > 1 {
                    color = Self.extendedColor(subparameters: Array(parameter.dropFirst()))
                } else {
                    let (parsed, used) = Self.extendedColor(following: parameters, after: index)
                    color = parsed
                    index += used
                }
                if let color {
                    if code == 38 { pen.foreground = color } else if code == 48 { pen.background = color }
                }
            default:
                break
            }
            index += 1
        }
    }

    /// `38:5:n` or `38:2:[colour space]:r:g:b`, after the 38.
    private static func extendedColor(subparameters values: [Int]) -> TerminalColor? {
        guard let kind = values.first else { return nil }
        switch kind {
        case 5:
            guard values.count > 1 else { return nil }
            return .indexed(UInt8(clamping: max(values[1], 0)))
        case 2:
            let rgb = values.count >= 5 ? Array(values.suffix(3)) : Array(values.dropFirst())
            guard rgb.count == 3 else { return nil }
            return .rgb(UInt8(clamping: max(rgb[0], 0)), UInt8(clamping: max(rgb[1], 0)), UInt8(clamping: max(rgb[2], 0)))
        default:
            return nil
        }
    }

    /// `38;5;n` or `38;2;r;g;b`: the colour and how many parameters after the 38 it used.
    private static func extendedColor(following parameters: [[Int]], after index: Int) -> (TerminalColor?, Int) {
        func value(_ offset: Int) -> Int? {
            let position = index + offset
            guard position < parameters.count else { return nil }
            return max(parameters[position][0], 0)
        }
        switch value(1) {
        case 5:
            guard let color = value(2) else { return (nil, 1) }
            return (.indexed(UInt8(clamping: color)), 2)
        case 2:
            guard let red = value(2), let green = value(3), let blue = value(4) else { return (nil, parameters.count - index - 1) }
            return (.rgb(UInt8(clamping: red), UInt8(clamping: green), UInt8(clamping: blue)), 4)
        default:
            return (nil, 0)
        }
    }

    // MARK: OSC

    private func operatingSystemCommand(_ text: String) {
        guard let separator = text.firstIndex(of: ";") else { return }
        let command = text[..<separator]
        let value = String(text[text.index(after: separator)...])
        switch command {
        case "0", "2":
            title = String(value.prefix(256))
        case "7":
            if let url = URL(string: value), url.isFileURL, !url.path.isEmpty { reportedDirectory = url.path }
        default:
            break
        }
    }

    // MARK: Helpers

    private func isBlank(_ line: TerminalLine) -> Bool {
        line.cells.allSatisfy { $0.isPlainBlank }
    }

    /// One-character strings for ASCII, made once (most of what programs print).
    private static let asciiText: [String] = (0..<128).map { String(Character(Unicode.Scalar(UInt8($0)))) }

    private static func defaultTabStops(_ columns: Int) -> [Bool] {
        (0..<columns).map { $0 > 0 && $0 % 8 == 0 }
    }

    /// The DEC special graphics set (`ESC ( 0`): line drawing for programs that draw boxes.
    private static let decSpecialGraphics: [UInt32: Unicode.Scalar] = [
        0x5F: "\u{00A0}", 0x60: "\u{25C6}", 0x61: "\u{2592}", 0x62: "\u{2409}", 0x63: "\u{240C}", 0x64: "\u{240D}",
        0x65: "\u{240A}", 0x66: "\u{00B0}", 0x67: "\u{00B1}", 0x68: "\u{2424}", 0x69: "\u{240B}", 0x6A: "\u{2518}",
        0x6B: "\u{2510}", 0x6C: "\u{250C}", 0x6D: "\u{2514}", 0x6E: "\u{253C}", 0x6F: "\u{23BA}", 0x70: "\u{23BB}",
        0x71: "\u{2500}", 0x72: "\u{23BC}", 0x73: "\u{23BD}", 0x74: "\u{251C}", 0x75: "\u{2524}", 0x76: "\u{2534}",
        0x77: "\u{252C}", 0x78: "\u{2502}", 0x79: "\u{2264}", 0x7A: "\u{2265}", 0x7B: "\u{03C0}", 0x7C: "\u{2260}",
        0x7D: "\u{00A3}", 0x7E: "\u{00B7}",
    ]
}

/// Which mouse events a program asked to receive.
public enum TerminalMouseTracking: Sendable, Equatable {
    case off
    /// Presses and releases (1000).
    case clicks
    /// Also movement while a button is down (1002).
    case drags
    /// All movement (1003).
    case motion
}

extension TerminalLine {
    /// Text of columns `start..<end`, optionally keeping trailing spaces.
    func text(from start: Int, to end: Int, trimming: Bool) -> String {
        if trimming { return text(from: start, to: end) }
        let lower = max(0, start)
        let upper = min(cells.count, end)
        guard lower < upper else { return "" }
        var result = ""
        for column in lower..<upper where cells[column].width != 0 {
            result += cells[column].text.isEmpty ? " " : cells[column].text
        }
        return result
    }
}
